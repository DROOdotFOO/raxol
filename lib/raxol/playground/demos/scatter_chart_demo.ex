defmodule Raxol.Playground.Demos.ScatterChartDemo do
  @moduledoc "Playground demo: braille scatter plot with animated clusters."
  use Raxol.Core.Runtime.Application

  import Raxol.Playground.DemoHelpers, only: [effective_width: 2]

  @points_per_cluster 20
  @default_chart_width 60
  @chart_height 15
  @tick_interval_ms 200
  @tick_scale 0.05

  # Cluster A: center, radius, angular speeds
  @cluster_a_cx 30
  @cluster_a_cy 20
  @cluster_a_radius 10
  @cluster_a_angle_speed 0.3
  @cluster_a_sin_speed 0.4

  # Cluster B: center, radius, angular speeds
  @cluster_b_cx 60
  @cluster_b_cy 40
  @cluster_b_radius 8
  @cluster_b_angle_speed 0.35
  @cluster_b_time_scale 1.2
  @cluster_b_cos_speed 0.25
  @cluster_b_cos_time_scale 0.8

  @impl true
  def init(_context) do
    %{tick: 0, show_legend: true}
  end

  @impl true
  def update(message, model) do
    case message do
      key_match("l") ->
        {%{model | show_legend: not model.show_legend}, []}

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
    series = build_series(model.tick)
    point_count = series |> Enum.map(fn s -> length(s.data) end) |> Enum.sum()

    # snippet:start
    chart_element =
      scatter_chart(
        series: series,
        width: effective_width(model, @default_chart_width),
        height: @chart_height,
        show_legend: model.show_legend
      )

    # snippet:end

    legend_label = if model.show_legend, do: "ON", else: "OFF"

    column style: %{gap: 1} do
      [
        text("ScatterChart Demo", style: [:bold]),
        divider(),
        chart_element,
        text(
          "Legend: #{legend_label}  Points: #{point_count}  Tick: #{model.tick}"
        ),
        text("[l] legend  [r] reset", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model), do: [subscribe_interval(@tick_interval_ms, :tick)]

  defp build_series(tick) do
    t = tick * @tick_scale

    [
      %{name: "Alpha", data: build_cluster_a(t), color: :green},
      %{name: "Beta", data: build_cluster_b(t), color: :yellow}
    ]
  end

  defp build_cluster_a(t) do
    for i <- 0..(@points_per_cluster - 1) do
      {
        @cluster_a_cx +
          @cluster_a_radius * :math.cos(i * @cluster_a_angle_speed + t),
        @cluster_a_cy +
          @cluster_a_radius * :math.sin(i * @cluster_a_sin_speed + t)
      }
    end
  end

  defp build_cluster_b(t) do
    for i <- 0..(@points_per_cluster - 1) do
      {
        @cluster_b_cx +
          @cluster_b_radius *
            :math.sin(i * @cluster_b_angle_speed + t * @cluster_b_time_scale),
        @cluster_b_cy +
          @cluster_b_radius *
            :math.cos(i * @cluster_b_cos_speed + t * @cluster_b_cos_time_scale)
      }
    end
  end
end
