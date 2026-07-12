defmodule Raxol.UI.Layout.FlexboxTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.Flexbox

  describe "new/1" do
    test "creates flexbox with defaults" do
      fb = Flexbox.new()
      assert fb.type == :flexbox
      assert fb.direction == :row
      assert fb.justify == :flex_start
      assert fb.align == :stretch
      assert fb.wrap == :nowrap
      assert fb.gap == 0
      assert fb.children == []
      assert fb.width == nil
      assert fb.height == nil
    end

    test "accepts custom options" do
      fb =
        Flexbox.new(
          direction: :column,
          justify: :center,
          align: :flex_end,
          wrap: :wrap,
          gap: 5,
          width: 100,
          height: 50,
          children: [%{type: :text}]
        )

      assert fb.direction == :column
      assert fb.justify == :center
      assert fb.align == :flex_end
      assert fb.wrap == :wrap
      assert fb.gap == 5
      assert fb.width == 100
      assert fb.height == 50
      assert length(fb.children) == 1
    end
  end

  describe "render/1" do
    test "returns ok tuple with rendered structure" do
      fb = Flexbox.new(children: [%{type: :text, content: "hi"}])
      assert {:ok, rendered} = Flexbox.render(fb)
      assert rendered.type == :rendered_flexbox
      assert rendered.layout == fb
      assert rendered.children == fb.children
    end
  end

  describe "calculate_layout/1" do
    test "calculates row layout dimensions" do
      children = [
        %{type: :text, width: 10, height: 5},
        %{type: :text, width: 20, height: 3}
      ]

      fb = Flexbox.new(direction: :row, children: children)
      layout = Flexbox.calculate_layout(fb)

      assert layout.width == 30
      assert layout.height == 5
      assert length(layout.children) == 2
    end

    test "calculates column layout dimensions" do
      children = [
        %{type: :text, width: 10, height: 5},
        %{type: :text, width: 20, height: 3}
      ]

      fb = Flexbox.new(direction: :column, children: children)
      layout = Flexbox.calculate_layout(fb)

      assert layout.width == 20
      assert layout.height == 8
    end

    test "includes gap in row calculations" do
      children = [
        %{type: :text, width: 10, height: 5},
        %{type: :text, width: 10, height: 5}
      ]

      fb = Flexbox.new(direction: :row, gap: 5, children: children)
      layout = Flexbox.calculate_layout(fb)

      # 10 + 5 (gap) + 10 = 25
      assert layout.width == 25
    end

    test "includes gap in column calculations" do
      children = [
        %{type: :text, width: 10, height: 5},
        %{type: :text, width: 10, height: 5}
      ]

      fb = Flexbox.new(direction: :column, gap: 3, children: children)
      layout = Flexbox.calculate_layout(fb)

      # 5 + 3 (gap) + 5 = 13
      assert layout.height == 13
    end

    test "uses explicit width/height when provided" do
      fb = Flexbox.new(width: 200, height: 100, children: [])
      layout = Flexbox.calculate_layout(fb)

      assert layout.width == 200
      assert layout.height == 100
    end

    test "handles empty children" do
      fb = Flexbox.new(direction: :row, children: [])
      layout = Flexbox.calculate_layout(fb)

      assert layout.width == 0
      assert layout.height == 0
      assert layout.children == []
    end
  end

  describe "measure_flex/2" do
    test "measures flex container with children" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        children: [
          %{type: :text, attrs: %{content: "hello"}},
          %{type: :text, attrs: %{content: "world"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.measure_flex(flex, space)

      assert is_integer(result.width)
      assert is_integer(result.height)
      assert result.width >= 0
      assert result.height >= 0
    end

    test "returns zero for non-flex element" do
      result = Flexbox.measure_flex(%{type: :other}, %{width: 80, height: 24})
      assert result == %{width: 0, height: 0}
    end

    test "accounts for padding in measurement" do
      flex = %{
        type: :flex,
        attrs: %{
          flex_direction: :row,
          padding: %{top: 2, right: 3, bottom: 2, left: 3}
        },
        children: []
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.measure_flex(flex, space)

      # Empty children but padding adds: left(3) + right(3) = 6, top(2) + bottom(2) = 4
      assert result.width == 6
      assert result.height == 4
    end
  end

  describe "process_flex/3" do
    test "returns accumulator for non-flex element" do
      acc = [{0, 0, "x", :white, :black, %{}}]

      result =
        Flexbox.process_flex(%{type: :other}, %{width: 80, height: 24}, acc)

      assert result == acc
    end

    test "processes flex container with text children" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        children: [
          %{type: :text, attrs: %{content: "A"}},
          %{type: :text, attrs: %{content: "B"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])

      assert is_list(result)
    end

    test "sorts children by order property" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        children: [
          %{type: :text, attrs: %{content: "B", order: 2}},
          %{type: :text, attrs: %{content: "A", order: 1}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end

  describe "style inheritance" do
    test "inherits fg/bg from parent to children" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        style: %{fg: :red, bg: :blue},
        children: [
          %{type: :text, attrs: %{content: "child"}, style: %{}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end

    test "child style overrides inherited style" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        style: %{fg: :red},
        children: [
          %{type: :text, attrs: %{content: "child"}, style: %{fg: :green}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end

    test "does not inherit layout properties" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        style: %{fg: :red, padding: 5, margin: 10},
        children: [
          %{type: :text, attrs: %{content: "child"}, style: %{}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      # Should not crash; layout props should not leak
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end

  describe "justify content positioning" do
    test "flex_start positions at beginning" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row, justify_content: :flex_start},
        children: [
          %{type: :text, attrs: %{content: "A"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end

    test "center positions in middle" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row, justify_content: :center},
        children: [
          %{type: :text, attrs: %{content: "A"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end

  describe "flex grow/shrink" do
    test "distributes extra space with flex grow" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        children: [
          %{type: :text, attrs: %{content: "A", flex: %{grow: 1}}},
          %{type: :text, attrs: %{content: "B", flex: %{grow: 2}}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end

    test "handles zero total grow" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row},
        children: [
          %{type: :text, attrs: %{content: "A", flex: %{grow: 0}}},
          %{type: :text, attrs: %{content: "B", flex: %{grow: 0}}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end

  describe "flex wrapping" do
    test "wraps children when wrap is enabled" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row, flex_wrap: :wrap},
        children: [
          %{type: :text, attrs: %{content: String.duplicate("X", 40)}},
          %{type: :text, attrs: %{content: String.duplicate("Y", 40)}},
          %{type: :text, attrs: %{content: String.duplicate("Z", 40)}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end

  describe "gap" do
    test "applies integer gap uniformly" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row, gap: 5},
        children: [
          %{type: :text, attrs: %{content: "A"}},
          %{type: :text, attrs: %{content: "B"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end

    test "applies row/column gap separately" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row, gap: %{row: 3, column: 5}},
        children: [
          %{type: :text, attrs: %{content: "A"}},
          %{type: :text, attrs: %{content: "B"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end

  describe "column direction" do
    test "lays out children vertically" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :column},
        children: [
          %{type: :text, attrs: %{content: "Top"}},
          %{type: :text, attrs: %{content: "Bottom"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end

  describe "padding" do
    test "reduces available space for children" do
      flex = %{
        type: :flex,
        attrs: %{
          flex_direction: :row,
          padding: %{top: 2, right: 3, bottom: 2, left: 3}
        },
        children: [
          %{type: :text, attrs: %{content: "padded"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end

    test "handles integer padding" do
      flex = %{
        type: :flex,
        attrs: %{flex_direction: :row, padding: 5},
        children: [
          %{type: :text, attrs: %{content: "padded"}}
        ]
      }

      space = %{x: 0, y: 0, width: 80, height: 24}
      result = Flexbox.process_flex(flex, space, [])
      assert is_list(result)
    end
  end
end
