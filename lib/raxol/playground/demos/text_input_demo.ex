defmodule Raxol.Playground.Demos.TextInputDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.TextInput` — the REAL component,
  mounted controlled (state lives in this demo's model, every key routes through
  `TextInput.handle_event/3`).

  ## Why TextInput (not TextField / SingleLineInput)

  Three single-line modules exist:

  - **TextInput** — public Event-based API with `max_length`, `validator`,
    `on_change`/`on_submit`, `mask_char`, plus MCP ToolProvider + a11y.
    View DSL emits `type: :text_input`. This is the storybook entry.
  - **TextField** — cell-aware scroll, `disabled`, `secret`. Substrate for
    `PasswordField` (see PasswordFieldDemo). Parallel API, not a wrapper.
  - **SingleLineInput** — simpler older substrate; not demoed separately.

  Stories (top to bottom): interactive (receives keys), empty+placeholder,
  filled (unfocused), max_length cap. TextInput has **no `disabled` prop**
  (unlike TextField) — that is the honest gap; ^d is a *demo-level* mute that
  stops routing, not a component feature.

  ## Contract warts

  - Playground keys arrive as `%{key: :char, char: ch}`; TextInput's KeyHandler
    reads `data.key` as the character (tests use `Event.key("a")`). The demo
    translates `:char` events into that shape.
  - `handle_event/3` returns `{state, commands}` consistently (cleaner than
    TextField's `{:noreply, state}` / `{state, commands}` zoo).
  - `update/2` returns a bare state map for `:update_props`.
  - Escape blurs (`focused: false`) inside the component; ^f re-focuses via
    `%{type: :focus}`.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Input.TextInput

  @max_length_story 8
  # TextInput.render reads context.theme[:input]; empty map is fine.
  @render_ctx %{theme: %{}}

  @impl true
  def init(_context) do
    %{
      main:
        field!(%{
          id: "ti-main",
          placeholder: "Type here...",
          focused: true
        }),
      placeholder_story:
        field!(%{
          id: "ti-placeholder",
          placeholder: "Enter your name...",
          focused: false
        }),
      filled_story:
        field!(%{
          id: "ti-filled",
          value: "already filled",
          focused: false
        }),
      max_length_story:
        field!(%{
          id: "ti-maxlen",
          value: "12345678",
          max_length: @max_length_story,
          focused: false
        }),
      # Demo-level mute only — TextInput has no disabled prop.
      muted: false,
      event_log: []
    }
  end

  defp field!(props) do
    {:ok, state} = TextInput.init(props)
    # API wart: init always sets focused: false and cursor_pos: 0, ignoring
    # those props. Re-apply them so storybook stories can start focused/filled.
    focused = Map.get(props, :focused, false)
    value = state.value
    cursor = Map.get(props, :cursor_pos, String.length(value))
    %{state | focused: focused, cursor_pos: cursor}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("f", ctrl: true) ->
        event = if model.main.focused, do: %{type: :blur}, else: %{type: :focus}
        {field, model} = apply_field(model, event, inspect(event))
        {%{model | main: field}, []}

      key_match("d", ctrl: true) ->
        muted? = not model.muted
        model = DemoHelpers.log_event(model, "demo muted=#{muted?} (no component disabled)")
        {%{model | muted: muted?}, []}

      key_match("x", ctrl: true) ->
        field = apply_props(model.main, %{value: "", cursor_pos: 0})
        model = DemoHelpers.log_event(model, "clear -> value=\"\"")
        {%{model | main: field}, []}

      _ ->
        cond do
          model.muted ->
            case translate_event(message) do
              nil ->
                {model, []}

              {_event, summary} ->
                model =
                  DemoHelpers.log_event(model, "#{summary} -> ignored (demo muted)")

                {model, []}
            end

          true ->
            case translate_event(message) do
              nil ->
                {model, []}

              {event, summary} ->
                {field, model} = apply_field(model, event, summary)
                {%{model | main: field}, []}
            end
        end
    end
  end

  # Playground Event shape -> TextInput's Event.key vocabulary
  # (data.key is the character string or special-key atom, not :char).
  defp translate_event(%Event{type: :key, data: data}) do
    case data do
      %{key: :char, char: ch} when is_binary(ch) ->
        {Event.key(ch), "key #{inspect(ch)}"}

      %{key: k}
      when k in [:backspace, :delete, :left, :right, :home, :end, :enter, :escape] ->
        {Event.key(k), "key #{inspect(k)}"}

      _ ->
        nil
    end
  end

  defp translate_event(_other), do: nil

  defp apply_field(model, event, summary) do
    result = TextInput.handle_event(event, model.main, %{})
    field = unwrap(result, model.main)

    outcome =
      "#{summary} -> len=#{String.length(field.value || "")} " <>
        "cursor=#{field.cursor_pos} focused=#{field.focused}"

    {field, DemoHelpers.log_event(model, outcome)}
  end

  defp unwrap({state, _cmds}, _fallback) when is_map(state), do: state
  defp unwrap({:noreply, state}, _fallback) when is_map(state), do: state
  defp unwrap({:ok, state}, _fallback) when is_map(state), do: state
  defp unwrap(%{} = state, _fallback), do: state
  defp unwrap(_other, fallback), do: fallback

  defp apply_props(field, props) do
    case TextInput.update({:update_props, props}, field) do
      %{} = state -> state
      other -> unwrap(other, field)
    end
  end

  @impl true
  def view(model) do
    main = model.main
    char_count = String.length(main.value || "")
    muted_note = if model.muted, do: " [MUTED]", else: ""

    column style: %{gap: 0} do
      [
        text("TextInput — Raxol.UI.Components.Input.TextInput", style: [:bold]),
        text(
          " (Event-based; max_length/validator/on_change; no disabled — see TextField)",
          style: [:dim]
        ),
        text(""),
        text(" interactive (keys route here)#{muted_note}:", style: [:dim]),
        TextInput.render(main, @render_ctx),
        text("   chars: #{char_count}  cursor: #{main.cursor_pos}", style: [:dim]),
        text(""),
        text(" empty + placeholder (unfocused):", style: [:dim]),
        TextInput.render(model.placeholder_story, @render_ctx),
        text(""),
        text(" filled (unfocused):", style: [:dim]),
        TextInput.render(model.filled_story, @render_ctx),
        text(""),
        text(" max_length=#{@max_length_story} (capped, unfocused):", style: [:dim]),
        TextInput.render(model.max_length_story, @render_ctx),
        text(""),
        text(
          " [type] insert  [← → home end] move  [bksp del] delete  [^f] focus  [^d] mute  [^x] clear",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
