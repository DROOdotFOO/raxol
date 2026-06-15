defmodule ScatterPlotDemo do
  @moduledoc """
  Random walk with 3 colored clusters, braille scatter plot.
  """

  use Raxol.Core.Runtime.Application

  alias Raxol.UI.Charts.{ScatterChart, ViewBridge}

  @max_points 200

  @impl true
  def init(_context) do
    %{tick: 0, cluster_a: [], cluster_b: [], cluster_c: []}
  end

  @impl true
  def update(message, model) do
    case message do
      :tick ->
        a = {25.0 + :rand.normal() * 8, 25.0 + :rand.normal() * 8}
        b = {60.0 + :rand.normal() * 6, 70.0 + :rand.normal() * 6}
        c = {75.0 + :rand.normal() * 10, 30.0 + :rand.normal() * 10}

        {%{
           model
           | tick: model.tick + 1,
             cluster_a: [a | model.cluster_a] |> Enum.take(@max_points),
             cluster_b: [b | model.cluster_b] |> Enum.take(@max_points),
             cluster_c: [c | model.cluster_c] |> Enum.take(@max_points)
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
      %{name: "Cluster A", data: model.cluster_a, color: :red},
      %{name: "Cluster B", data: model.cluster_b, color: :green},
      %{name: "Cluster C", data: model.cluster_c, color: :blue}
    ]

    cells =
      ScatterChart.render({1, 2, 78, 20}, series,
        show_legend: true,
        x_range: {0.0, 100.0},
        y_range: {0.0, 100.0}
      )

    column style: %{padding: 1} do
      [
        text("Braille Scatter Plot - 3 Clusters", style: [:bold], fg: :cyan),
        ViewBridge.cells_to_view(cells),
        text("#{model.tick * 3} points | Press q to quit", style: [:dim])
      ]
    end
  end

  @impl true
  def subscribe(_model) do
    [subscribe_interval(100, :tick)]
  end
end

Raxol.start_link(ScatterPlotDemo)
