defmodule Raxol.UI.Layout.EngineTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.Layout.Preparer

  describe "apply_layout/3 with prepared_tree" do
    test "produces same output as apply_layout/2 for a simple text view" do
      view = %{
        type: :view,
        children: [
          %{type: :label, attrs: [content: "Hello, World!"]}
        ]
      }

      dimensions = %{width: 80, height: 24}
      prepared = Preparer.prepare(view)

      assert Engine.apply_layout(view, dimensions) ==
               Engine.apply_layout(view, dimensions, prepared)
    end

    test "produces same output as apply_layout/2 for a flex column" do
      view = %{
        type: :view,
        children: [
          %{
            type: :flex,
            direction: :column,
            children: [
              %{type: :text, content: "Hello"},
              %{type: :text, content: "World"}
            ]
          }
        ]
      }

      dimensions = %{width: 40, height: 10}
      prepared = Preparer.prepare(view)

      assert Engine.apply_layout(view, dimensions) ==
               Engine.apply_layout(view, dimensions, prepared)
    end

    test "produces same output as apply_layout/2 for a panel with children" do
      view = %{
        type: :view,
        children: [
          %{
            type: :panel,
            attrs: %{title: "Panel"},
            children: [
              %{type: :label, attrs: [content: "Inside"]}
            ]
          }
        ]
      }

      dimensions = %{width: 80, height: 24}
      prepared = Preparer.prepare(view)

      assert Engine.apply_layout(view, dimensions) ==
               Engine.apply_layout(view, dimensions, prepared)
    end

    test "does not leak measurement cache into process dictionary" do
      view = %{type: :view, children: [%{type: :text, content: "x"}]}
      dimensions = %{width: 20, height: 5}
      prepared = Preparer.prepare(view)

      Process.delete(:raxol_measurement_cache)
      _ = Engine.apply_layout(view, dimensions, prepared)
      refute Process.get(:raxol_measurement_cache)
    end
  end

  describe "apply_layout/2" do
    test "applies layout to a simple view" do
      view = %{
        type: :view,
        children: [
          %{type: :label, attrs: [content: "Hello, World!"]}
        ]
      }

      dimensions = %{width: 80, height: 24}

      result = Engine.apply_layout(view, dimensions)

      assert is_list(result)
      assert [_ | _] = result

      # The first element should be a text element
      text_element = Enum.find(result, fn elem -> elem.type == :text end)
      assert text_element != nil
      assert text_element.text == "Hello, World!"
      assert text_element.x == 0
      assert text_element.y == 0
    end

    test "hybrid text (:content at top level, style in :attrs) keeps its content" do
      # The harness widgets (TranscriptView markers/echoes, BlockBody rows)
      # emit `%{type: :text, content: c, attrs: %{style: [...]}}`. The
      # `:attrs` clause matches first, so it must fall back to the element's
      # top-level :content — this pin is what keeps the whole harness
      # transcript from laying out as empty strings (the blank-screen bug).
      view = %{
        type: :column,
        children: [
          %{type: :text, content: "hybrid survives", attrs: %{style: [:dim]}}
        ]
      }

      result = Engine.apply_layout(view, %{width: 80, height: 24})

      text_element = Enum.find(result, &(&1.type == :text))
      assert text_element != nil
      assert text_element.text == "hybrid survives"
      assert text_element.style == %{dim: true}
    end

    test "applies layout to a view with a panel" do
      view = %{
        type: :view,
        children: [
          %{
            type: :panel,
            attrs: %{title: "Test Panel"},
            children: [
              %{type: :label, attrs: [content: "Panel Content"]}
            ]
          }
        ]
      }

      dimensions = %{width: 80, height: 24}

      result = Engine.apply_layout(view, dimensions)

      assert is_list(result)

      # Find the panel box
      box_element = Enum.find(result, fn elem -> elem.type == :box end)

      assert box_element != nil
      assert box_element.width == 15
      assert box_element.height == 3
      assert box_element.x == 0
      assert box_element.y == 0
      assert box_element.attrs.title == "Test Panel"
      assert box_element.attrs.border == :single

      # Find the panel title
      title_element =
        Enum.find(result, fn
          %{type: :text, text: text} -> String.contains?(text, "Test Panel")
          _ -> false
        end)

      assert title_element != nil

      # Find the panel content
      content_element =
        Enum.find(result, fn
          %{type: :text, text: "Panel Content"} -> true
          _ -> false
        end)

      assert content_element != nil
      # Content should be inside the panel
      assert content_element.x == box_element.x + 1
      assert content_element.y == box_element.y + 1
    end

    test "applies layout to a view with a panel without title" do
      view = %{
        type: :view,
        children: [
          %{
            type: :panel,
            attrs: %{},
            children: [
              %{type: :label, attrs: [content: "Panel Content"]}
            ]
          }
        ]
      }

      dimensions = %{width: 80, height: 24}
      result = Engine.apply_layout(view, dimensions)
      box_element = Enum.find(result, fn elem -> elem.type == :box end)
      assert box_element != nil
      assert box_element.width == 15
      assert box_element.height == 3

      title_element =
        Enum.find(result, fn
          %{type: :text, attrs: %{original_type: :panel_title}} -> true
          _ -> false
        end)

      assert title_element == nil
    end

    test "applies layout to nested containers" do
      view = %{
        type: :view,
        children: [
          %{
            type: :row,
            children: [
              %{
                type: :column,
                children: [
                  %{type: :label, attrs: [content: "Top Left"]},
                  %{type: :label, attrs: [content: "Bottom Left"]}
                ]
              },
              %{
                type: :column,
                children: [
                  %{type: :label, attrs: [content: "Top Right"]},
                  %{type: :label, attrs: [content: "Bottom Right"]}
                ]
              }
            ]
          }
        ]
      }

      dimensions = %{width: 80, height: 24}

      result = Engine.apply_layout(view, dimensions)

      assert is_list(result)
      # Four label elements
      assert length(result) == 4

      # Find the labels
      top_left =
        Enum.find(result, fn
          %{type: :text, text: "Top Left"} -> true
          _ -> false
        end)

      bottom_left =
        Enum.find(result, fn
          %{type: :text, text: "Bottom Left"} -> true
          _ -> false
        end)

      top_right =
        Enum.find(result, fn
          %{type: :text, text: "Top Right"} -> true
          _ -> false
        end)

      bottom_right =
        Enum.find(result, fn
          %{type: :text, text: "Bottom Right"} -> true
          _ -> false
        end)

      assert top_left != nil
      assert bottom_left != nil
      assert top_right != nil
      assert bottom_right != nil

      # Check vertical and horizontal relationships
      assert top_left.y < bottom_left.y
      assert top_right.y < bottom_right.y
      assert top_left.x < top_right.x
      assert bottom_left.x < bottom_right.x
    end

    test "layout engine handles nested elements with flex properties" do
      view = %{
        type: :view,
        children: [
          %{
            type: :panel,
            attrs: %{title: "Test Panel"},
            children: [
              %{type: :label, attrs: [content: "Panel Content"]}
            ]
          }
        ]
      }

      dimensions = %{width: 80, height: 24}

      result = Engine.apply_layout(view, dimensions)

      assert is_list(result)

      # Check the box element specifically (assuming it's the first child after layout)
      box_element = List.first(result)
      assert box_element.type == :box
      assert Map.get(box_element.attrs, :title) == "Test Panel"
      assert Map.get(box_element.attrs, :border) == :single
    end
  end

  describe "measure_element/2" do
    test "measures a label element" do
      element = %{type: :label, attrs: [content: "Test Label"]}
      available_space = %{width: 80, height: 24}

      dimensions = Engine.measure_element(element, available_space)

      # Length of "Test Label"
      assert dimensions.width == 10
      assert dimensions.height == 1
    end

    test "measures a button element" do
      element = %{type: :button, attrs: %{label: "Click Me"}}
      available_space = %{width: 80, height: 24}

      dimensions = Engine.measure_element(element, available_space)

      # Button width = text length + 4 for padding
      assert dimensions.width == 12
      assert dimensions.height == 3
    end

    test "measures a text input element" do
      element = %{type: :text_input, attrs: %{value: "Hello"}}
      available_space = %{width: 80, height: 24}

      dimensions = Engine.measure_element(element, available_space)

      # Text input width = text length + 4 for padding
      assert dimensions.width == 9
      assert dimensions.height == 3
    end

    test "measures a box element" do
      element = %{type: :box, attrs: %{width: 20, height: 10}}
      available_space = %{width: 80, height: 24}
      dimensions = Engine.measure_element(element, available_space)
      assert dimensions.width == 20
      assert dimensions.height == 10
    end

    test "measures a checkbox element" do
      element = %{type: :checkbox, attrs: %{label: "Option 1"}}
      available_space = %{width: 80, height: 24}
      dimensions = Engine.measure_element(element, available_space)
      # "[ ] " + "Option 1" => 4 + 8 = 12
      assert dimensions.width == 12
      assert dimensions.height == 1
    end

    test "measures a panel element based on children" do
      element = %{
        type: :panel,
        attrs: %{},
        children: [
          %{type: :label, attrs: [content: String.duplicate("X", 15)]}
        ]
      }

      # Panel adds 2 width/height for borders
      available_space = %{width: 80, height: 24}
      dimensions = Engine.measure_element(element, available_space)
      # Child width 15, Panel width 15 + 2 = 17
      assert dimensions.width == 17
      # Child height 1, Panel height 1 + 2 = 3
      assert dimensions.height == 3
    end

    test "measures a panel element with explicit size" do
      element = %{
        type: :panel,
        attrs: %{width: 30, height: 5},
        children: [%{type: :label, attrs: [content: "Short"]}]
      }

      available_space = %{width: 80, height: 24}
      dimensions = Engine.measure_element(element, available_space)
      assert dimensions.width == 30
      assert dimensions.height == 5
    end

    test "measures a grid element based on children" do
      element = %{
        type: :grid,
        attrs: %{columns: 2, gap_x: 1, gap_y: 1},
        children: [
          # Width 10
          %{type: :label, attrs: [content: "AAAAAAAAAA"]},
          # Width 2
          %{type: :label, attrs: [content: "BB"]},
          # Width 3
          %{type: :label, attrs: [content: "CCC"]},
          # Width 6
          %{type: :label, attrs: [content: "DDDDDD"]}
        ]
      }

      # Grid logic uses max child width/height
      available_space = %{width: 80, height: 24}
      dimensions = Engine.measure_element(element, available_space)
      # Max child width = 10. Grid width = cols * max_w + gap_x * (cols - 1)
      # 2 * 10 + 1 * (2 - 1) = 20 + 1 = 21
      assert dimensions.width == 21
      # Max child height = 1. Rows = ceil(4/2) = 2.
      # Grid height = rows * max_h + gap_y * (rows - 1)
      # 2 * 1 + 1 * (2 - 1) = 2 + 1 = 3
      assert dimensions.height == 3
    end

    test "constrains element size to available space" do
      # Create a label with very long text
      element = %{type: :label, attrs: [content: String.duplicate("A", 100)]}
      available_space = %{width: 50, height: 24}

      dimensions = Engine.measure_element(element, available_space)

      # Measures intrinsic width, ignoring available_space constraint here
      # The constraint is applied during processing/placement
      assert dimensions.width == 100
      assert dimensions.height == 1
    end

    test "measures button with new View DSL format (top-level :text key)" do
      element = %{
        type: :button,
        text: "Click Me",
        id: nil,
        on_click: :click,
        style: []
      }

      available_space = %{width: 80, height: 24}

      dimensions = Engine.measure_element(element, available_space)

      assert dimensions.width == String.length("Click Me") + 4
      assert dimensions.height == 3
    end

    test "measures checkbox with new View DSL format (top-level :label key)" do
      element = %{type: :checkbox, label: "Accept", checked: false, style: []}

      dimensions = Engine.measure_element(element)

      # checkbox width = 4 + label length
      assert dimensions.width == 4 + String.length("Accept")
      assert dimensions.height == 1
    end

    test "measures text_input with new View DSL format (top-level :value key)" do
      element = %{
        type: :text_input,
        value: "hello",
        placeholder: "Type...",
        style: []
      }

      available_space = %{width: 80, height: 24}

      dimensions = Engine.measure_element(element, available_space)

      assert dimensions.width == String.length("hello") + 4
      assert dimensions.height == 3
    end

    test "measures text_input with empty value uses placeholder" do
      element = %{
        type: :text_input,
        value: "",
        placeholder: "Search...",
        style: []
      }

      available_space = %{width: 80, height: 24}

      dimensions = Engine.measure_element(element, available_space)

      assert dimensions.width == String.length("Search...") + 4
      assert dimensions.height == 3
    end

    test "measures box with new View DSL format and explicit dimensions" do
      element = %{
        type: :box,
        children: [%{type: :text, content: "child", style: %{}}],
        width: 30,
        height: 10,
        style: []
      }

      dimensions = Engine.measure_element(element)

      assert dimensions.width == 30
      assert dimensions.height == 10
    end

    test "measures box with new View DSL format without explicit dimensions" do
      element = %{
        type: :box,
        children: [%{type: :text, content: "child", style: %{}}],
        padding: {1, 1, 1, 1},
        border: :single,
        style: []
      }

      dimensions = Engine.measure_element(element)

      # Falls through to container measurement (column-like)
      assert is_integer(dimensions.width)
      assert is_integer(dimensions.height)
    end
  end

  describe "element id preservation (accessibility)" do
    # Accessibility surfaces (Browser data-raxol-id, ARIA) map a rendered cell
    # span back to its source node by the positioned element's top-level :id
    # plus geometry. These leaf components must carry both through layout.
    defp positioned_by_id(view, id) do
      view
      |> Engine.apply_layout(%{width: 80, height: 24})
      |> Enum.find(fn el ->
        Map.get(el, :id) == id and is_integer(Map.get(el, :width)) and
          is_integer(Map.get(el, :height))
      end)
    end

    test "button carries its id and geometry on the positioned box" do
      view = %{type: :button, id: "submit", attrs: %{label: "Submit"}}

      el = positioned_by_id(view, "submit")

      assert el.type == :box
      assert el.width > 0
      assert el.height == 3
    end

    test "checkbox carries its id and geometry on the positioned text" do
      view = %{
        type: :checkbox,
        id: "agree",
        attrs: %{label: "Agree", checked: true}
      }

      el = positioned_by_id(view, "agree")

      assert el.type == :text
      assert el.width == Raxol.UI.TextMeasure.display_width("[[OK]] Agree")
      assert el.height == 1
    end

    test "text_input carries its id and geometry on the positioned box" do
      view = %{type: :text_input, id: "name", attrs: %{value: "Alice"}}

      el = positioned_by_id(view, "name")

      assert el.type == :box
      assert el.width > 0
      assert el.height == 3
    end

    test "content text carries its id and geometry" do
      view = %{type: :text, id: "greeting", content: "Hello"}

      el = positioned_by_id(view, "greeting")

      assert el.type == :text
      assert el.width == Raxol.UI.TextMeasure.display_width("Hello")
      assert el.height == 1
    end

    test "box carries its id and geometry on the positioned element" do
      view = %{
        type: :box,
        id: "panel",
        children: [%{type: :text, content: "Hi"}]
      }

      el = positioned_by_id(view, "panel")

      assert el.type == :box
      assert el.width > 0
      assert el.height > 0
    end

    test "box without an id keeps behaving exactly as before" do
      view = %{type: :box, children: [%{type: :text, content: "Hi"}]}

      [box_el, _text_el] = Engine.apply_layout(view, %{width: 80, height: 24})

      assert box_el.type == :box
      assert box_el.id == nil
    end

    # Neither the literal :row/:column dialect nor the View DSL :flex
    # container produce a positioned element of their own -- Flexbox lays
    # out and emits only the children, matching pre-existing behavior. So
    # the container's own :id has nowhere to land in `apply_layout/2`
    # output; these tests instead pin that translating a container with an
    # :id (compat rewrite, or a raw :flex node) does not corrupt or drop
    # the :id carried by a child, which is the identity that IS addressable
    # today.
    test "a literal :row with an id preserves a child box's id through the compat rewrite" do
      view = %{
        type: :row,
        id: "toolbar",
        children: [
          %{
            type: :box,
            id: "save_btn",
            children: [%{type: :text, content: "Save"}]
          }
        ]
      }

      el = positioned_by_id(view, "save_btn")

      assert el.type == :box
      assert el.width > 0
      assert el.height > 0
    end

    test "a literal :column with an id preserves a child box's id through the compat rewrite" do
      view = %{
        type: :column,
        id: "sidebar",
        children: [
          %{
            type: :box,
            id: "item1",
            children: [%{type: :text, content: "Item"}]
          }
        ]
      }

      el = positioned_by_id(view, "item1")

      assert el.type == :box
      assert el.width > 0
      assert el.height > 0
    end

    test "a View DSL :flex container with an id preserves a child box's id" do
      view = %{
        type: :flex,
        id: "layout_root",
        direction: :row,
        children: [
          %{type: :box, id: "card", children: [%{type: :text, content: "Card"}]}
        ]
      }

      el = positioned_by_id(view, "card")

      assert el.type == :box
      assert el.width > 0
      assert el.height > 0
    end
  end
end
