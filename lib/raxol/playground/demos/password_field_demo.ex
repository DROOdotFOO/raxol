defmodule Raxol.Playground.Demos.PasswordFieldDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.PasswordField` — the REAL
  component, mounted controlled (state lives in this demo's model, every
  key routes through `PasswordField.handle_event/3`).

  PasswordField is a thin wrapper over `TextField` that forces
  `secret: true`: the value renders as one `•` per grapheme. There is no
  visibility toggle and no strength meter in the component — those were
  inventions of the previous hand-rolled demo; what the component actually
  provides is placeholder rendering, a `|` cursor while focused, cell-aware
  horizontal scrolling for long secrets (CJK/emoji safe), and a disabled
  state that swallows keypresses.

  Stories shown (top to bottom): interactive (receives keys), placeholder
  (empty + unfocused), long secret (scroll window), disabled.

  Contract wart surfaced honestly: `TextField.handle_event/3` returns
  `{:noreply, state}` for keypresses (a 2-tuple outside the
  `Base.Component` contract's listed shapes) but `{state, commands}` for
  focus/blur. `apply_field/2` normalizes both. A follow-up should align
  TextField (+ its tests) with the contract.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Input.PasswordField

  @field_width 24
  @scrolled_width 14
  @long_secret "sup3r-s3cret-with-a-very-long-tail"

  @impl true
  def init(_context) do
    %{
      main: field!(%{id: "pw-main", placeholder: "hunter2", focused: true}),
      placeholder_story:
        field!(%{id: "pw-placeholder", placeholder: "correct horse battery staple"}),
      # Build empty then apply value via :update_props so scroll_offset
      # is reconciled cell-aware (init alone does not adjust scroll).
      scrolled_story:
        field!(%{id: "pw-scrolled", focused: true, width: @scrolled_width})
        |> then(fn f ->
          apply_props(f, %{
            value: @long_secret,
            cursor_pos: String.length(@long_secret)
          })
        end),
      disabled_story: field!(%{id: "pw-disabled", value: "cannot-edit", disabled: true}),
      event_log: []
    }
  end

  defp field!(props) do
    {:ok, state} = PasswordField.init(Map.put_new(props, :width, @field_width))
    state
  end

  @impl true
  def update(message, model) do
    case message do
      # -- demo chords (control the stories, never reach the field) --
      key_match("f", ctrl: true) ->
        event = if model.main.focused, do: {:blur}, else: {:focus}
        {field, model} = apply_field(model, event, inspect(event))
        {%{model | main: field}, []}

      key_match("d", ctrl: true) ->
        disabled? = not model.main.disabled
        field = apply_props(model.main, %{disabled: disabled?})
        model = DemoHelpers.log_event(model, "props disabled=#{disabled?}")
        {%{model | main: field}, []}

      key_match("x", ctrl: true) ->
        field = apply_props(model.main, %{value: "", cursor_pos: 0, scroll_offset: 0})
        model = DemoHelpers.log_event(model, "clear -> value=\"\"")
        {%{model | main: field}, []}

      # -- everything else routes to the real component --
      _ ->
        case field_event(message) do
          nil ->
            {model, []}

          {event, summary} ->
            {field, model} = apply_field(model, event, summary)
            {%{model | main: field}, []}
        end
    end
  end

  # Playground key events -> TextField's `{:keypress, key, mods}` vocabulary.
  defp field_event(%Raxol.Core.Events.Event{type: :key, data: data}) do
    case data do
      %{key: :char, char: ch} -> {{:keypress, ch, []}, "key #{inspect(ch)}"}
      %{key: :backspace} -> {{:keypress, :backspace, []}, "key :backspace"}
      %{key: :delete} -> {{:keypress, :delete, []}, "key :delete"}
      %{key: :left} -> {{:keypress, :arrow_left, []}, "key :left"}
      %{key: :right} -> {{:keypress, :arrow_right, []}, "key :right"}
      %{key: :home} -> {{:keypress, :home, []}, "key :home"}
      %{key: :end} -> {{:keypress, :end, []}, "key :end"}
      _ -> nil
    end
  end

  defp field_event(_other), do: nil

  # Route one event through the REAL component, normalizing its return
  # shapes, and log the outcome the component actually produced.
  defp apply_field(model, event, summary) do
    result = PasswordField.handle_event(event, model.main, %{})
    field = unwrap(result, model.main)

    outcome =
      if field == model.main and model.main.disabled do
        "#{summary} -> ignored (disabled)"
      else
        "#{summary} -> len=#{String.length(field.value)} " <>
          "cursor=#{field.cursor_pos} scroll=#{field.scroll_offset}"
      end

    {field, DemoHelpers.log_event(model, outcome)}
  end

  # TextField.update/2 returns a bare state for :update_props and
  # {:noreply, state} otherwise; handle_event/3 adds {state, commands},
  # {:handled, state}, and :passthrough to the shape zoo. Normalize.
  defp unwrap({:noreply, state}, _fallback), do: state
  defp unwrap({:ok, state}, _fallback), do: state
  defp unwrap({:update, state, _cmds}, _fallback), do: state
  defp unwrap({:handled, state}, _fallback), do: state
  defp unwrap({state, _cmds}, _fallback), do: state
  defp unwrap(:passthrough, fallback), do: fallback

  defp apply_props(field, props) do
    case PasswordField.update({:update_props, props}, field) do
      %{} = state -> state
      other -> unwrap(other, field)
    end
  end

  @impl true
  def view(model) do
    column style: %{gap: 0} do
      [
        text("PasswordField — Raxol.UI.Components.Input.PasswordField", style: [:bold]),
        text(" (TextField with secret: true; one • per grapheme)", style: [:dim]),
        text(""),
        text(" interactive (keys route here):", style: [:dim]),
        PasswordField.render(model.main, %{}),
        text(""),
        text(" placeholder (empty + unfocused):", style: [:dim]),
        PasswordField.render(model.placeholder_story, %{}),
        text(""),
        text(" long secret (cell-scroll window, width #{@scrolled_width}):", style: [:dim]),
        PasswordField.render(model.scrolled_story, %{}),
        text(""),
        text(" disabled (keypresses ignored):", style: [:dim]),
        PasswordField.render(model.disabled_story, %{}),
        text(""),
        text(
          " [type] insert  [← → home end] move  [bksp del] delete  [^f] focus  [^d] disable  [^x] clear",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
