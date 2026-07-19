defmodule Raxol.Playground.Demos.TextAreaDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.TextArea` — the REAL component,
  mounted controlled (state lives in this demo's model, every key routes through
  `TextArea.handle_event/3`).

  TextArea is a thin public wrapper over `MultiLineInput` (init/update/
  handle_event/render all delegate). Features inherited: line wrapping,
  scrolling, selection, undo/redo, placeholder, focus. There is **no vim
  insert/normal mode** in the component — the previous hand-rolled demo
  invented that; real editing is always "insert".

  Stories (top to bottom): interactive (receives keys, multi-line sample),
  empty+placeholder (unfocused).

  ## Contract warts

  - `handle_event/3` returns `{:noreply, state, cmds}` (3-tuple) after the
    EventHandler → update path, or the same shape on no-op. Normalize in
    `unwrap/2`.
  - `update({:update_props, props}, state)` also returns
    `{:noreply, state, nil}`.
  - Keys are normalized inside MultiLineInput.EventHandler via
    `InputEvent.normalize/1`, so playground `%{key: :char, char: ch}` Events
    pass through without demo-side reshaping (unlike TextInput).
  - `mount/1` returns bare state (not `{state, cmds}`).
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Input.TextArea

  @area_width 40
  @area_height 5
  @sample_value "Hello, world!\nEdit me with arrows\nThird line"
  # MultiLineInput.render does context.theme (not Map.get) — empty map crashes.
  @render_ctx %{theme: %{}}

  @impl true
  def init(_context) do
    %{
      main:
        field!(%{
          id: "ta-main",
          value: @sample_value,
          placeholder: "Type multi-line notes...",
          focused: true,
          width: @area_width,
          height: @area_height,
          wrap: :word
        }),
      placeholder_story:
        field!(%{
          id: "ta-placeholder",
          value: "",
          placeholder: "Empty — placeholder shows when unfocused",
          focused: false,
          width: @area_width,
          height: 3,
          wrap: :word
        }),
      event_log: []
    }
  end

  defp field!(props) do
    {:ok, state} = TextArea.init(props)
    state
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("f", ctrl: true) ->
        msg = if model.main.focused, do: :blur, else: :focus
        {field, model} = apply_update(model, msg, inspect(msg))
        {%{model | main: field}, []}

      key_match("x", ctrl: true) ->
        {field, model} =
          apply_update(
            model,
            {:update_props, %{value: "", cursor_pos: {0, 0}}},
            "clear -> value=\"\""
          )

        {%{model | main: field}, []}

      %Event{type: :key} = event ->
        case key_summary(event) do
          nil ->
            {model, []}

          summary ->
            {field, model} = apply_event(model, event, summary)
            {%{model | main: field}, []}
        end

      _ ->
        {model, []}
    end
  end

  # Summarize for the event log; return nil for keys we don't want to spam
  # (e.g. pure modifier chords the component ignores).
  defp key_summary(%Event{type: :key, data: data}) do
    case data do
      %{key: :char, char: ch} when is_binary(ch) -> "key #{inspect(ch)}"
      %{key: k} when is_atom(k) and k != :char -> "key #{inspect(k)}"
      _ -> nil
    end
  end

  defp apply_event(model, event, summary) do
    result = TextArea.handle_event(event, model.main, %{})
    field = unwrap(result, model.main)
    {field, DemoHelpers.log_event(model, outcome(summary, field))}
  end

  defp apply_update(model, msg, summary) do
    result = TextArea.update(msg, model.main)
    field = unwrap(result, model.main)
    {field, DemoHelpers.log_event(model, outcome(summary, field))}
  end

  defp outcome(summary, field) do
    {row, col} = field.cursor_pos
    lines = length(field.lines || [])
    chars = String.length(field.value || "")

    "#{summary} -> chars=#{chars} lines=#{lines} cursor={#{row},#{col}} " <>
      "focused=#{field.focused}"
  end

  # MultiLineInput shape zoo: {:noreply, state, cmds} is the common path.
  defp unwrap({:noreply, state, _cmds}, _fallback) when is_map(state), do: state
  defp unwrap({:noreply, state}, _fallback) when is_map(state), do: state
  defp unwrap({:ok, state}, _fallback) when is_map(state), do: state
  defp unwrap({:update, state, _cmds}, _fallback) when is_map(state), do: state
  defp unwrap({state, _cmds}, _fallback) when is_map(state), do: state
  defp unwrap(%{} = state, _fallback), do: state
  defp unwrap(_other, fallback), do: fallback

  @impl true
  def view(model) do
    main = model.main
    {row, col} = main.cursor_pos
    chars = String.length(main.value || "")
    line_count = length(main.lines || [])

    column style: %{gap: 0} do
      [
        text("TextArea — Raxol.UI.Components.Input.TextArea", style: [:bold]),
        text(" (thin wrapper over MultiLineInput; always-insert, no vim modes)",
          style: [:dim]
        ),
        text(""),
        text(" interactive (keys route here):", style: [:dim]),
        TextArea.render(main, @render_ctx),
        text(
          "   chars: #{chars}  lines: #{line_count}  cursor: {#{row},#{col}}",
          style: [:dim]
        ),
        text(""),
        text(" empty + placeholder (unfocused):", style: [:dim]),
        TextArea.render(model.placeholder_story, @render_ctx),
        text(""),
        text(
          " [type] insert  [enter] newline  [←↑↓→ home end] move  [bksp del] delete  [^f] focus  [^x] clear",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
