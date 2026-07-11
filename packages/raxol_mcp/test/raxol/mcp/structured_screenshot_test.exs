defmodule Raxol.MCP.StructuredScreenshotTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.StructuredScreenshot

  describe "from_view_tree/1" do
    test "returns empty list for nil" do
      assert StructuredScreenshot.from_view_tree(nil) == []
    end

    test "summarizes a single node" do
      node = %{
        type: :button,
        id: "submit",
        content: "Go",
        on_click: fn -> :noop end
      }

      [summary] = StructuredScreenshot.from_view_tree(node)

      assert summary.type == :button
      assert summary.id == "submit"
      assert summary.content == "Go"
      assert summary.children == []
    end

    test "summarizes nested children" do
      tree = %{
        type: :panel,
        id: "main",
        children: [
          %{type: :text, id: "label", content: "Hello"},
          %{type: :button, id: "btn", content: "Click"}
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(tree)
      assert summary.type == :panel
      assert length(summary.children) == 2
      assert Enum.map(summary.children, & &1.type) == [:text, :button]
    end

    test "handles list input" do
      nodes = [
        %{type: :text, id: "a"},
        %{type: :text, id: "b"}
      ]

      summaries = StructuredScreenshot.from_view_tree(nodes)
      assert length(summaries) == 2
    end

    test "handles non-string content gracefully" do
      node = %{type: :text, id: "x", content: 42}
      [summary] = StructuredScreenshot.from_view_tree(node)
      refute Map.has_key?(summary, :content)
    end

    test "defaults missing type to :unknown" do
      node = %{id: "orphan"}
      [summary] = StructuredScreenshot.from_view_tree(node)
      assert summary.type == :unknown
    end
  end

  describe "animation_hints in from_view_tree/1" do
    test "includes animation_hints when present" do
      node = %{
        type: :box,
        id: "panel",
        animation_hints: [
          %{
            property: :opacity,
            from: 0.0,
            to: 1.0,
            duration_ms: 300,
            easing: :ease_out_cubic,
            delay_ms: 0
          }
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(node)
      assert [hint] = summary.animation_hints
      assert hint.property == :opacity
      assert hint.from == 0.0
      assert hint.to == 1.0
      assert hint.duration_ms == 300
      assert hint.easing == :ease_out_cubic
      assert hint.delay_ms == 0
    end

    test "omits animation_hints key when not present" do
      node = %{type: :text, id: "label", content: "Hello"}
      [summary] = StructuredScreenshot.from_view_tree(node)
      refute Map.has_key?(summary, :animation_hints)
    end

    test "omits animation_hints key when empty list" do
      node = %{type: :box, id: "panel", animation_hints: []}
      [summary] = StructuredScreenshot.from_view_tree(node)
      refute Map.has_key?(summary, :animation_hints)
    end

    test "serializes multiple hints" do
      node = %{
        type: :box,
        id: "card",
        animation_hints: [
          %{
            property: :opacity,
            to: 1.0,
            duration_ms: 300,
            easing: :ease_out_cubic,
            delay_ms: 0
          },
          %{
            property: :fg,
            to: :cyan,
            duration_ms: 200,
            easing: :linear,
            delay_ms: 100
          }
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(node)
      assert length(summary.animation_hints) == 2
      assert Enum.map(summary.animation_hints, & &1.property) == [:opacity, :fg]
    end

    test "preserves hints in nested children" do
      tree = %{
        type: :column,
        id: "root",
        children: [
          %{
            type: :box,
            id: "child",
            animation_hints: [
              %{
                property: :opacity,
                to: 1.0,
                duration_ms: 500,
                easing: :ease_in_out,
                delay_ms: 50
              }
            ]
          }
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(tree)
      refute Map.has_key?(summary, :animation_hints)
      [child] = summary.children
      assert [hint] = child.animation_hints
      assert hint.property == :opacity
      assert hint.delay_ms == 50
    end

    test "applies defaults for missing hint fields" do
      node = %{
        type: :box,
        id: "minimal",
        animation_hints: [%{property: :width}]
      }

      [summary] = StructuredScreenshot.from_view_tree(node)
      [hint] = summary.animation_hints
      assert hint.property == :width
      assert hint.duration_ms == 300
      assert hint.easing == :ease_out_cubic
      assert hint.delay_ms == 0
      refute Map.has_key?(hint, :from)
      refute Map.has_key?(hint, :to)
    end

    test "filters out non-map hints" do
      node = %{
        type: :box,
        id: "mixed",
        animation_hints: [
          %{
            property: :opacity,
            to: 1.0,
            duration_ms: 300,
            easing: :linear,
            delay_ms: 0
          },
          "not a hint",
          42
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(node)
      assert length(summary.animation_hints) == 1
    end

    test "hints appear in JSON output" do
      node = %{
        type: :box,
        id: "animated",
        animation_hints: [
          %{
            property: :opacity,
            to: 1.0,
            duration_ms: 300,
            easing: :ease_out_cubic,
            delay_ms: 0
          }
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(node)
      json = StructuredScreenshot.to_json([summary])
      assert json =~ "animation_hints"
      assert json =~ "opacity"
    end
  end

  describe "border_beam hint serialization" do
    test "serializes border_beam type hint" do
      node = %{
        type: :box,
        id: "beam-box",
        animation_hints: [
          %{
            type: :border_beam,
            variant: :ocean,
            size: :full,
            strength: 0.6,
            duration_ms: 3000,
            active: true
          }
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(node)

      assert [hint] = summary.animation_hints
      assert hint.type == :border_beam
      assert hint.variant == :ocean
      assert hint.strength == 0.6
      assert hint.duration_ms == 3000
    end

    test "border_beam hints coexist with property hints" do
      node = %{
        type: :box,
        id: "combo",
        animation_hints: [
          %{property: :opacity, duration_ms: 300, easing: :linear, delay_ms: 0},
          %{
            type: :border_beam,
            variant: :colorful,
            strength: 0.8,
            duration_ms: 2000,
            active: true
          }
        ]
      }

      [summary] = StructuredScreenshot.from_view_tree(node)

      assert length(summary.animation_hints) == 2

      types =
        Enum.map(summary.animation_hints, &Map.get(&1, :type, :transition))

      assert :border_beam in types
    end
  end

  describe "accessibility fields" do
    # The Component Providers live in main raxol and are not loaded here, so
    # these exercise the projection's default (Roles-driven) extraction path.
    # The Provider path is covered by the main app's ComponentA11y tests.
    test "adds role/label/state for an interactive node" do
      node = %{type: :button, id: "save", attrs: %{label: "Save", disabled: true}}
      [summary] = StructuredScreenshot.from_view_tree(node)

      assert summary.role == :button
      assert summary.label == "Save"
      assert summary.state == %{disabled?: true}
    end

    test "role always present; static text gets :text with content label" do
      node = %{type: :text, id: "t", content: "Hello"}
      [summary] = StructuredScreenshot.from_view_tree(node)

      assert summary.role == :text
      assert summary.label == "Hello"
      refute Map.has_key?(summary, :state)
    end

    test "unknown types get role :generic" do
      [summary] = StructuredScreenshot.from_view_tree(%{type: :frobnicate, id: "x"})
      assert summary.role == :generic
    end

    test "marks live regions" do
      [summary] = StructuredScreenshot.from_view_tree(%{type: :progress, id: "p"})
      assert summary.role == :progressbar
      assert summary.live == true
    end

    test "omits :live and :focused when not applicable" do
      [summary] = StructuredScreenshot.from_view_tree(%{type: :text, id: "t", content: "x"})
      refute Map.has_key?(summary, :live)
      refute Map.has_key?(summary, :focused)
    end

    test "reports focus from the Component's own focused field" do
      node = %{type: :text_input, id: "n", attrs: %{focused: true}}
      [summary] = StructuredScreenshot.from_view_tree(node)
      assert summary.focused == true
    end

    test "marks focus via the :focused_id option" do
      node = %{type: :text_input, id: "search", attrs: %{value: "hi"}}
      [summary] = StructuredScreenshot.from_view_tree(node, focused_id: "search")
      assert summary.focused == true
    end

    test "enriches nested children" do
      tree = %{
        type: :panel,
        id: "root",
        children: [%{type: :button, id: "b", attrs: %{label: "Go"}}]
      }

      [summary] = StructuredScreenshot.from_view_tree(tree)
      [child] = summary.children
      assert child.role == :button
      assert child.label == "Go"
    end

    test "a11y fields survive JSON serialization" do
      node = %{type: :button, id: "b", attrs: %{label: "Save", disabled: true}}
      json = node |> StructuredScreenshot.from_view_tree() |> StructuredScreenshot.to_json()

      assert json =~ "role"
      assert json =~ "button"
      assert json =~ "disabled?"
    end
  end

  describe "to_json/1" do
    test "serializes summaries to JSON string" do
      summaries = [%{type: :button, id: "btn", children: []}]
      json = StructuredScreenshot.to_json(summaries)
      assert is_binary(json)
      assert json =~ "button"
    end
  end
end
