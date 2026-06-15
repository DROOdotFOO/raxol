# Advanced Layout
#
# Demonstrates nested row/column layouts with different alignment options.
#
# Usage:
#   mix run examples/advanced/architecture/advanced_layout_test.exs

defmodule AdvancedLayoutExample do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context), do: %{}

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
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
  def view(_model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Advanced Layout Example", style: [:bold]),
        row style: %{gap: 2} do
          [
            box title: "Sidebar",
                style: %{border: :single, padding: 1, width: 20} do
              column style: %{gap: 1} do
                [
                  button("Nav 1", on_click: :nav1),
                  button("Nav 2", on_click: :nav2),
                  button("Nav 3", on_click: :nav3)
                ]
              end
            end,
            box title: "Main Content", style: %{border: :single, padding: 1} do
              column style: %{gap: 1} do
                [
                  text("This is the main content area."),
                  row style: %{gap: 1} do
                    [
                      text("Left"),
                      text("|"),
                      text("Center"),
                      text("|"),
                      text("Right")
                    ]
                  end,
                  text("Nested layouts are composed with row/column.")
                ]
              end
            end
          ]
        end,
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model), do: []
end

Raxol.Core.Runtime.Log.info("AdvancedLayoutExample: Starting...")
{:ok, pid} = Raxol.start_link(AdvancedLayoutExample, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
