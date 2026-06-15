# Focus Demo
#
# Demonstrates automatic Tab/Shift+Tab focus cycling via Raxol.Core.Focus.
# Tab moves focus forward, Shift+Tab moves backwards, focus wraps around.
#
# Usage:
#   mix run examples/apps/focus_demo.exs

defmodule FocusDemo do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    setup_focus([
      {"username", 0},
      {"password", 1},
      {"login", 2},
      {"cancel", 3}
    ])

    %{username: "", password: ""}
  end

  @impl true
  def update(message, model) do
    case message do
      {:focus_changed, _old, _new} ->
        {model, []}

      {:key_press, :char, %{char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    focus_label = current_focus() || "none"

    column style: %{padding: 1, gap: 1} do
      [
        text("Focus Demo -- Tab / Shift+Tab to cycle", style: [:bold]),
        text(""),
        box style: focus_style("username") do
          text("Username: #{model.username}")
        end,
        box style: focus_style("password") do
          text("Password: #{model.password}")
        end,
        row style: %{gap: 2} do
          [
            box style: focus_style("login") do
              text("[ Login ]")
            end,
            box style: focus_style("cancel") do
              text("[ Cancel ]")
            end
          ]
        end,
        text(""),
        text("Focused: #{focus_label}"),
        text("Press 'q' or Ctrl+C to quit")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []

  defp focus_style(id) do
    if focused?(id) do
      %{border: :double, padding: 0}
    else
      %{border: :single, padding: 0}
    end
  end
end

Raxol.Core.Runtime.Log.info("FocusDemo: Starting...")
{:ok, pid} = Raxol.start_link(FocusDemo, [])

ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
