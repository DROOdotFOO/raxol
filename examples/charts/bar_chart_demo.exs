defmodule BarChartDemo do
  @moduledoc """
  Live BEAM memory breakdown as grouped bar chart.
  Shows total/processes/binary/ets memory in MB. 1s tick.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Charts.{BarChart, ViewBridge}

  @impl true
  def init(_context) do
    %{tick: 0}
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        {%{model | tick: model.tick + 1}, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    mem = :erlang.memory()
    total = mem[:total] / 1_048_576
    procs = mem[:processes] / 1_048_576
    binary = mem[:binary] / 1_048_576
    ets = mem[:ets] / 1_048_576

    series = [
      %{name: "Total", data: [total], color: :cyan},
      %{name: "Processes", data: [procs], color: :magenta},
      %{name: "Binary", data: [binary], color: :yellow},
      %{name: "ETS", data: [ets], color: :green}
    ]

    v_cells =
      BarChart.render({1, 3, 35, 15}, series,
        show_legend: true,
        show_values: true,
        max: total * 1.2
      )

    h_cells =
      BarChart.render({38, 3, 40, 15}, series,
        orientation: :horizontal,
        show_values: true,
        max: total * 1.2
      )

    column style: %{padding: 1} do
      [
        text("BEAM Memory - Bar Charts", style: [:bold], fg: :cyan),
        text("Tick #{model.tick} | Total: #{Float.round(total, 1)} MB",
          style: [:dim]
        ),
        row style: %{gap: 2} do
          [
            ViewBridge.cells_to_view(v_cells),
            ViewBridge.cells_to_view(h_cells)
          ]
        end,
        text("Press q to quit", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(1000, :tick)]
  end
end

Raxol.start_link(BarChartDemo)
