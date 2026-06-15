# Line Chart Demo
#
# Live braille line chart with 3 sine waves at different frequencies.
#
# What you'll learn:
#   - LineChart.render/3 takes bounds and series data, returns cell tuples
#   - ViewBridge.cells_to_view/1 converts raw cells into View DSL elements
#   - Braille rendering: each terminal cell encodes a 2x4 dot grid,
#     giving 2x vertical and 2x horizontal resolution vs normal chars
#
# Usage:
#   mix run examples/charts/line_chart_demo.exs
#
# Controls:
#   q = quit

defmodule LineChartDemo do
  use Raxol.Core.Runtime.Application

  # LineChart renders to raw cell tuples; ViewBridge converts them
  # into View DSL elements so they can be composed with text/box/column.
  alias Raxol.UI.Charts.{LineChart, ViewBridge}

  @max_points 80
  @tick_interval_ms 200
  @time_scale 0.1
  @chart_bounds {1, 2, 78, 20}

  # {frequency_multiplier, phase_offset, amplitude, baseline}
  @wave_a {1.0, 0.0, 50, 50}
  @wave_b {1.5, 1.0, 30, 50}
  @wave_c {0.7, 2.0, 40, 50}

  @impl true
  def init(_context) do
    %{tick: 0, series_a: [], series_b: [], series_c: []}
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        t = model.tick * @time_scale
        a = wave(t, @wave_a)
        b = wave(t, @wave_b)
        c = wave(t, @wave_c)

        {%{
           model
           | tick: model.tick + 1,
             series_a: [a | model.series_a] |> Enum.take(@max_points),
             series_b: [b | model.series_b] |> Enum.take(@max_points),
             series_c: [c | model.series_c] |> Enum.take(@max_points)
         }, []}

      %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: "q"}} ->
        {model, [Directive.stop()]}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    series = [
      %{name: "Alpha", data: Enum.reverse(model.series_a), color: :cyan},
      %{name: "Beta", data: Enum.reverse(model.series_b), color: :magenta},
      %{name: "Gamma", data: Enum.reverse(model.series_c), color: :yellow}
    ]

    # render/3 takes {x, y, width, height} bounds and a list of series.
    # Returns raw cell tuples that ViewBridge converts to View DSL elements.
    cells = LineChart.render(@chart_bounds, series, show_legend: true)

    column style: %{padding: 1} do
      [
        text("Braille Line Chart - 3 Sine Waves", style: [:bold], fg: :cyan),
        ViewBridge.cells_to_view(cells),
        text("Press q to quit", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(@tick_interval_ms, :tick)]
  end

  defp wave(t, {freq, phase, amplitude, baseline}) do
    :math.sin(t * freq + phase) * amplitude + baseline
  end
end

Raxol.start_link(LineChartDemo)
