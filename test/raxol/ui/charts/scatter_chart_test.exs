defmodule Raxol.UI.Charts.ScatterChartTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Charts.ScatterChart

  @region {0, 0, 20, 10}

  defp single_series(data, color \\ :cyan) do
    [%{name: "Test", data: data, color: color}]
  end

  describe "render/3" do
    test "returns cell tuples" do
      data = [{1.0, 2.0}, {3.0, 4.0}, {5.0, 6.0}]
      cells = ScatterChart.render(@region, single_series(data))
      assert [_ | _] = cells
      assert Enum.all?(cells, fn cell -> tuple_size(cell) == 6 end)
    end

    test "cells within region bounds" do
      data = [{0.0, 0.0}, {1.0, 1.0}, {0.5, 0.5}]
      cells = ScatterChart.render({5, 3, 20, 10}, single_series(data))

      assert Enum.all?(cells, fn {x, y, _c, _fg, _bg, _a} ->
               x >= 5 and x < 25 and y >= 3 and y < 13
             end)
    end

    test "empty data returns blank braille" do
      cells = ScatterChart.render(@region, single_series([]))

      assert Enum.all?(cells, fn {_x, _y, c, _fg, _bg, _a} ->
               <<cp::utf8>> = c
               cp == 0x2800
             end)
    end

    test "multicolor overlap renders both series' dots" do
      series = [
        %{name: "A", data: [{0.0, 0.0}, {0.5, 0.5}], color: :red},
        %{name: "B", data: [{1.0, 1.0}, {0.5, 0.5}], color: :blue}
      ]

      cells = ScatterChart.render(@region, series)
      # All cells should be valid
      assert Enum.all?(cells, fn cell -> tuple_size(cell) == 6 end)
    end

    test "custom x_range and y_range" do
      data = [{5.0, 5.0}]

      cells =
        ScatterChart.render(@region, single_series(data),
          x_range: {0.0, 10.0},
          y_range: {0.0, 10.0}
        )

      # Should have at least one non-empty braille (the dot)
      assert Enum.any?(cells, fn {_x, _y, c, _fg, _bg, _a} ->
               <<cp::utf8>> = c
               cp != 0x2800
             end)
    end

    test "out-of-range points clipped gracefully" do
      data = [{-100.0, -100.0}, {100.0, 100.0}]

      cells =
        ScatterChart.render(@region, single_series(data),
          x_range: {0.0, 10.0},
          y_range: {0.0, 10.0}
        )

      assert [_ | _] = cells
    end

    test "single point renders" do
      cells = ScatterChart.render(@region, single_series([{5.0, 5.0}]))
      assert [_ | _] = cells
    end

    test "show_axes includes axis characters" do
      data = [{1.0, 2.0}, {3.0, 4.0}]
      cells = ScatterChart.render(@region, single_series(data), show_axes: true)
      chars = Enum.map(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert "|" in chars
    end

    test "show_legend includes series name" do
      data = [{1.0, 2.0}]

      cells =
        ScatterChart.render(@region, single_series(data), show_legend: true)

      chars = Enum.map_join(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert String.contains?(chars, "Test")
    end

    test "CircularBuffer input works" do
      cb = Enum.into([{1.0, 2.0}, {3.0, 4.0}], CircularBuffer.new(10))

      cells =
        ScatterChart.render(@region, [%{name: "CB", data: cb, color: :green}])

      assert [_ | _] = cells
    end
  end

  describe "a11y_node/1" do
    test "binary id is used verbatim as label" do
      assert ScatterChart.a11y_node(%{id: "cpu"}) ==
               %{role: :img, label: "cpu"}
    end

    test "atom id is stringified" do
      assert ScatterChart.a11y_node(%{id: :cpu}) ==
               %{role: :img, label: "cpu"}
    end

    test "nil id falls back to default label" do
      assert ScatterChart.a11y_node(%{id: nil}) ==
               %{role: :img, label: "scatter chart"}
    end

    test "missing id falls back to default label" do
      assert ScatterChart.a11y_node(%{}) ==
               %{role: :img, label: "scatter chart"}
    end

    test "aria_label wins over title and id" do
      assert ScatterChart.a11y_node(%{aria_label: "A", title: "T", id: "x"}) ==
               %{role: :img, label: "A"}
    end

    test "title wins over id" do
      assert ScatterChart.a11y_node(%{title: "T", id: "x"}) ==
               %{role: :img, label: "T"}
    end
  end
end
