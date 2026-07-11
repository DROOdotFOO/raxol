defmodule Raxol.CrossTerminal.ChartMeasurementTest do
  @moduledoc """
  Regression: chart widget types (:line_chart etc. — :box elements with an
  overridden :type for MCP discovery) measured 0x0 because only layout
  rewrote the type back to :box, not measurement. Result: siblings placed
  on top of the painted chart rows.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.Engine

  test "chart element measures its content height, not zero" do
    chart = %{
      type: :line_chart,
      style: %{},
      children: Enum.map(1..12, &%{type: :text, content: "row #{&1} braille"})
    }

    assert %{height: 12} = Engine.measure_element(chart, %{x: 0, y: 0, width: 80, height: 40})
  end

  test "siblings after a chart in a column land below the chart rows" do
    tree = %{
      type: :flex,
      direction: :column,
      gap: 0,
      children: [
        %{
          type: :bar_chart,
          style: %{},
          children: Enum.map(1..8, &%{type: :text, content: "bar row #{&1}"})
        },
        %{type: :text, content: "legend below"}
      ]
    }

    elements = Engine.apply_layout(tree, %{width: 80, height: 30})

    box = Enum.find(elements, &(&1.type == :box))
    legend = Enum.find(elements, &(Map.get(&1, :content) == "legend below" or Map.get(&1, :text) == "legend below"))

    assert box.height == 8
    assert legend.y >= box.y + box.height,
           "legend (y=#{legend.y}) overlaps chart box (y=#{box.y}, h=#{box.height})"
  end
end
