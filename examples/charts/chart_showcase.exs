defmodule ChartShowcase do
  @moduledoc """
  All 4 chart types in a 2x2 grid, all streaming live data.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Charts.{LineChart, ScatterChart, BarChart, Heatmap, ViewBridge}

  @max_points 60

  @impl true
  def init(_context) do
    :erlang.system_flag(:scheduler_wall_time, true)

    %{
      tick: 0,
      sine_a: [],
      sine_b: [],
      scatter: [],
      sched_prev: :erlang.statistics(:scheduler_wall_time) |> Enum.sort(),
      heat_history: []
    }
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        t = model.tick * 0.15

        # Line chart data
        a = :math.sin(t) * 40 + 50
        b = :math.cos(t * 0.8) * 30 + 50

        # Scatter data
        sx = 50 + :rand.normal() * 15
        sy = 50 + :rand.normal() * 15

        # Heatmap: scheduler utilization
        curr = :erlang.statistics(:scheduler_wall_time) |> Enum.sort()

        utils =
          Enum.zip(model.sched_prev, curr)
          |> Enum.map(fn {{_id, a1, t1}, {_id2, a2, t2}} ->
            delta = t2 - t1
            if delta > 0, do: round((a2 - a1) / delta * 100), else: 0
          end)

        {%{
           model
           | tick: model.tick + 1,
             sine_a: [a | model.sine_a] |> Enum.take(@max_points),
             sine_b: [b | model.sine_b] |> Enum.take(@max_points),
             scatter: [{sx, sy} | model.scatter] |> Enum.take(200),
             sched_prev: curr,
             heat_history: [utils | model.heat_history] |> Enum.take(30)
         }, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    # Top-left: Line chart
    line_series = [
      %{name: "Sin", data: Enum.reverse(model.sine_a), color: :cyan},
      %{name: "Cos", data: Enum.reverse(model.sine_b), color: :magenta}
    ]

    line_cells =
      LineChart.render({0, 0, 38, 10}, line_series, show_legend: true)

    # Top-right: Scatter
    scatter_series = [
      %{name: "Cloud", data: model.scatter, color: :yellow}
    ]

    scatter_cells =
      ScatterChart.render({0, 0, 38, 10}, scatter_series,
        x_range: {0.0, 100.0},
        y_range: {0.0, 100.0}
      )

    # Bottom-left: Bar chart (BEAM memory)
    mem = :erlang.memory()
    total = mem[:total] / 1_048_576
    procs = mem[:processes] / 1_048_576
    binary = mem[:binary] / 1_048_576

    bar_series = [
      %{name: "Tot", data: [total], color: :cyan},
      %{name: "Proc", data: [procs], color: :green},
      %{name: "Bin", data: [binary], color: :yellow}
    ]

    bar_cells =
      BarChart.render({0, 0, 38, 9}, bar_series,
        show_values: true,
        max: total * 1.2
      )

    # Bottom-right: Heatmap (scheduler util)
    num_sched = length(model.sched_prev)

    history = Enum.reverse(model.heat_history)

    heat_data =
      for s <- 0..(num_sched - 1) do
        Enum.map(history, fn snap -> Enum.at(snap, s, 0) end)
      end

    heat_cells =
      Heatmap.render({0, 0, 38, min(num_sched * 2, 9)}, heat_data,
        color_scale: :warm,
        min: 0,
        max: 100
      )

    column style: %{padding: 1, gap: 0} do
      [
        text("Chart Showcase - All 4 Types", style: [:bold], fg: :cyan),
        spacer(size: 1),
        row style: %{gap: 2} do
          [
            box style: %{border: :single, width: 40, padding: 0} do
              column do
                [
                  text(" Braille Line Chart", style: [:bold], fg: :cyan),
                  ViewBridge.cells_to_view(line_cells)
                ]
              end
            end,
            box style: %{border: :single, width: 40, padding: 0} do
              column do
                [
                  text(" Braille Scatter Plot", style: [:bold], fg: :yellow),
                  ViewBridge.cells_to_view(scatter_cells)
                ]
              end
            end
          ]
        end,
        row style: %{gap: 2} do
          [
            box style: %{border: :single, width: 40, padding: 0} do
              column do
                [
                  text(" Block Bar Chart", style: [:bold], fg: :green),
                  ViewBridge.cells_to_view(bar_cells)
                ]
              end
            end,
            box style: %{border: :single, width: 40, padding: 0} do
              column do
                [
                  text(" Scheduler Heatmap", style: [:bold], fg: :red),
                  ViewBridge.cells_to_view(heat_cells)
                ]
              end
            end
          ]
        end,
        text("Tick #{model.tick} | Press q to quit", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(500, :tick)]
  end
end

Raxol.start_link(ChartShowcase)
