defmodule Raxol.UI.Charts.LineChartTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Charts.LineChart

  @region {0, 0, 20, 10}

  defp single_series(data, color \\ :cyan) do
    [%{name: "Test", data: data, color: color}]
  end

  describe "render/3" do
    test "returns cell tuples" do
      cells = LineChart.render(@region, single_series([1, 2, 3, 4, 5]))
      assert [_ | _] = cells
      assert Enum.all?(cells, fn cell -> tuple_size(cell) == 6 end)
    end

    test "cells within region bounds" do
      cells = LineChart.render({5, 3, 20, 10}, single_series([1, 2, 3, 4, 5]))

      assert Enum.all?(cells, fn {x, y, _c, _fg, _bg, _a} ->
               x >= 5 and x < 25 and y >= 3 and y < 13
             end)
    end

    test "empty data returns empty" do
      cells = LineChart.render(@region, single_series([]))
      # Only braille chars, all empty
      assert Enum.all?(cells, fn {_x, _y, c, _fg, _bg, _a} ->
               <<cp::utf8>> = c
               cp == 0x2800
             end)
    end

    test "single point returns cells (no line to draw)" do
      cells = LineChart.render(@region, single_series([42]))
      assert [_ | _] = cells
    end

    test "multi-series renders all colors" do
      series = [
        %{name: "A", data: [1, 2, 3, 4, 5], color: :red},
        %{name: "B", data: [5, 4, 3, 2, 1], color: :blue}
      ]

      cells = LineChart.render(@region, series)

      colors =
        cells |> Enum.map(fn {_x, _y, _c, fg, _bg, _a} -> fg end) |> Enum.uniq()

      # Should have at least 2 colors (from different series winning cells)
      assert length(colors) >= 2
    end

    test "auto-scaling handles negative values" do
      cells = LineChart.render(@region, single_series([-10, -5, 0, 5, 10]))
      assert [_ | _] = cells
    end

    test "CircularBuffer input works" do
      cb = Enum.into([1, 2, 3, 4, 5], CircularBuffer.new(10))

      cells =
        LineChart.render(@region, [%{name: "CB", data: cb, color: :green}])

      assert [_ | _] = cells
    end

    test "show_axes includes axis characters" do
      cells =
        LineChart.render(@region, single_series([1, 2, 3]), show_axes: true)

      chars = Enum.map(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert "|" in chars
    end

    test "show_legend includes series name" do
      cells =
        LineChart.render(@region, single_series([1, 2, 3]), show_legend: true)

      chars = Enum.map_join(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert String.contains?(chars, "Test")
    end

    test "explicit min/max respected" do
      cells =
        LineChart.render(@region, single_series([1, 2, 3]), min: 0, max: 10)

      assert [_ | _] = cells
    end

    test "all cells have braille or axis characters" do
      cells = LineChart.render(@region, single_series([1, 2, 3, 4, 5]))

      assert Enum.all?(cells, fn {_x, _y, c, _fg, _bg, _a} ->
               <<_::utf8>> = c
               String.length(c) == 1
             end)
    end

    test "large dataset renders without error" do
      data = for i <- 1..1000, do: :math.sin(i / 10.0) * 100
      cells = LineChart.render({0, 0, 80, 24}, single_series(data))
      assert [_ | _] = cells
    end
  end

  describe "a11y_node/1" do
    test "binary id is used verbatim as label" do
      assert LineChart.a11y_node(%{id: "cpu"}) == %{role: :img, label: "cpu"}
    end

    test "atom id is stringified" do
      assert LineChart.a11y_node(%{id: :cpu}) == %{role: :img, label: "cpu"}
    end

    test "nil id falls back to default label" do
      assert LineChart.a11y_node(%{id: nil}) ==
               %{role: :img, label: "line chart"}
    end

    test "missing id falls back to default label" do
      assert LineChart.a11y_node(%{}) == %{role: :img, label: "line chart"}
    end

    test "aria_label wins over title and id" do
      assert LineChart.a11y_node(%{aria_label: "A", title: "T", id: "x"}) ==
               %{role: :img, label: "A"}
    end

    test "title wins over id" do
      assert LineChart.a11y_node(%{title: "T", id: "x"}) ==
               %{role: :img, label: "T"}
    end
  end
end
