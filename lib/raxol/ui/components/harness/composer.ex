defmodule Raxol.UI.Components.Harness.Composer do
  @moduledoc """
  Harness prompt composer: wraps `Raxol.UI.Components.Input.MultiLineInput`
  with harness-specific submit semantics, input history recall, bracketed
  paste fidelity, and a queued-steer banner. Does not reimplement multi-line
  editing -- cursor movement, selection, and text mutation stay entirely in
  MultiLineInput; this module only decides *when* those primitives fire and
  adds one banner above the prompt.

  ## Submit semantics

  Enter with no modifiers submits (`{:component_event, id, {:submit, text}}`)
  when the buffer is a single logical line (no embedded `\\n`, regardless of
  visual wrap) and non-empty after trimming. Enter with `:shift` or `:alt`
  held, or Enter while the buffer already spans multiple logical lines
  (continuation), inserts a literal newline instead via MultiLineInput's own
  `{:enter}` message. `force_submit/1` is exposed for a consumer (T12
  keybinds) to wire an unconditional submit key (e.g. Ctrl+Enter) that
  bypasses the single-line gate.

  **Legacy terminals and the degraded-mode inlet:** many terminals do not
  encode Shift+Enter or Alt+Enter distinctly (Alt+Enter arrives as ESC CR
  and the ESC is dropped in parsing -- a bare Enter is all this component
  sees), so the modifier branches are unreachable there. The
  modifier-independent primary inlet to a first newline is **backslash
  continuation**: a line ending in `\\` + Enter consumes the backslash and
  inserts a newline instead of submitting. This works over tmux/SSH/mosh
  at any point, including creating the very first newline. Escape rule
  (simplest that round-trips a literal trailing backslash): count the
  trailing backslash run -- an odd run means continuation (the final
  backslash is consumed, the rest stay as typed); an even run means submit
  with the run halved (`\\\\` submits as `\\`). The rule applies only on
  the Enter-submit path; `force_submit/1` and paste submit/insert content
  verbatim. Bracketed paste and a consumer-wired `force_submit/1` remain
  alternate inlets, and a dim hint line (`\\ continue · paste multiline ·
  ↵ submit`) renders below the input while it is focused, empty, and has
  no history yet. The modifier branches activate automatically when F1b
  (kitty keyboard protocol) lands -- zero logic change here.

  ## Input-shape normalization

  `handle_event/3` normalizes every incoming event through
  `Raxol.UI.Harness.InputEvent.normalize/1` before deciding anything.
  Before T27's review round this component matched key events by pattern
  (`%{key: :enter, modifiers: modifiers}`), which only exists on
  `Event.key_event/3`'s test-API shape -- the real terminal driver's two
  shapes (`event_translator.ex`'s boolean `shift:`/`ctrl:`/... fields,
  `input_parser.ex`'s optional fields) have no `:modifiers` key at all, so
  the pattern never matched a REAL keypress. Enter never submitted,
  printable characters never inserted, and everything silently fell
  through to raw `MultiLineInput` delegation for actual terminal input --
  this unit only ever worked in tests that construct `Event.key_event/3`
  directly. `InputEvent.normalize/1` erases that shape difference: Enter
  from a real termbox driver, a real ANSI parser, or `Event.key_event/3`
  all normalize to the same `kind: :key, key: :enter` and reach the same
  `handle_enter_key/2`.

  Printable characters arriving with compound modifiers (e.g. Shift+Alt)
  are `InputEvent.shortcut?/1` (alt held) and fall through to
  `MultiLineInput` delegation, same as before -- canonical compound-
  modifier handling belongs to F1a input canon, not this unit.

  ## Bracketed paste

  The terminal driver already parses `ESC[200~...ESC[201~` into
  `%Raxol.Core.Events.Event{type: :paste, data: %{text: text}}`
  (`Raxol.Terminal.Ansi.InputParser`). This component routes that event
  straight into MultiLineInput's `{:clipboard_content, text}` message -- the
  same path Ctrl+V system-clipboard paste already uses
  (`MultiLineInput.SelectionOps.handle_clipboard_content/2`) -- so pasted
  newlines are inserted verbatim in one edit and never pass through the
  Enter/submit decision above, no matter how many lines the paste contains.

  ## History recall

  Up at the first (visual) line, or Down at the last (visual) line, walks a
  bounded ring (default 100) of past submissions, newest first. The
  in-progress draft is saved on the first Up so Down can restore it. Any
  other cursor position forwards Up/Down to MultiLineInput unchanged (normal
  cursor movement / shift-selection).

  ## Queued-steer banner

  `queued_steer: nil | %{text: String.t(), queued_at: term()}` renders (when
  set) one dim, truncated line above the prompt, prefixed with "⏸ " --
  `⏸ steer queued for next boundary: <text>` -- visually distinct from
  editable content. This is AD-2's two-signal model (interrupt vs. steer)
  made visible.

  ## Resize safety

  No absolute width is persisted on this struct. `render/2` derives
  MultiLineInput's width from `context[:available_width]` on every call and
  re-wraps the cached lines for that width, so a resized `context` produces
  a correctly-wrapped prompt without any stored width going stale.
  """

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Input.MultiLineInput
  alias Raxol.UI.Components.Input.MultiLineInput.TextHelper
  alias Raxol.UI.Harness.InputEvent
  alias Raxol.UI.StyleHelper
  alias Raxol.UI.TextMeasure
  alias Raxol.View.Components

  use Raxol.UI.Components.Base.Component

  @default_width 80
  @default_height 3
  @default_max_history 100
  @steer_prefix "⏸ steer queued for next boundary: "
  @hint_text "\\ continue · paste multiline · ↵ submit"

  @type queued_steer :: %{text: String.t(), queued_at: term()} | nil

  @type t :: %{
          id: String.t() | atom(),
          mli: MultiLineInput.t(),
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          draft: String.t() | nil,
          queued_steer: queued_steer(),
          max_history: pos_integer(),
          style: map(),
          theme: map()
        }

  @impl true
  @spec init(keyword() | map()) :: {:ok, t()}
  def init(props) do
    props = Map.new(props)

    id =
      Map.get(
        props,
        :id,
        "harness-composer-#{:erlang.unique_integer([:positive])}"
      )

    {:ok, mli} =
      MultiLineInput.init(%{
        id: "#{id}-input",
        value: Map.get(props, :value, ""),
        placeholder: Map.get(props, :placeholder, ""),
        width: Map.get(props, :width, @default_width),
        height: Map.get(props, :height, @default_height),
        wrap: Map.get(props, :wrap, :word),
        focused: Map.get(props, :focused, true)
      })

    state = %{
      id: id,
      mli: mli,
      history: [],
      history_index: nil,
      draft: nil,
      queued_steer: Map.get(props, :queued_steer),
      max_history: Map.get(props, :max_history, @default_max_history),
      style: Map.get(props, :style, %{}),
      theme: Map.get(props, :theme, %{})
    }

    {:ok, state}
  end

  # -- public helpers (used by consumers: T12 keybinds, T25 editor handoff) --

  @doc "Current composer text (delegates to the wrapped MultiLineInput)."
  @spec value(t()) :: String.t()
  def value(%{mli: %{value: text}}), do: text

  @doc "Replace the composer's content programmatically (e.g. after $EDITOR)."
  @spec set_value(t(), String.t()) :: t()
  def set_value(state, text), do: %{state | mli: set_mli_value(state.mli, text)}

  @doc "Bounded, newest-first list of past submissions."
  @spec history(t()) :: [String.t()]
  def history(%{history: history}), do: history

  @doc """
  The composer's edit point within the lines `render/2` produces at
  `avail_width`: `{row_offset, col}` -- 0-based row offset counted from
  the composer's own first rendered line (the queued-steer banner, when
  present, occupies row 0), 1-based display column.

  This is the terminal-cursor park target for an assembling surface
  (`Raxol.Harness.Surface.paint_footer/1` -> `InlineAuthority`'s
  `:cursor` option): the native cursor should sit where the next typed
  grapheme lands. Minimal honest version, deliberately: the reported
  point is the END OF THE TYPED DRAFT (last visible input row, one
  column past its content) -- not the mid-draft caret MultiLineInput
  tracks internally. Re-deriving the caret's visual position under
  `render/2`'s own re-wrap-at-`avail_width` is real work
  (`size_mli_for_render/2` re-splits the buffer, invalidating
  `cursor_pos`'s row/col against the rendered lines); end-of-draft is
  exact for the common case (typing appends) and honestly approximate
  after mid-draft cursor movement. Columns are measured with
  `Raxol.UI.TextMeasure` (CJK double-width), never `String.length/1`.
  """
  @spec edit_point(t(), pos_integer()) ::
          {non_neg_integer(), pos_integer()}
  def edit_point(state, avail_width)
      when is_integer(avail_width) and avail_width > 0 do
    mli = size_mli_for_render(state.mli, avail_width)
    banner = if state.queued_steer, do: 1, else: 0

    {scroll_row, _scroll_col} = mli.scroll_offset
    line_count = max(length(mli.lines), 1)
    last_visible = min(line_count - 1, scroll_row + mli.height - 1)
    row = banner + max(last_visible - scroll_row, 0)

    last_line = List.last(mli.lines) || ""
    col = min(TextMeasure.display_width(last_line) + 1, avail_width)

    {row, max(col, 1)}
  end

  @doc """
  Unconditional submit, bypassing the single-line gate -- for a consumer
  keybind (e.g. Ctrl+Enter) that must submit multi-line content directly.
  Returns `{state, []}` unchanged if the trimmed buffer is empty.
  """
  @spec force_submit(t()) :: {t(), [term()]}
  def force_submit(state) do
    text = value(state)

    if String.trim(text) == "" do
      {state, []}
    else
      submit(state, text)
    end
  end

  @impl true
  def update({:set_queued_steer, queued_steer}, state) do
    {%{state | queued_steer: queued_steer}, []}
  end

  def update(props, state) when is_map(props) do
    # :value/:placeholder/:focused describe the embedded MultiLineInput, not
    # the composer map itself -- forward them into the mli (buffer truth)
    # instead of letting merge_props stamp them onto the outer state where
    # they would silently desync from what the input actually contains.
    {mli_props, rest} = Map.split(props, [:value, :placeholder, :focused])

    state =
      if map_size(mli_props) > 0 do
        %{state | mli: sync_mli_props(state.mli, mli_props)}
      else
        state
      end

    Raxol.UI.Components.Base.Component.merge_props(rest, state)
  end

  def update(_msg, state), do: {state, []}

  defp sync_mli_props(mli, props) do
    mli =
      case Map.fetch(props, :value) do
        {:ok, value} -> set_mli_value(mli, value)
        :error -> mli
      end

    struct(mli, Map.take(props, [:placeholder, :focused]))
  end

  # -- events --

  # Migration pattern documented at `Raxol.UI.Harness.InputEvent`'s
  # moduledoc: normalize first, check `shortcut?/1` before `text?/1`/
  # `key/1` (so a modifier-qualified char/key still reaches the right
  # handler WITH its mods), paste short-circuits everything. Enter is
  # special-cased ahead of the generic shortcut/text/key triage because
  # its submit-vs-newline decision depends on mods (shift/alt) rather than
  # being a plain pass/fail shortcut check -- both `handle_shortcut/4`
  # (Alt+Enter, which IS classified `shortcut?`) and the `key` branch
  # (plain Enter, Shift+Enter, neither of which is) route back into the
  # same `handle_enter_key/2`.
  @impl true
  def handle_event(%Event{} = event, state, context) do
    norm = InputEvent.normalize(event)

    cond do
      norm.kind == :paste ->
        {new_mli, _cmds} =
          update_mli({:clipboard_content, norm.text}, state.mli)

        {%{state | mli: new_mli}, []}

      InputEvent.shortcut?(norm) ->
        handle_shortcut(norm, state, event, context)

      InputEvent.text?(norm) ->
        insert_char(state, InputEvent.printable_char(norm))

      key = InputEvent.key(norm) ->
        dispatch_key(key, norm.mods, state, event, context)

      true ->
        {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
        {%{state | mli: new_mli}, cmds}
    end
  end

  def handle_event(event, state, context) do
    {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
    {%{state | mli: new_mli}, cmds}
  end

  # Alt+Enter is `shortcut?` (alt held) but is still "insert a newline",
  # not a generic keyboard shortcut -- recognize it here and fall back to
  # the same `handle_enter_key/2` the unmodified/Shift+Enter path in
  # `dispatch_key/5` uses. No other composer-level shortcuts exist today;
  # a consumer (T12 keybinds) wires additional ones (e.g. Ctrl+Enter via
  # `force_submit/1`) outside this component, so anything else
  # ctrl/alt/meta-qualified falls through to MultiLineInput (e.g. Ctrl+C,
  # Ctrl+V, which it already owns).
  defp handle_shortcut(%{key: :enter, mods: mods}, state, _event, _context) do
    handle_enter_key(mods, state)
  end

  defp handle_shortcut(_norm, state, event, context) do
    {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
    {%{state | mli: new_mli}, cmds}
  end

  defp insert_char(state, nil), do: {state, []}

  # Routed through `{:clipboard_content, char}` -- the same safe insertion
  # path bracketed paste uses -- rather than MultiLineInput's own
  # `{:input, <binary>}` dispatch, which expects an integer codepoint
  # (`<<codepoint::utf8>>`) and crashes on ordinary keystrokes (kept out of
  # this changeset; MultiLineInput is outside T11's write-set). Also
  # correctly handles multi-codepoint graphemes (emoji) that the upstream
  # `byte_size == 1` dispatch drops entirely.
  defp insert_char(state, char) do
    {new_mli, cmds} = update_mli({:clipboard_content, char}, state.mli)
    {%{state | mli: new_mli}, cmds}
  end

  # Reached only when `shortcut?/1` was false, so ctrl/alt/meta are all
  # false here -- only `mods.shift` varies (e.g. Shift+Enter, Shift+Up).
  defp dispatch_key(:enter, mods, state, _event, _context) do
    handle_enter_key(mods, state)
  end

  defp dispatch_key(:up, mods, state, event, context) do
    if mods.shift do
      delegate(event, state, context)
    else
      handle_history_nav(:up, event, state, context)
    end
  end

  defp dispatch_key(:down, mods, state, event, context) do
    if mods.shift do
      delegate(event, state, context)
    else
      handle_history_nav(:down, event, state, context)
    end
  end

  defp dispatch_key(_key, _mods, state, event, context),
    do: delegate(event, state, context)

  defp delegate(event, state, context) do
    {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
    {%{state | mli: new_mli}, cmds}
  end

  # -- render --

  @impl true
  @spec render(t(), map()) :: map()
  def render(state, context) do
    avail_width = context[:available_width] || state.mli.width
    mli = size_mli_for_render(state.mli, avail_width)
    mli_context = Map.put_new(context, :theme, %{})

    base_style =
      StyleHelper.merge_component_styles(state, context, :harness_composer)

    children =
      [
        queued_steer_banner(state.queued_steer, avail_width),
        MultiLineInput.render(mli, mli_context),
        first_focus_hint(state)
      ]
      |> Enum.reject(&is_nil/1)

    %{
      type: :column,
      style: base_style,
      gap: 0,
      children: children
    }
  end

  # -- private: enter / submit --

  defp handle_enter_key(%{shift: shift, alt: alt}, state) do
    cond do
      shift or alt -> insert_newline(state)
      multiline?(state.mli) -> insert_newline(state)
      true -> maybe_submit(state)
    end
  end

  defp multiline?(mli), do: String.contains?(mli.value, "\n")

  defp insert_newline(state) do
    {new_mli, cmds} = update_mli({:enter}, state.mli)
    {%{state | mli: new_mli}, cmds}
  end

  # Enter-submit path only: backslash continuation is the
  # modifier-independent inlet to a newline (see moduledoc). An odd trailing
  # backslash run means "continue" (consume the final backslash, insert a
  # newline); an even run submits with the run halved so a literal trailing
  # backslash is expressible as `\\`.
  defp maybe_submit(state) do
    text = value(state)

    cond do
      String.trim(text) == "" -> {state, []}
      continuation?(text) -> apply_continuation(state, text)
      true -> submit(state, collapse_trailing_escapes(text))
    end
  end

  defp continuation?(text), do: rem(trailing_backslashes(text), 2) == 1

  defp collapse_trailing_escapes(text) do
    case trailing_backslashes(text) do
      0 -> text
      n -> String.slice(text, 0, String.length(text) - div(n, 2))
    end
  end

  defp trailing_backslashes(text) do
    text
    |> String.reverse()
    |> String.graphemes()
    |> Enum.take_while(&(&1 == "\\"))
    |> length()
  end

  # Builds the continued value directly (base minus the consumed backslash,
  # plus a newline) and derives `lines` by logical split, preserving the
  # trailing empty line. Deliberately NOT routed through MultiLineInput's
  # re-init/ensure_cursor_visible: its split_into_lines drops a trailing
  # empty line (upstream bug (2) in the commit body), which would strand the
  # cursor past the line list and lose the just-created newline on the next
  # edit.
  defp apply_continuation(state, text) do
    base = String.slice(text, 0, String.length(text) - 1)
    new_value = base <> "\n"
    lines = String.split(new_value, "\n")

    mli = %{
      state.mli
      | value: new_value,
        lines: lines,
        cursor_pos: {length(lines) - 1, 0},
        selection_start: nil,
        selection_end: nil
    }

    {%{state | mli: mli}, []}
  end

  defp submit(state, text) do
    history = Enum.take([text | state.history], state.max_history)
    fresh_mli = set_mli_value(state.mli, "")

    new_state = %{
      state
      | mli: fresh_mli,
        history: history,
        history_index: nil,
        draft: nil
    }

    {new_state, [{:component_event, state.id, {:submit, text}}]}
  end

  # -- private: history navigation --

  defp handle_history_nav(:up, event, state, context) do
    {row, _col} = state.mli.cursor_pos

    if row == 0 and state.history != [] do
      recall_older(state)
    else
      {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
      {%{state | mli: new_mli}, cmds}
    end
  end

  defp handle_history_nav(:down, event, state, context) do
    last_row = max(length(state.mli.lines) - 1, 0)
    {row, _col} = state.mli.cursor_pos

    if row == last_row and state.history_index != nil do
      recall_newer(state)
    else
      {new_mli, cmds} = delegate_to_mli(event, state.mli, context)
      {%{state | mli: new_mli}, cmds}
    end
  end

  defp recall_older(state) do
    next_index =
      case state.history_index do
        nil -> 0
        idx -> min(idx + 1, length(state.history) - 1)
      end

    draft = if state.history_index == nil, do: value(state), else: state.draft
    text = Enum.at(state.history, next_index, "")

    {%{
       state
       | mli: set_mli_value(state.mli, text),
         history_index: next_index,
         draft: draft
     }, []}
  end

  defp recall_newer(%{history_index: 0} = state) do
    text = state.draft || ""

    {%{
       state
       | mli: set_mli_value(state.mli, text),
         history_index: nil,
         draft: nil
     }, []}
  end

  defp recall_newer(state) do
    new_index = state.history_index - 1
    text = Enum.at(state.history, new_index, "")

    {%{state | mli: set_mli_value(state.mli, text), history_index: new_index},
     []}
  end

  defp set_mli_value(mli, text) do
    {:ok, new_mli} =
      MultiLineInput.init(%{
        id: mli.id,
        value: text,
        placeholder: mli.placeholder,
        width: mli.width,
        height: mli.height,
        wrap: mli.wrap,
        focused: true
      })

    last_row = max(length(new_mli.lines) - 1, 0)
    last_line = Enum.at(new_mli.lines, last_row, "")
    %{new_mli | cursor_pos: {last_row, String.length(last_line)}}
  end

  # -- private: delegation to the wrapped MultiLineInput --

  defp delegate_to_mli(event, mli, context) do
    case MultiLineInput.handle_event(event, mli, context) do
      {:noreply, new_mli, cmd} -> {new_mli, wrap_cmd(cmd)}
      _other -> {mli, []}
    end
  end

  defp update_mli(msg, mli) do
    case MultiLineInput.update(msg, mli) do
      {:noreply, new_mli, cmd} -> {new_mli, wrap_cmd(cmd)}
      _other -> {mli, []}
    end
  end

  defp wrap_cmd(nil), do: []
  defp wrap_cmd(cmd) when is_list(cmd), do: cmd
  defp wrap_cmd(cmd), do: [cmd]

  # -- private: render helpers --

  defp size_mli_for_render(mli, avail_width)
       when is_integer(avail_width) and avail_width > 0 and
              avail_width != mli.width do
    lines = TextHelper.split_into_lines(mli.value, avail_width, mli.wrap)
    %{mli | width: avail_width, lines: lines}
  end

  defp size_mli_for_render(mli, _avail_width), do: mli

  # First-focus hint: shown only while there is nothing else to look at --
  # focused, empty buffer, no history yet. Same dim styling tier as the
  # steer banner; disappears the moment any of the three conditions breaks.
  defp first_focus_hint(%{mli: mli, history: history}) do
    if mli.focused and history == [] and mli.value == "" do
      Components.text(
        id: "composer-hint",
        content: @hint_text,
        style: %{dim: true}
      )
    else
      nil
    end
  end

  defp queued_steer_banner(nil, _avail_width), do: nil

  defp queued_steer_banner(%{text: text}, avail_width) do
    content = truncate_to_width(@steer_prefix <> text, avail_width)

    Components.text(
      id: "queued-steer-banner",
      content: content,
      style: %{dim: true}
    )
  end

  defp truncate_to_width(text, width) when is_integer(width) and width > 0 do
    if TextMeasure.display_width(text) <= width do
      text
    else
      {left, _rest} =
        TextMeasure.split_at_display_width(text, max(width - 1, 0))

      left <> "…"
    end
  end

  defp truncate_to_width(text, _width), do: text
end
