defmodule Raxol.UI.Charts.BarChartTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Charts.BarChart

  @region {0, 0, 40, 10}

  defp single_series(data, color \\ :cyan) do
    [%{name: "Test", data: data, color: color}]
  end

  describe "render/3 vertical" do
    test "returns cell tuples" do
      cells = BarChart.render(@region, single_series([10, 20, 30]))
      assert [_ | _] = cells
      assert Enum.all?(cells, fn cell -> tuple_size(cell) == 6 end)
    end

    test "cells within region bounds" do
      cells = BarChart.render({5, 3, 40, 10}, single_series([10, 20, 30]))

      assert Enum.all?(cells, fn {x, y, _c, _fg, _bg, _a} ->
               x >= 5 and x < 45 and y >= 3 and y < 13
             end)
    end

    test "empty data returns empty" do
      assert BarChart.render(@region, single_series([])) == []
    end

    test "single bar renders" do
      cells = BarChart.render(@region, single_series([50]))
      assert [_ | _] = cells
    end

    test "uses block characters" do
      cells = BarChart.render(@region, single_series([10, 50, 100]))
      block_chars = ~w(▁ ▂ ▃ ▄ ▅ ▆ ▇ █)

      chars = Enum.map(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert Enum.any?(chars, fn c -> c in block_chars end)
    end

    test "multi-series grouped" do
      series = [
        %{name: "A", data: [10, 20], color: :red},
        %{name: "B", data: [30, 40], color: :blue}
      ]

      cells = BarChart.render(@region, series)

      colors =
        cells |> Enum.map(fn {_x, _y, _c, fg, _bg, _a} -> fg end) |> Enum.uniq()

      assert :red in colors
      assert :blue in colors
    end

    test "show_values renders value text" do
      # Use a tall region so partial bars leave room for labels
      cells =
        BarChart.render({0, 0, 40, 20}, single_series([5]),
          show_values: true,
          max: 100
        )

      chars = Enum.map_join(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert String.contains?(chars, "5")
    end
  end

  describe "render/3 horizontal" do
    test "renders horizontal bars" do
      cells =
        BarChart.render(@region, single_series([10, 20, 30]),
          orientation: :horizontal
        )

      assert [_ | _] = cells
      assert Enum.all?(cells, fn cell -> tuple_size(cell) == 6 end)
    end

    test "horizontal empty data returns empty" do
      assert BarChart.render(@region, single_series([]),
               orientation: :horizontal
             ) == []
    end

    test "horizontal multi-series" do
      series = [
        %{name: "A", data: [10, 20], color: :red},
        %{name: "B", data: [30, 40], color: :blue}
      ]

      cells = BarChart.render(@region, series, orientation: :horizontal)

      colors =
        cells |> Enum.map(fn {_x, _y, _c, fg, _bg, _a} -> fg end) |> Enum.uniq()

      assert :red in colors
      assert :blue in colors
    end

    test "horizontal show_values renders value text" do
      # Use max: 200 so bar only fills ~25% of width, leaving room for label
      cells =
        BarChart.render(@region, single_series([50]),
          orientation: :horizontal,
          show_values: true,
          max: 200
        )

      chars = Enum.map_join(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert String.contains?(chars, "50")
    end
  end

  describe "render/3 options" do
    test "show_axes includes axis characters" do
      cells = BarChart.render(@region, single_series([10, 20]), show_axes: true)
      chars = Enum.map(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert "|" in chars
    end

    test "show_legend includes series name" do
      cells =
        BarChart.render(@region, single_series([10, 20]), show_legend: true)

      chars = Enum.map_join(cells, fn {_x, _y, c, _fg, _bg, _a} -> c end)
      assert String.contains?(chars, "Test")
    end

    test "explicit min/max" do
      cells = BarChart.render(@region, single_series([50]), min: 0, max: 200)
      assert [_ | _] = cells
    end

    test "CircularBuffer input" do
      cb = Enum.into([10, 20, 30], CircularBuffer.new(10))
      cells = BarChart.render(@region, [%{name: "CB", data: cb, color: :green}])
      assert [_ | _] = cells
    end
  end

  describe "a11y_node/1" do
    test "binary id is used verbatim as label" do
      assert BarChart.a11y_node(%{id: "cpu"}) == %{role: :img, label: "cpu"}
    end

    test "atom id is stringified" do
      assert BarChart.a11y_node(%{id: :cpu}) == %{role: :img, label: "cpu"}
    end

    test "nil id falls back to default label" do
      assert BarChart.a11y_node(%{id: nil}) ==
               %{role: :img, label: "bar chart"}
    end

    test "missing id falls back to default label" do
      assert BarChart.a11y_node(%{}) == %{role: :img, label: "bar chart"}
    end

    test "aria_label wins over title and id" do
      assert BarChart.a11y_node(%{aria_label: "A", title: "T", id: "x"}) ==
               %{role: :img, label: "A"}
    end

    test "title wins over id" do
      assert BarChart.a11y_node(%{title: "T", id: "x"}) ==
               %{role: :img, label: "T"}
    end
  end
end
