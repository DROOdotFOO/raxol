defmodule Raxol.Playground.Demos.SelectListDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.SelectList` — the REAL
  component, mounted controlled (state lives in this demo's model, every
  key routes through `SelectList.handle_event/3`).

  SelectList is always a visible list (not a closed dropdown). Features
  used here: single-select navigation, multi-select, search toggle, and
  an empty-options story.

  Stories shown (top to bottom): interactive single-select (receives
  keys), multi-select (read-only story of selected set), empty list.

  Contract warts surfaced honestly:
  * `SelectList.init/1` takes a **map** (unlike Checkbox/Menu/Tabs keywords).
  * Options are `{label, value}` tuples.
  * Key events: `handle_event` reads `data.key` only — playground
    `%{key: :char, char: "a"}` must be rewritten to `%{key: "a"}` for
    search characters; space is `:space` not `" "`.
  * Search filtering is debounced via `Process.send_after(self(),
    {:apply_search, text}, …)` — under controlled mount the TEA demo
    must forward `{:apply_search, _}` into `SelectList.update/2` or
    filtering never applies. Renderer also checks `search_enabled` /
    `search_active` while key logic uses `enable_search` /
    `is_search_focused` (dual field names).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Input.SelectList

  @lang_options [
    {"Elixir", :elixir},
    {"Rust", :rust},
    {"Go", :go},
    {"Python", :python},
    {"TypeScript", :typescript}
  ]

  @impl true
  def init(_context) do
    {:ok, main} =
      SelectList.init(%{
        id: "sl-main",
        options: @lang_options,
        label: "Language",
        has_focus: true,
        enable_search: true,
        # dual fields: renderer reads these, key logic reads enable_search
        search_enabled: true,
        visible_items: 5,
        max_height: 8
      })

    {:ok, multi} =
      SelectList.init(%{
        id: "sl-multi",
        options: [
          {"Bold", :bold},
          {"Italic", :italic},
          {"Underline", :underline}
        ],
        multiple: true,
        has_focus: false,
        visible_items: 3
      })

    # Pre-select first two for the multi story so the state is visible
    multi = %{
      multi
      | selected_indices: MapSet.new([0, 1]),
        selected_index: 0,
        focused_index: 0
    }

    {:ok, empty} =
      SelectList.init(%{
        id: "sl-empty",
        options: [],
        empty_message: "No options available",
        has_focus: false
      })

    %{
      main: main,
      multi_story: multi,
      empty_story: empty,
      event_log: []
    }
  end

  @impl true
  def update(message, model) do
    case message do
      # Debounced search applies via Process.send_after(self(), …) — forward it.
      {:apply_search, text} ->
        {list, _} = SelectList.update({:apply_search, text}, model.main)

        model =
          DemoHelpers.log_event(
            model,
            "apply_search #{inspect(text)} -> filter=#{list.is_filtering}"
          )

        {%{model | main: list}, []}

      _ ->
        case list_event(message) do
          nil ->
            {model, []}

          {event, summary} ->
            apply_list(model, event, summary)
        end
    end
  end

  # Playground Event -> SelectList key vocabulary (data.key is the only field read).
  defp list_event(%Event{type: :key, data: data}) do
    case data do
      %{key: :down} ->
        {%{type: :key, data: %{key: :down}}, "key :down"}

      %{key: :up} ->
        {%{type: :key, data: %{key: :up}}, "key :up"}

      %{key: :enter} ->
        {%{type: :key, data: %{key: :enter}}, "key :enter"}

      %{key: :space} ->
        {%{type: :key, data: %{key: :space}}, "key :space"}

      %{key: :tab} ->
        {%{type: :key, data: %{key: :tab}}, "key :tab"}

      %{key: :backspace} ->
        {%{type: :key, data: %{key: :backspace}}, "key :backspace"}

      %{key: :home} ->
        {%{type: :key, data: %{key: :home}}, "key :home"}

      %{key: :end} ->
        {%{type: :key, data: %{key: :end}}, "key :end"}

      %{key: :page_down} ->
        {%{type: :key, data: %{key: :page_down}}, "key :page_down"}

      %{key: :page_up} ->
        {%{type: :key, data: %{key: :page_up}}, "key :page_up"}

      # vim aliases for nav
      %{key: :char, char: "j"} ->
        {%{type: :key, data: %{key: :down}}, "key j→:down"}

      %{key: :char, char: "k"} ->
        {%{type: :key, data: %{key: :up}}, "key k→:up"}

      # space char -> :space
      %{key: :char, char: " "} ->
        {%{type: :key, data: %{key: :space}}, "key space"}

      # searchable chars: SelectList expects the binary itself as data.key
      %{key: :char, char: ch} when is_binary(ch) and byte_size(ch) == 1 ->
        {%{type: :key, data: %{key: ch}}, "key #{inspect(ch)} (search)"}

      _ ->
        nil
    end
  end

  defp list_event(%Event{type: :focus}) do
    {%{type: :focus}, "focus"}
  end

  defp list_event(%Event{type: :blur}) do
    {%{type: :blur}, "blur"}
  end

  defp list_event(_other), do: nil

  defp apply_list(model, event, summary) do
    before = model.main
    result = SelectList.handle_event(event, before, %{})
    list = unwrap(result, before)

    selected_label = option_label(list, list.selected_index || list.focused_index)

    outcome =
      cond do
        list.is_search_focused != before.is_search_focused ->
          "#{summary} -> search_focused=#{list.is_search_focused} buf=#{inspect(list.search_buffer)}"

        list.search_buffer != before.search_buffer ->
          "#{summary} -> search_buf=#{inspect(list.search_buffer)}"

        list.focused_index != before.focused_index or
            list.selected_index != before.selected_index ->
          "#{summary} -> focus=#{list.focused_index} selected=#{list.selected_index} (#{selected_label})"

        list.selected_indices != before.selected_indices ->
          "#{summary} -> selected_indices=#{inspect(MapSet.to_list(list.selected_indices))}"

        true ->
          "#{summary} -> focus=#{list.focused_index} selected=#{list.selected_index}"
      end

    model =
      model
      |> Map.put(:main, list)
      |> DemoHelpers.log_event(outcome)

    {model, []}
  end

  defp option_label(list, index) do
    opts = list.filtered_options || list.options

    case Enum.at(opts || [], index || 0) do
      {label, _} -> label
      {label, _, _} -> label
      _ -> "?"
    end
  end

  defp unwrap({:noreply, state}, _fallback), do: state
  defp unwrap({:ok, state}, _fallback), do: state
  defp unwrap({:update, state, _cmds}, _fallback), do: state
  defp unwrap({:handled, state}, _fallback), do: state
  defp unwrap({state, _cmds}, _fallback) when is_map(state), do: state
  defp unwrap({state, _cmds, _more}, _fallback) when is_map(state), do: state
  defp unwrap(:passthrough, fallback), do: fallback
  defp unwrap(nil, fallback), do: fallback
  defp unwrap(state, _fallback) when is_map(state), do: state

  @impl true
  def view(model) do
    main = model.main
    selected_label = option_label(main, main.selected_index || main.focused_index)

    multi_selected =
      model.multi_story.selected_indices
      |> MapSet.to_list()
      |> Enum.sort()
      |> Enum.map_join(", ", fn i ->
        case Enum.at(model.multi_story.options, i) do
          {label, _} -> label
          _ -> inspect(i)
        end
      end)

    search_hint =
      if main.is_search_focused do
        "search ON buf=#{inspect(main.search_buffer)} query=#{inspect(main.search_query)}"
      else
        "search OFF (tab toggles)"
      end

    column style: %{gap: 0} do
      [
        text("SelectList — Raxol.UI.Components.Input.SelectList", style: [:bold]),
        text(
          " (always-open list; not a closed dropdown — that was the old imitation)",
          style: [:dim]
        ),
        text(""),
        text(
          " interactive single-select (#{search_hint}):",
          style: [:dim]
        ),
        SelectList.render(model.main, %{}),
        text(" selected: #{selected_label}", style: [:bold]),
        text(""),
        text(" multi-select story (pre-checked Bold+Italic):", style: [:dim]),
        SelectList.render(model.multi_story, %{}),
        text(" multi selected: #{multi_selected}", style: [:dim]),
        text(""),
        text(" empty options story:", style: [:dim]),
        SelectList.render(model.empty_story, %{}),
        text(""),
        text(
          " [↑↓/jk] move  [enter/space] select  [tab] search focus  [type] filter  [bksp] erase",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
