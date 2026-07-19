defmodule Raxol.Playground.Demos.CheckboxDemo do
  @moduledoc """
  Playground demo: `Raxol.UI.Components.Input.Checkbox` — the REAL
  component, mounted controlled (state lives in this demo's model, every
  toggle routes through `Checkbox.handle_event/3`).

  Checkbox is a single boolean toggle with a label. It responds to
  `:space` and mouse press; it has no built-in list navigation. The demo
  owns focus movement (`j`/`k` / arrows) across a list of mounted
  checkboxes and routes space/click to the focused one.

  Stories shown (top to bottom): interactive list (receives keys),
  disabled checkbox (space ignored), pre-checked required checkbox.

  Contract wart: `Checkbox.init/1` takes a keyword list (not a map like
  SelectList/PasswordField). `handle_event/3` expects
  `%Event{type: :key, data: %{key: :space}}` — playground char space
  (`%{key: :char, char: " "}`) must be translated. Return shape is
  always `{state, commands}`.
  """
  use Raxol.Core.Runtime.Application

  alias Raxol.Core.Events.Event
  alias Raxol.Playground.DemoHelpers
  alias Raxol.UI.Components.Input.Checkbox

  @impl true
  def init(_context) do
    boxes = [
      box!(id: "cb-notif", label: "Enable notifications", checked: false),
      box!(id: "cb-dark", label: "Dark mode", checked: true),
      box!(id: "cb-autosave", label: "Auto-save", checked: false),
      box!(id: "cb-linenums", label: "Show line numbers", checked: true),
      box!(id: "cb-wrap", label: "Word wrap", checked: false)
    ]

    %{
      checkboxes: focus_at(boxes, 0),
      focus_index: 0,
      disabled_story:
        box!(id: "cb-disabled", label: "Disabled option", checked: false, disabled: true),
      required_story:
        box!(
          id: "cb-required",
          label: "I agree to the terms (required)",
          checked: true,
          required: true
        ),
      event_log: []
    }
  end

  defp box!(props) do
    {:ok, state} = Checkbox.init(props)
    state
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("j") ->
        move_focus(model, 1)

      key_match(:down) ->
        move_focus(model, 1)

      key_match("k") ->
        move_focus(model, -1)

      key_match(:up) ->
        move_focus(model, -1)

      key_match("a") ->
        toggle_all(model)

      # Space (char or :space atom) toggles the focused checkbox
      key_match(" ") ->
        apply_toggle(model, "key :space")

      key_match(:space) ->
        apply_toggle(model, "key :space")

      %Event{type: :mouse, data: %{action: :press}} ->
        apply_toggle(model, "mouse press")

      _ ->
        {model, []}
    end
  end

  defp move_focus(model, delta) do
    max_i = length(model.checkboxes) - 1
    new_i = model.focus_index + delta |> max(0) |> min(max_i)
    boxes = focus_at(model.checkboxes, new_i)
    label = Enum.at(boxes, new_i).label
    model = DemoHelpers.log_event(model, "focus -> ##{new_i} #{inspect(label)}")
    {%{model | checkboxes: boxes, focus_index: new_i}, []}
  end

  defp focus_at(boxes, index) do
    Enum.with_index(boxes)
    |> Enum.map(fn {box, i} -> %{box | focused: i == index} end)
  end

  defp apply_toggle(model, summary) do
    idx = model.focus_index
    box = Enum.at(model.checkboxes, idx)
    event = %Event{type: :key, data: %{key: :space}}
    result = Checkbox.handle_event(event, box, %{})
    new_box = unwrap(result, box)

    outcome =
      if new_box == box and box.disabled do
        "#{summary} -> ignored (disabled) #{inspect(box.label)}"
      else
        "#{summary} -> #{inspect(box.label)} checked=#{new_box.checked}"
      end

    boxes =
      model.checkboxes
      |> List.replace_at(idx, new_box)
      |> focus_at(idx)

    model = DemoHelpers.log_event(model, outcome)
    {%{model | checkboxes: boxes}, []}
  end

  defp toggle_all(model) do
    all_checked? =
      model.checkboxes
      |> Enum.reject(& &1.disabled)
      |> Enum.all?(& &1.checked)

    boxes =
      Enum.map(model.checkboxes, fn box ->
        if box.disabled, do: box, else: %{box | checked: not all_checked?}
      end)
      |> focus_at(model.focus_index)

    model =
      DemoHelpers.log_event(
        model,
        "toggle all -> checked=#{not all_checked?} (n=#{length(boxes)})"
      )

    {%{model | checkboxes: boxes}, []}
  end

  defp unwrap({:noreply, state}, _fallback), do: state
  defp unwrap({:ok, state}, _fallback), do: state
  defp unwrap({:handled, state}, _fallback), do: state
  defp unwrap({state, _cmds}, _fallback) when is_map(state), do: state

  @impl true
  def view(model) do
    checked_count = Enum.count(model.checkboxes, & &1.checked)

    interactive_rows =
      Enum.map(model.checkboxes, fn box ->
        marker = if box.focused, do: ">", else: " "

        row style: %{gap: 1} do
          [
            text(marker, style: [:bold]),
            Checkbox.render(box, %{})
          ]
        end
      end)

    column style: %{gap: 0} do
      [
        text("Checkbox — Raxol.UI.Components.Input.Checkbox", style: [:bold]),
        text(" (controlled mount; space/click toggle via Checkbox.handle_event)", style: [:dim]),
        text(""),
        text(" interactive list (j/k moves focus, space toggles):", style: [:dim]),
        column(style: %{gap: 0}, do: interactive_rows),
        text(" checked: #{checked_count}/#{length(model.checkboxes)}", style: [:bold]),
        text(""),
        text(" disabled (space ignored):", style: [:dim]),
        Checkbox.render(model.disabled_story, %{}),
        text(""),
        text(" required (pre-checked story):", style: [:dim]),
        Checkbox.render(model.required_story, %{}),
        text(""),
        text(
          " [j/k ↑↓] focus  [space] toggle  [a] toggle all",
          style: [:dim]
        ),
        text("")
      ] ++ DemoHelpers.event_log_lines(model)
    end
  end

  @impl true
  def subscribe(_model), do: []
end
