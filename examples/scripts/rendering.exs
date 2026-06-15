# Rendering Demo
#
# A kitchen-sink example showing text styling, tables, and layout.
#
# Usage:
#   mix run examples/scripts/rendering.exs

defmodule RenderingDemo do
  use Raxol.Core.Runtime.Application

  require Raxol.Core.Runtime.Log

  @impl true
  def init(_context) do
    %{
      current_time: DateTime.utc_now(),
      table_data: [
        %{id: 1, name: "Item A", value: :rand.uniform(100)},
        %{id: 2, name: "Item B", value: :rand.uniform(100)},
        %{id: 3, name: "Item C", value: :rand.uniform(100)}
      ],
      overlay: true
    }
  end

  @impl true
  def update(message, model) do
    case message do
      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: " "}} ->
        {%{model | overlay: !model.overlay}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      %Raxol.Core.Events.Event{
        type: :key,
        data: %{key: :char, char: "c", ctrl: true}
      } ->
        {model, [Directive.stop()]}

      :tick ->
        new_model = %{
          model
          | current_time: DateTime.utc_now(),
            table_data:
              Enum.map(model.table_data, fn row ->
                %{row | value: :rand.uniform(100)}
              end)
        }

        {new_model, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    column style: %{padding: 1, gap: 1} do
      [
        text("Rendering Demo", style: [:bold]),
        row do
          [
            box title: "Text Styling", style: %{border: :single, padding: 1} do
              column style: %{gap: 1} do
                [
                  text("Normal text"),
                  text("Bold text", style: [:bold]),
                  text("Time: #{DateTime.to_string(model.current_time)}"),
                  text("Overlay: #{model.overlay} (press Space to toggle)")
                ]
              end
            end,
            box title: "Table", style: %{border: :single, padding: 1} do
              table(
                id: :demo_table,
                data: model.table_data,
                columns: [
                  %{header: "ID", key: :id, width: 5},
                  %{header: "Name", key: :name, width: 10},
                  %{header: "Value", key: :value, width: 10}
                ]
              )
            end
          ]
        end,
        text("Press 'q' or Ctrl+C to quit.")
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(500, :tick)]
  end
end

Raxol.Core.Runtime.Log.info("RenderingDemo: Starting...")
{:ok, pid} = Raxol.start_link(RenderingDemo, [])
ref = Process.monitor(pid)

receive do
  {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
end
