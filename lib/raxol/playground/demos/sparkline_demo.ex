defmodule Raxol.Playground.Demos.SparklineDemo do
  @moduledoc "Playground demo: compact sparkline with live data."
  use Raxol.Core.Runtime.Application
  alias Raxol.Playground.DemoHelpers

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @data_points 40
  @default_spark_width 40
  @spark_height 5
  @tick_interval_ms 200

  # {baseline, amplitude, frequency} for each metric
  @cpu_wave {50, 30, 0.25}
  @mem_wave {60, 20, 0.18}
  @net_wave {30, 25, 0.3}

  @impl true
  def init(_context) do
    %{tick: 0, color: :cyan, colors: [:cyan, :green, :yellow, :magenta, :red]}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("c") ->
        idx = Enum.find_index(model.colors, &(&1 == model.color))

        next =
          Enum.at(
            model.colors,
            DemoHelpers.cycle_next(idx, length(model.colors))
          )

        {%{model | color: next}, []}

      key_match("r") ->
        {%{model | tick: 0}, []}

      :tick ->
        {%{model | tick: model.tick + 1}, []}

      _ ->
        {model, []}
    end
  end

  @impl true
  def view(model) do
    range = 0..(@data_points - 1)

    cpu_data = wave_data(range, model.tick, @cpu_wave, :sin)
    mem_data = wave_data(range, model.tick, @mem_wave, :cos)
    net_data = wave_data(range, model.tick, @net_wave, :sin)

    column style: %{gap: 1} do
      [
        text("Sparkline Demo", style: [:bold]),
        divider(),
        text("CPU Usage:", style: [:dim]),
        # snippet:start
        sparkline(
          data: cpu_data,
          width: effective_width(model, @default_spark_width),
          height: @spark_height,
          color: model.color
        ),
        # snippet:end
        text("Memory:", style: [:dim]),
        sparkline(
          data: mem_data,
          width: effective_width(model, @default_spark_width),
          height: @spark_height,
          color: :green
        ),
        text("Network I/O:", style: [:dim]),
        sparkline(
          data: net_data,
          width: effective_width(model, @default_spark_width),
          height: @spark_height,
          color: :yellow
        ),
        text("Color: #{model.color}  Tick: #{model.tick}"),
        text("[c] cycle color  [r] reset", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_interval_ms, :tick)]

  defp wave_data(range, tick, {baseline, amplitude, frequency}, :sin) do
    for i <- range,
        do: round(baseline + amplitude * :math.sin((tick + i) * frequency))
  end

  defp wave_data(range, tick, {baseline, amplitude, frequency}, :cos) do
    for i <- range,
        do: round(baseline + amplitude * :math.cos((tick + i) * frequency))
  end
end
