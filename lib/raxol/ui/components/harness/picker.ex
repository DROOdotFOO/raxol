defmodule Raxol.UI.Components.Harness.Picker do
  @moduledoc """
  Overlay picker primitive (AD-U3): prompt + ranked list + async
  cancelable preview -- the fzf-shape that serves every "pick one of N"
  (sessions, runs, tool-calls, command palette, file mentions). One
  primitive, many projections (T15's job); this unit builds the
  component itself.

  ## Substrate honesty

  This component renders in **ordinary buffer mode** -- a ranked list
  laid out in a normal flow column, no `AbsoluteLayer`/`CellDim`
  full-viewport cover. The overlay-over-inline SUBSTRATE question (does
  summoning this picker as a screen overlay mean a scoped full-viewport
  cover via terminal save/restore, or a footer-anchored expansion?) is
  deferred to the D-PA/T0 verdict and lands with T15/T24, which mount
  this component inside whichever substrate they choose. Nothing here
  assumes a particular host; `render/2` just needs a `context` with
  `:available_width` (and optionally `:available_height`, used to size
  the visible window) the way any other component does.

  ## Filtering

  Uses `Raxol.UI.ListScorer.rank/4` (the list-item fuzzy scorer) against
  `key_fn.(item)` for every item on every query change -- **not**
  `Raxol.Search.Fuzzy`, which searches buffer cells, a different problem.

  ## Props

    * `:items` -- required, the full unfiltered list.
    * `:key_fn` -- required, `item -> String.t()`; derives both the
      search key and the rendered label for each item.
    * `:on_select` -- message tag emitted on Enter, default `:select`.
      Emits `{:component_event, id, {on_select, item}}` for the
      currently selected item; a no-op if the ranked list is empty.
    * `:on_cancel` -- message tag emitted on Escape, default `:cancel`.
      Emits `{:component_event, id, on_cancel}`.
    * `:preview_fn` -- optional, `item -> {:ok, content} | {:error,
      reason}`, run via `Task.async/1` for the currently selected item.
      When absent, no preview pane renders at all. **Must be
      side-effect-free / cancel-safe:** on any selection change the
      in-flight preview task is killed with `Task.shutdown(task,
      :brutal_kill)` (no cleanup, no `terminate`, no chance to close
      what it opened), so `preview_fn` must not perform unguarded
      side effects that leak on an abrupt kill -- no bare file handles,
      sockets, ports, or DB connections held across the call. Read a
      snapshot, compute, return; if it must acquire a resource, wrap it
      so an abrupt process death can't strand it.
    * `:placeholder` -- prompt placeholder shown while the query is
      empty (default `""`).
    * `:visible_height` -- rows in the scrollable list window (default
      `10`); windowing is `Raxol.UI.ScrollWindow` (cursor-follow,
      edge-anchored).

  ## Behavior

  Type-to-filter: printable keys append to the query, Backspace removes
  the last grapheme; the ranked list and cursor (reset to the top match)
  update on every change. Up/Down move the cursor, clamped and windowed
  by `ScrollWindow`. Enter selects the current item. Escape dismisses.

  ## Stale-preview cancellation (the fzf#3134 lesson)

  Every selection change (typing that changes the top match, or Up/Down
  landing on a different item) cancels the in-flight preview `Task` for
  the *previous* selection via `Task.shutdown/2` and starts a new one
  for the current item, tagging the pending result with the new task's
  own `ref`. Two independent guards keep a superseded result from ever
  reaching the screen:

    1. `Task.shutdown/2` kills the old task process and flushes any
       completion message already sitting in this process's mailbox --
       most of the time, that's the end of it.
    2. Even in the race where a result was already in flight before the
       shutdown call landed, `update/2` only applies a `{ref, result}`
       (or `{:DOWN, ref, ...}`) message when `ref` matches
       `state.preview_ref` *at the time the message is handled*. A
       result tagged with a superseded ref is pattern-matched into a
       catch-all clause and dropped -- it never touches `state.preview`,
       so it can never render.

  A real host process must forward whatever arrives in its mailbox for
  a spawned preview task straight into this component's `update/2` --
  the raw `{ref, result}` / `{:DOWN, ref, :process, pid, reason}` shapes
  `Task.async/1` itself produces, unwrapped. That's what makes the
  ref-matching guard above work with zero translation layer.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.Ids
  alias Raxol.UI.Components.Harness.TextUtil
  alias Raxol.UI.ListScorer
  alias Raxol.UI.ScrollWindow
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @default_visible_height 10
  @default_placeholder ""
  @default_preview_width_divisor 2
  @min_preview_width 10

  @type preview_state ::
          :none | :loading | {:ok, String.t()} | {:error, term()}

  @type t :: %{
          id: term(),
          items: [term()],
          key_fn: (term() -> String.t()),
          on_select: term(),
          on_cancel: term(),
          preview_fn: (term() -> {:ok, String.t()} | {:error, term()}) | nil,
          placeholder: String.t(),
          visible_height: pos_integer(),
          query: String.t(),
          ranked: [ListScorer.result()],
          cursor: non_neg_integer(),
          scroll_top: non_neg_integer(),
          preview: preview_state(),
          preview_task: Task.t() | nil,
          preview_ref: reference() | nil,
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = Map.new(props)

    id = Ids.default_id(props, "harness-picker")

    items = Map.get(props, :items, [])
    key_fn = Map.fetch!(props, :key_fn)
    ranked = ListScorer.rank(items, "", key_fn)

    state = %{
      id: id,
      items: items,
      key_fn: key_fn,
      on_select: Map.get(props, :on_select, :select),
      on_cancel: Map.get(props, :on_cancel, :cancel),
      preview_fn: Map.get(props, :preview_fn),
      placeholder: Map.get(props, :placeholder, @default_placeholder),
      visible_height: Map.get(props, :visible_height, @default_visible_height),
      query: "",
      ranked: ranked,
      cursor: 0,
      scroll_top: 0,
      preview: :none,
      preview_task: nil,
      preview_ref: nil,
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }

    {:ok, refresh_preview(state)}
  end

  # -- public helpers --

  @doc "The currently selected item, or `nil` if the ranked list is empty."
  @spec selected_item(t()) :: term() | nil
  def selected_item(state) do
    case Enum.at(state.ranked, state.cursor) do
      nil -> nil
      %{item: item} -> item
    end
  end

  @doc "Current query string."
  @spec query(t()) :: String.t()
  def query(%{query: query}), do: query

  @doc "Current ranked (filtered) result list."
  @spec ranked(t()) :: [ListScorer.result()]
  def ranked(%{ranked: ranked}), do: ranked

  @doc "Current preview state."
  @spec preview(t()) :: preview_state()
  def preview(%{preview: preview}), do: preview

  # -- update: preview task results + prop merge --

  @impl true
  def update({ref, result}, %{preview_ref: ref} = state)
      when is_reference(ref) do
    {%{
       state
       | preview: normalize_preview(result),
         preview_task: nil,
         preview_ref: nil
     }, []}
  end

  # Any other `{ref, result}` is a superseded selection's preview task
  # completing late -- dropped by ref-matching, never rendered (see
  # moduledoc, "Stale-preview cancellation").
  def update({ref, _result}, state) when is_reference(ref), do: {state, []}

  def update({:DOWN, ref, :process, _pid, reason}, %{preview_ref: ref} = state) do
    {%{state | preview: {:error, reason}, preview_task: nil, preview_ref: nil},
     []}
  end

  def update({:DOWN, _ref, :process, _pid, _reason}, state), do: {state, []}

  def update({:set_items, items}, state) do
    new_state = %{state | items: items}
    {update_query(new_state, new_state.query), []}
  end

  # Keys `update/2`'s prop-merge clause is willing to touch. Anything
  # else in an incoming map -- notably internal fields like `:cursor`,
  # `:scroll_top`, `:ranked`, `:query`, `:preview*` that this module
  # manages itself via `update_query/2`/`move_cursor/2`/`refresh_preview/1`
  # -- is silently dropped rather than merged verbatim. Without this,
  # `update(%{cursor: 99}, state)` would write an out-of-range cursor
  # straight into state, bypassing `ScrollWindow`'s clamp/windowing (the
  # only path that's supposed to move `:cursor`) and desyncing it from
  # `:scroll_top` -- a caller doesn't need a hostile struct to corrupt
  # this component's invariants, an ordinary map with the wrong key is
  # enough.
  @allowed_props [
    :id,
    :items,
    :key_fn,
    :visible_height,
    :placeholder,
    :on_select,
    :on_cancel,
    :preview_fn,
    :style,
    :theme
  ]

  # `not is_struct(props)` matters too: every `%Event{}` (and any other
  # struct) is also a plain map, so a bare `is_map(props)` guard here
  # would let a mis-routed struct -- e.g. an `%Event{}` that missed every
  # `handle_event/3` clause above and got sent through `update/2` instead
  # -- reach this clause at all. Structs fall through to the catch-all
  # below instead, which is a safe no-op; the `Map.take/2` allowlist
  # above is the second, independent guard for ordinary maps carrying
  # unexpected keys.
  def update(props, state) when is_map(props) and not is_struct(props) do
    Raxol.UI.Components.Base.Component.merge_props(
      Map.take(props, @allowed_props),
      state
    )
  end

  def update(_msg, state), do: {state, []}

  # -- events --

  @impl true
  def handle_event(%Event{type: :key, data: %{key: :escape}}, state, _context) do
    {cancel_preview(state), [{:component_event, state.id, state.on_cancel}]}
  end

  def handle_event(%Event{type: :key, data: %{key: :enter}}, state, _context) do
    case selected_item(state) do
      nil -> {state, []}
      item -> {state, [{:component_event, state.id, {state.on_select, item}}]}
    end
  end

  def handle_event(%Event{type: :key, data: %{key: :up}}, state, _context) do
    {move_cursor(state, -1), []}
  end

  def handle_event(%Event{type: :key, data: %{key: :down}}, state, _context) do
    {move_cursor(state, 1), []}
  end

  def handle_event(
        %Event{type: :key, data: %{key: :backspace}},
        state,
        _context
      ) do
    {update_query(state, drop_last_grapheme(state.query)), []}
  end

  # Printable characters. A binary `key` is always a text character (the
  # special keys above all use atoms), so this matches the printable
  # inlet across every driver's event shape -- but whether it's *text* or
  # a *shortcut* depends on the modifiers, which each driver reports
  # differently (see `text_input?/1`). NOTE the shape gap this fixes:
  # only `Event.key_event/3` sets a `modifiers:` list; the native
  # terminal driver's `event_translator.ex` emits boolean
  # `shift:/ctrl:/alt:` fields and `input_parser.ex` emits a bare
  # `%{key: char}` with no modifier fields at all. A clause requiring
  # `modifiers:` is therefore dead on the real terminal (the T11 bug
  # class). Handled defensively inline here; a shared `T27` normalize/1
  # will supersede this later.
  def handle_event(
        %Event{type: :key, data: %{key: char} = data},
        state,
        _context
      )
      when is_binary(char) do
    if text_input?(data) do
      {update_query(state, state.query <> char), []}
    else
      {state, []}
    end
  end

  def handle_event(_event, state, _context), do: {state, []}

  # A printable key is text unless a ctrl/alt modifier makes it a
  # shortcut. Reads all three modifier encodings defensively: the
  # `modifiers:` list (`Event.key_event/3`), boolean `ctrl:`/`alt:`
  # fields (`event_translator.ex`), or their absence entirely
  # (`input_parser.ex`'s bare `%{key: char}`). Shift alone (capital
  # letters) stays text.
  defp text_input?(data) do
    modifiers = data[:modifiers] || []

    not (data[:ctrl] == true or data[:alt] == true or :ctrl in modifiers or
           :alt in modifiers)
  end

  # -- private: query / cursor / preview lifecycle --

  defp update_query(state, new_query) do
    ranked = ListScorer.rank(state.items, new_query, state.key_fn)

    %{state | query: new_query, ranked: ranked, cursor: 0, scroll_top: 0}
    |> refresh_preview()
  end

  defp move_cursor(state, delta) do
    if state.ranked == [] do
      state
    else
      requested = state.cursor + delta

      window =
        ScrollWindow.window(
          state.ranked,
          requested,
          state.visible_height,
          state.scroll_top
        )

      new_cursor = window.scroll_top + window.cursor_row
      new_state = %{state | cursor: new_cursor, scroll_top: window.scroll_top}

      if selected_item(new_state) == selected_item(state) do
        new_state
      else
        refresh_preview(new_state)
      end
    end
  end

  defp refresh_preview(state) do
    state = cancel_preview(state)

    case {state.preview_fn, selected_item(state)} do
      {nil, _item} -> %{state | preview: :none}
      {_preview_fn, nil} -> %{state | preview: :none}
      {preview_fn, item} -> start_preview(state, preview_fn, item)
    end
  end

  defp start_preview(state, preview_fn, item) do
    task = Task.async(fn -> safe_preview(preview_fn, item) end)
    %{state | preview_task: task, preview_ref: task.ref, preview: :loading}
  end

  defp safe_preview(preview_fn, item) do
    preview_fn.(item)
  rescue
    error -> {:error, error}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp cancel_preview(%{preview_task: nil} = state), do: state

  defp cancel_preview(%{preview_task: task} = state) do
    Task.shutdown(task, :brutal_kill)
    %{state | preview_task: nil, preview_ref: nil}
  end

  defp normalize_preview({:ok, content}) when is_binary(content),
    do: {:ok, content}

  defp normalize_preview({:error, _reason} = error), do: error
  defp normalize_preview(other), do: {:error, {:invalid_preview_result, other}}

  defp drop_last_grapheme(""), do: ""

  defp drop_last_grapheme(text) do
    text
    |> String.graphemes()
    |> Enum.drop(-1)
    |> Enum.join()
  end

  # -- render --

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    avail_width = context[:available_width] || 60

    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_picker)

    list = render_list(state, avail_width)

    body =
      if state.preview_fn do
        Components.row(
          id: "picker-body",
          gap: 2,
          children: [list, render_preview(state, avail_width)]
        )
      else
        list
      end

    Components.column(
      id: state.id,
      style: base_style,
      gap: 0,
      children: [render_prompt(state, avail_width), body]
    )
  end

  defp render_prompt(state, avail_width) do
    shown = if state.query == "", do: state.placeholder, else: state.query
    dim? = state.query == ""

    Components.text(
      id: "picker-prompt",
      content: TextUtil.truncate_to_width("> " <> shown, avail_width),
      style: if(dim?, do: %{dim: true}, else: %{})
    )
  end

  defp render_list(state, avail_width) do
    window =
      ScrollWindow.window(
        state.ranked,
        state.cursor,
        state.visible_height,
        state.scroll_top
      )

    rows =
      window.visible
      |> Enum.with_index()
      |> Enum.map(fn {result, row_index} ->
        render_row(result, row_index == window.cursor_row, avail_width)
      end)

    Components.column(id: "picker-list", gap: 0, children: rows)
  end

  # An empty label (`key_fn` yielding `""`) would otherwise fall through
  # to a zero-child row via the general clause below (`String.graphemes("")`
  # is `[]`) -- invisible and, on some hosts, unselectable since there's
  # nothing rendered to hang a hit-test on. Emit a dim placeholder so the
  # row is visible and its selection background still shows.
  defp render_row(%{key: ""}, selected?, _avail_width) do
    row_style = if selected?, do: %{bg: :blue, fg: :white}, else: %{}

    placeholder =
      Components.text(
        content: "(no label)",
        style: Map.put(row_style, :dim, true)
      )

    Components.row(style: row_style, gap: 0, children: [placeholder])
  end

  defp render_row(%{key: key, positions: positions}, selected?, avail_width) do
    {key, positions} = truncate_key(key, positions, avail_width)
    position_set = MapSet.new(positions)

    segments =
      key
      |> String.graphemes()
      |> Enum.with_index()
      |> Enum.chunk_by(fn {_grapheme, index} ->
        MapSet.member?(position_set, index)
      end)
      |> Enum.map(fn chunk ->
        {_grapheme, first_index} = hd(chunk)
        highlighted? = MapSet.member?(position_set, first_index)
        text = Enum.map_join(chunk, fn {grapheme, _index} -> grapheme end)

        Components.text(
          content: text,
          style: segment_style(highlighted?, selected?)
        )
      end)

    row_style = if selected?, do: %{bg: :blue, fg: :white}, else: %{}
    Components.row(style: row_style, gap: 0, children: segments)
  end

  defp segment_style(true, selected?),
    do: Map.put(base_row_style(selected?), :bold, true)

  defp segment_style(false, selected?), do: base_row_style(selected?)

  defp base_row_style(true), do: %{bg: :blue, fg: :white}
  defp base_row_style(false), do: %{}

  defp truncate_key(key, positions, avail_width)
       when is_integer(avail_width) and avail_width > 0 do
    if TextMeasure.display_width(key) <= avail_width do
      {key, positions}
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(key, max(avail_width - 1, 0))

      kept_len = String.length(left)
      {left <> "…", Enum.filter(positions, &(&1 < kept_len))}
    end
  end

  defp truncate_key(key, positions, _avail_width), do: {key, positions}

  defp render_preview(state, avail_width) do
    preview_width =
      max(div(avail_width, @default_preview_width_divisor), @min_preview_width)

    children =
      state.preview
      |> preview_lines()
      |> Enum.map(fn {line, style} ->
        Components.text(content: line, style: style)
      end)

    Components.column(
      id: "picker-preview",
      style: %{width: preview_width},
      gap: 0,
      children: children
    )
  end

  defp preview_lines(:none), do: [{"", %{}}]
  defp preview_lines(:loading), do: [{"loading…", %{dim: true}}]

  defp preview_lines({:error, _reason}),
    do: [{"preview unavailable", %{dim: true}}]

  defp preview_lines({:ok, text}) do
    text
    |> String.split("\n")
    |> Enum.map(&{&1, %{}})
  end
end
