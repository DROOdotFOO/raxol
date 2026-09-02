defmodule Raxol.Playground.Demos.LineChartDemo do
  @moduledoc "Playground demo: streaming braille-resolution line chart."
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @data_points 30
  @default_chart_width 60
  @chart_height 15
  @tick_interval_ms Raxol.Core.Defaults.animation_duration_ms()

  @sine_baseline 50
  @sine_amplitude 40
  @sine_frequency 0.2
  @cosine_amplitude 25
  @cosine_frequency 0.15

  @impl true
  def init(_context) do
    %{tick: 0, show_legend: true, show_axes: false}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("l") ->
        {%{model | show_legend: not model.show_legend}, []}

      key_match("a") ->
        {%{model | show_axes: not model.show_axes}, []}

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
    # snippet:start
    series = build_series(model.tick)

    chart_element =
      line_chart(
        series: series,
        width: effective_width(model, @default_chart_width),
        height: @chart_height,
        show_legend: model.show_legend,
        show_axes: model.show_axes
      )

    # snippet:end

    legend_label = if model.show_legend, do: "ON", else: "OFF"
    axes_label = if model.show_axes, do: "ON", else: "OFF"

    column style: %{gap: 1} do
      [
        text("LineChart Demo", style: [:bold]),
        divider(),
        chart_element,
        text(
          "Legend: #{legend_label}  Axes: #{axes_label}  Tick: #{model.tick}"
        ),
        text("[l] legend  [a] axes  [r] reset", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_interval_ms, :tick)]

  defp build_series(tick) do
    range = 0..(@data_points - 1)

    data_a =
      for i <- range,
          do:
            round(
              @sine_baseline +
                @sine_amplitude * :math.sin((tick + i) * @sine_frequency)
            )

    data_b =
      for i <- range,
          do:
            round(
              @sine_baseline +
                @cosine_amplitude * :math.cos((tick + i) * @cosine_frequency)
            )

    [
      %{name: "Sine", data: data_a, color: :cyan},
      %{name: "Cosine", data: data_b, color: :magenta}
    ]
  end
end
