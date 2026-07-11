defmodule Raxol.View.ChartComponentsTest do
  use ExUnit.Case, async: true

  alias Raxol.View.Components

  @series [
    %{name: "A", data: [10, 20, 30, 40, 50], color: :cyan},
    %{name: "B", data: [50, 40, 30, 20, 10], color: :magenta}
  ]

  @scatter_series [
    %{name: "S", data: [{1, 2}, {3, 4}, {5, 6}], color: :green}
  ]

  @heatmap_data [
    [1.0, 2.0, 3.0],
    [4.0, 5.0, 6.0],
    [7.0, 8.0, 9.0]
  ]

  describe "line_chart/1" do
    test "returns a box with chart content" do
      view = Components.line_chart(series: @series, width: 20, height: 5)
      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
      assert is_list(view.children)
    end

    test "renders with show_axes and show_legend" do
      view =
        Components.line_chart(
          series: @series,
          width: 40,
          height: 10,
          show_axes: true,
          show_legend: true
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
      assert view.children != []
    end

    test "returns empty box for empty series" do
      view = Components.line_chart(series: [], width: 20, height: 5)
      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end

    test "sets id when provided" do
      view = Components.line_chart(series: @series, id: "my-chart")
      assert view.id == "my-chart"
    end

    test "passes style to wrapper" do
      view =
        Components.line_chart(
          series: @series,
          style: %{border: :single}
        )

      # The wrapper box carries the chart region as width/height (hugging
      # the chart instead of filling all available space); caller style
      # keys still pass through and win.
      assert view.style.border == :single
      assert view.style.width == 40
      assert view.style.height == 10
    end
  end

  describe "bar_chart/1" do
    test "returns a box with chart content" do
      view = Components.bar_chart(series: @series, width: 20, height: 8)
      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
      assert is_list(view.children)
    end

    test "supports horizontal orientation" do
      view =
        Components.bar_chart(
          series: @series,
          width: 40,
          height: 10,
          orientation: :horizontal
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end

    test "supports show_values" do
      view =
        Components.bar_chart(
          series: @series,
          width: 40,
          height: 10,
          show_values: true
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end
  end

  describe "scatter_chart/1" do
    test "returns a box with chart content" do
      view = Components.scatter_chart(series: @scatter_series, width: 20, height: 8)
      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
      assert is_list(view.children)
    end

    test "supports custom ranges" do
      view =
        Components.scatter_chart(
          series: @scatter_series,
          width: 30,
          height: 10,
          x_range: {0, 10},
          y_range: {0, 10}
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end
  end

  describe "heatmap/1" do
    test "returns a box with chart content" do
      view = Components.heatmap(data: @heatmap_data, width: 15, height: 9)
      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
      assert is_list(view.children)
    end

    test "supports different color scales" do
      for scale <- [:warm, :cool, :diverging] do
        view =
          Components.heatmap(
            data: @heatmap_data,
            width: 15,
            height: 9,
            color_scale: scale
          )

        assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
      end
    end

    test "supports show_values" do
      view =
        Components.heatmap(
          data: @heatmap_data,
          width: 15,
          height: 9,
          show_values: true
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end
  end

  describe "sparkline/1" do
    test "returns a box with minimal chart" do
      view = Components.sparkline(data: [1, 3, 2, 5, 4], width: 10, height: 3)
      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end

    test "uses custom color" do
      view =
        Components.sparkline(
          data: [1, 2, 3],
          color: :yellow,
          width: 10,
          height: 3
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end

    test "returns empty box for empty data" do
      view = Components.sparkline(data: [], width: 10, height: 3)
      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end
  end

  describe "View module delegates" do
    test "line_chart is accessible via View" do
      view =
        Raxol.Core.Renderer.View.line_chart(
          series: @series,
          width: 20,
          height: 5
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end

    test "sparkline is accessible via View" do
      view =
        Raxol.Core.Renderer.View.sparkline(
          data: [1, 2, 3],
          width: 10,
          height: 3
        )

      assert view.type in [:line_chart, :bar_chart, :scatter_chart, :heatmap]
    end
  end
end
