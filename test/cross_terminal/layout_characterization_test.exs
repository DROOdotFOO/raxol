defmodule Raxol.CrossTerminal.LayoutCharacterizationTest do
  @moduledoc """
  Characterization net for the live layout engine.

  Pins the CURRENT geometry of `Raxol.UI.Layout.Engine.apply_layout/2` across
  the two dialects it dispatches: View DSL `row`/`column`/`flex` (the
  `Flexbox` path) and literal `:row`/`:column` elements (the Containers-dialect
  compat map), which has its own gap/align/justify defaults.

  Pins behavior as-is, quirks included; a changed number here is either a
  conscious re-pin or a regression.
  """

  use ExUnit.Case, async: true

  import Raxol.View.Elements
  alias Raxol.UI.Layout.Engine
  require Raxol.Core.Renderer.View
  alias Raxol.Core.Renderer.View, as: LegacyView

  # Reduces every positioned element to the fields these pins track:
  # type/x/y/width/height plus text content when present. This is
  # deliberately lossy (drops style/attrs/fg/bg) so pins stay readable and
  # focused on geometry.
  defp simplify(elements) do
    Enum.map(elements, fn el ->
      case el do
        %{type: :text, text: t} -> %{type: :text, x: el.x, y: el.y, text: t}
        _ -> Map.take(el, [:type, :x, :y, :width, :height])
      end
    end)
  end

  defp layout(tree, dims \\ %{width: 40, height: 20}) do
    tree |> Engine.apply_layout(dims) |> simplify()
  end

  # ---------------------------------------------------------------------
  # `style: %{gap: n}` and top-level `gap:` must produce identical geometry.
  # ---------------------------------------------------------------------
  describe "gap conventions (row/column x gap 0/1/3 x style/top-level)" do
    for gap <- [0, 1, 3] do
      test "row gap #{gap} via style: %{gap: n}" do
        tree =
          row(
            style: %{gap: unquote(gap)},
            do: [text("A"), text("B"), text("C")]
          )

        assert layout(tree) == row_gap_expected(unquote(gap))
      end

      test "row gap #{gap} via top-level gap: n" do
        tree = row(gap: unquote(gap), do: [text("A"), text("B"), text("C")])
        assert layout(tree) == row_gap_expected(unquote(gap))
      end

      test "column gap #{gap} via style: %{gap: n}" do
        tree =
          column(
            style: %{gap: unquote(gap)},
            do: [text("A"), text("B"), text("C")]
          )

        assert layout(tree) == column_gap_expected(unquote(gap))
      end

      test "column gap #{gap} via top-level gap: n" do
        tree = column(gap: unquote(gap), do: [text("A"), text("B"), text("C")])
        assert layout(tree) == column_gap_expected(unquote(gap))
      end
    end

    defp row_gap_expected(0) do
      [
        %{type: :text, x: 0, y: 0, text: "A"},
        %{type: :text, x: 1, y: 0, text: "B"},
        %{type: :text, x: 2, y: 0, text: "C"}
      ]
    end

    defp row_gap_expected(1) do
      [
        %{type: :text, x: 0, y: 0, text: "A"},
        %{type: :text, x: 2, y: 0, text: "B"},
        %{type: :text, x: 4, y: 0, text: "C"}
      ]
    end

    defp row_gap_expected(3) do
      [
        %{type: :text, x: 0, y: 0, text: "A"},
        %{type: :text, x: 4, y: 0, text: "B"},
        %{type: :text, x: 8, y: 0, text: "C"}
      ]
    end

    defp column_gap_expected(0) do
      [
        %{type: :text, x: 0, y: 0, text: "A"},
        %{type: :text, x: 0, y: 1, text: "B"},
        %{type: :text, x: 0, y: 2, text: "C"}
      ]
    end

    defp column_gap_expected(1) do
      [
        %{type: :text, x: 0, y: 0, text: "A"},
        %{type: :text, x: 0, y: 2, text: "B"},
        %{type: :text, x: 0, y: 4, text: "C"}
      ]
    end

    defp column_gap_expected(3) do
      [
        %{type: :text, x: 0, y: 0, text: "A"},
        %{type: :text, x: 0, y: 4, text: "B"},
        %{type: :text, x: 0, y: 8, text: "C"}
      ]
    end
  end

  # ---------------------------------------------------------------------
  # Top-level `justify:` has no effect; only `style: %{justify_content: j}` is honored.
  # ---------------------------------------------------------------------
  describe "justify_content (row, 3 children width 2, container width 30)" do
    test "flex_start" do
      tree = row(style: %{justify_content: :flex_start}, do: three_wide())

      assert layout(tree, %{width: 30, height: 5}) == [
               %{type: :text, x: 0, y: 0, text: "AA"},
               %{type: :text, x: 2, y: 0, text: "BB"},
               %{type: :text, x: 4, y: 0, text: "CC"}
             ]
    end

    test "flex_end" do
      tree = row(style: %{justify_content: :flex_end}, do: three_wide())

      assert layout(tree, %{width: 30, height: 5}) == [
               %{type: :text, x: 24, y: 0, text: "AA"},
               %{type: :text, x: 26, y: 0, text: "BB"},
               %{type: :text, x: 28, y: 0, text: "CC"}
             ]
    end

    test "center" do
      tree = row(style: %{justify_content: :center}, do: three_wide())

      assert layout(tree, %{width: 30, height: 5}) == [
               %{type: :text, x: 12, y: 0, text: "AA"},
               %{type: :text, x: 14, y: 0, text: "BB"},
               %{type: :text, x: 16, y: 0, text: "CC"}
             ]
    end

    test "space_between" do
      tree = row(style: %{justify_content: :space_between}, do: three_wide())

      assert layout(tree, %{width: 30, height: 5}) == [
               %{type: :text, x: 0, y: 0, text: "AA"},
               %{type: :text, x: 14, y: 0, text: "BB"},
               %{type: :text, x: 28, y: 0, text: "CC"}
             ]
    end

    test "space_around" do
      tree = row(style: %{justify_content: :space_around}, do: three_wide())

      assert layout(tree, %{width: 30, height: 5}) == [
               %{type: :text, x: 4, y: 0, text: "AA"},
               %{type: :text, x: 14, y: 0, text: "BB"},
               %{type: :text, x: 24, y: 0, text: "CC"}
             ]
    end

    test "space_evenly" do
      tree = row(style: %{justify_content: :space_evenly}, do: three_wide())

      assert layout(tree, %{width: 30, height: 5}) == [
               %{type: :text, x: 6, y: 0, text: "AA"},
               %{type: :text, x: 14, y: 0, text: "BB"},
               %{type: :text, x: 22, y: 0, text: "CC"}
             ]
    end

    defp three_wide, do: [text("AA"), text("BB"), text("CC")]
  end

  # ---------------------------------------------------------------------
  # stretch is a no-op when children declare an explicit height; it only
  # applies when the box has no explicit height.
  # ---------------------------------------------------------------------
  describe "align_items (row, height 10, box X height=1 / box Y height=3, both explicit)" do
    defp align_children do
      [
        box(style: %{width: 3, height: 1}, do: text("X")),
        box(style: %{width: 3, height: 3}, do: text("Y"))
      ]
    end

    test "flex_start" do
      tree = row(style: %{align_items: :flex_start}, do: align_children())

      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :box, x: 0, y: 0, width: 3, height: 1},
               %{type: :text, x: 0, y: 0, text: "X"},
               %{type: :box, x: 3, y: 0, width: 3, height: 3},
               %{type: :text, x: 3, y: 0, text: "Y"}
             ]
    end

    test "flex_end" do
      tree = row(style: %{align_items: :flex_end}, do: align_children())

      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :box, x: 0, y: 9, width: 3, height: 1},
               %{type: :text, x: 0, y: 9, text: "X"},
               %{type: :box, x: 3, y: 7, width: 3, height: 3},
               %{type: :text, x: 3, y: 7, text: "Y"}
             ]
    end

    test "center" do
      tree = row(style: %{align_items: :center}, do: align_children())

      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :box, x: 0, y: 4, width: 3, height: 1},
               %{type: :text, x: 0, y: 4, text: "X"},
               %{type: :box, x: 3, y: 3, width: 3, height: 3},
               %{type: :text, x: 3, y: 3, text: "Y"}
             ]
    end

    test "stretch is a no-op when children declare an explicit height" do
      tree = row(style: %{align_items: :stretch}, do: align_children())

      # Identical to flex_start: box's min(explicit_h, space.height) clamp wins.
      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :box, x: 0, y: 0, width: 3, height: 1},
               %{type: :text, x: 0, y: 0, text: "X"},
               %{type: :box, x: 3, y: 0, width: 3, height: 3},
               %{type: :text, x: 3, y: 0, text: "Y"}
             ]
    end

    test "stretch DOES override when the box has no explicit height" do
      tree =
        row(
          style: %{align_items: :stretch},
          do: [
            box(style: %{width: 4, border: :single}, do: text("N"))
          ]
        )

      assert layout(tree, %{width: 30, height: 8}) == [
               %{type: :box, x: 0, y: 0, width: 4, height: 8},
               %{type: :text, x: 1, y: 1, text: "N"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # box explicit sizing conventions
  # ---------------------------------------------------------------------
  describe "box explicit sizing" do
    test "explicit style width/height" do
      tree = box(style: %{width: 10, height: 4}, do: text("hi"))

      assert layout(tree) == [
               %{type: :box, x: 0, y: 0, width: 10, height: 4},
               %{type: :text, x: 0, y: 0, text: "hi"}
             ]
    end

    test "padding tuple {top, right, bottom, left} insets content, box fills space" do
      tree =
        box(style: %{padding: {1, 2, 1, 2}, border: :single}, do: text("hi"))

      assert layout(tree) == [
               %{type: :box, x: 0, y: 0, width: 40, height: 20},
               %{type: :text, x: 3, y: 2, text: "hi"}
             ]
    end

    test "size: {w, h} top-level tuple" do
      tree = box(size: {12, 6}, do: text("hi"))

      assert layout(tree) == [
               %{type: :box, x: 0, y: 0, width: 12, height: 6},
               %{type: :text, x: 0, y: 0, text: "hi"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # nesting: column-in-row, row-in-column, box-in-column-in-row (3 deep)
  # ---------------------------------------------------------------------
  describe "nesting" do
    test "column-in-row" do
      tree =
        row(
          style: %{gap: 1},
          do: [
            column(style: %{gap: 0}, do: [text("A1"), text("A2")]),
            column(style: %{gap: 0}, do: [text("B1"), text("B2")])
          ]
        )

      assert layout(tree) == [
               %{type: :text, x: 0, y: 0, text: "A1"},
               %{type: :text, x: 0, y: 1, text: "A2"},
               %{type: :text, x: 3, y: 0, text: "B1"},
               %{type: :text, x: 3, y: 1, text: "B2"}
             ]
    end

    test "row-in-column" do
      tree =
        column(
          style: %{gap: 1},
          do: [
            row(style: %{gap: 0}, do: [text("A1"), text("A2")]),
            row(style: %{gap: 0}, do: [text("B1"), text("B2")])
          ]
        )

      assert layout(tree) == [
               %{type: :text, x: 0, y: 0, text: "A1"},
               %{type: :text, x: 2, y: 0, text: "A2"},
               %{type: :text, x: 0, y: 2, text: "B1"},
               %{type: :text, x: 2, y: 2, text: "B2"}
             ]
    end

    test "box-in-column-in-row (3 deep)" do
      tree =
        row(
          style: %{gap: 0},
          do: [
            column(
              style: %{gap: 0},
              do: [
                box(
                  style: %{width: 5, height: 3, border: :single},
                  do: text("Z")
                )
              ]
            )
          ]
        )

      assert layout(tree) == [
               %{type: :box, x: 0, y: 0, width: 5, height: 3},
               %{type: :text, x: 1, y: 1, text: "Z"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # grow child (attrs.flex.grow) beside a fixed-size sibling
  # ---------------------------------------------------------------------
  describe "grow child (attrs: %{flex: %{grow: 1}})" do
    test "row: grow child fills remaining main-axis space" do
      fixed = box(style: %{width: 5, height: 3, border: :single}, do: text("F"))

      grow =
        box(style: %{height: 3, border: :single}, do: text("G"))
        |> Map.put(:attrs, %{flex: %{grow: 1}})

      tree = row(style: %{gap: 0}, do: [fixed, grow])

      assert layout(tree, %{width: 30, height: 5}) == [
               %{type: :box, x: 0, y: 0, width: 5, height: 3},
               %{type: :text, x: 1, y: 1, text: "F"},
               %{type: :box, x: 5, y: 0, width: 25, height: 3},
               %{type: :text, x: 6, y: 1, text: "G"}
             ]
    end

    test "column: grow child fills remaining cross... main-axis (vertical) space" do
      fixed =
        box(style: %{width: 10, height: 3, border: :single}, do: text("F"))

      grow =
        box(style: %{width: 10, border: :single}, do: text("G"))
        |> Map.put(:attrs, %{flex: %{grow: 1}})

      tree = column(style: %{gap: 0}, do: [fixed, grow])

      assert layout(tree, %{width: 12, height: 20}) == [
               %{type: :box, x: 0, y: 0, width: 10, height: 3},
               %{type: :text, x: 1, y: 1, text: "F"},
               %{type: :box, x: 0, y: 3, width: 10, height: 17},
               %{type: :text, x: 1, y: 4, text: "G"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # The View DSL `flex/2` macro requires `require Raxol.Core.Renderer.View`
  # to invoke; row/column's compiled attrs never lift `flex_wrap`, so it's
  # only reachable via `flex/2` or a hand-built `attrs.flex_wrap`.
  # ---------------------------------------------------------------------
  describe "flex_wrap" do
    test "View DSL flex/2 macro requires `require Raxol.Core.Renderer.View`, else UndefinedFunctionError" do
      # flex/2 is a macro; without `require` in scope, calling it raises
      # UndefinedFunctionError.
      tree =
        LegacyView.flex style: %{flex_wrap: :wrap}, direction: :row do
          [text("AAAA"), text("BBBB"), text("CCCC")]
        end

      assert tree.type == :flex
      assert tree.style == %{flex_wrap: :wrap}
    end

    test "style-based flex_wrap is honored by the live engine" do
      tree =
        LegacyView.flex style: %{flex_wrap: :wrap}, direction: :row do
          [text("AAAA"), text("BBBB"), text("CCCC")]
        end

      # Container 10 wide, words 4 wide: two fit on line 0, third wraps.
      # align-content defaults to :stretch, splitting the two 1-tall lines
      # 5/5 (wrapped line starts at y=5). Output order is line-reversed, so
      # sort for stability.
      result =
        layout(tree, %{width: 10, height: 10})
        |> Enum.sort_by(&{&1.y, &1.x})

      assert result == [
               %{type: :text, x: 0, y: 0, text: "AAAA"},
               %{type: :text, x: 4, y: 0, text: "BBBB"},
               %{type: :text, x: 0, y: 5, text: "CCCC"}
             ]
    end

    test "hand-built attrs.flex_wrap: :wrap, fits on one line" do
      tree = %{
        type: :flex,
        attrs: %{flex_direction: :row, flex_wrap: :wrap, gap: 0},
        children: [text("AA"), text("BB"), text("CC")]
      }

      assert layout(tree, %{width: 20, height: 10}) == [
               %{type: :text, x: 0, y: 0, text: "AA"},
               %{type: :text, x: 2, y: 0, text: "BB"},
               %{type: :text, x: 4, y: 0, text: "CC"}
             ]
    end

    test "hand-built attrs.flex_wrap: :wrap, breaks into two... three lines (each word alone doesn't fit alongside another)" do
      tree = %{
        type: :flex,
        attrs: %{flex_direction: :row, flex_wrap: :wrap, gap: 0},
        children: [text("AAAAAA"), text("BBBBBB"), text("CCCCCC")]
      }

      # Each 6-wide word alone fits but two together don't, so each gets its
      # own line; order comes back reversed (C, B, A) even though y is
      # ascending (`Wrapper.place_lines_cross/5` prepends). align-content
      # defaults to :stretch, giving allocations 4/3/3 (y = 0/4/7).
      assert layout(tree, %{width: 10, height: 10}) == [
               %{type: :text, x: 0, y: 7, text: "CCCCCC"},
               %{type: :text, x: 0, y: 4, text: "BBBBBB"},
               %{type: :text, x: 0, y: 0, text: "AAAAAA"}
             ]
    end

    test "hand-built attrs.flex_wrap: :wrap, item wider than container gets its own line anyway (no overflow clip)" do
      tree = %{
        type: :flex,
        attrs: %{flex_direction: :row, flex_wrap: :wrap, gap: 0},
        children: [text("AAAAAAAAAAAAAAAAAAAA"), text("B")]
      }

      # An empty line always accepts its first item regardless of fit, so the
      # 20-wide item gets its own line; "B" can't share it and starts a new
      # one. align-content :stretch splits the two lines 5/5 (y=5).
      assert layout(tree, %{width: 10, height: 10}) == [
               %{type: :text, x: 0, y: 5, text: "B"},
               %{type: :text, x: 0, y: 0, text: "AAAAAAAAAAAAAAAAAAAA"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # Literal :row/:column route through the Containers-dialect compat map,
  # whose defaults (gap 1, justify :start, align :start) differ from
  # Flexbox's own defaults (gap 0, align :stretch).
  # ---------------------------------------------------------------------
  describe "literal :row / :column (Containers-dialect compat baseline)" do
    test "literal :row uses Containers defaults: gap 1, justify :start, align :start" do
      tree = %{
        type: :row,
        children: [
          %{type: :label, attrs: [content: "R1"]},
          %{type: :label, attrs: [content: "R2"]},
          %{type: :label, attrs: [content: "R3"]}
        ]
      }

      # Gap 1 between 2-wide labels (x = 0, 3, 6); document order.
      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :text, x: 0, y: 0, text: "R1"},
               %{type: :text, x: 3, y: 0, text: "R2"},
               %{type: :text, x: 6, y: 0, text: "R3"}
             ]
    end

    test "literal :column uses Containers defaults: gap 1, justify :start, align :start" do
      tree = %{
        type: :column,
        children: [
          %{type: :label, attrs: [content: "C1"]},
          %{type: :label, attrs: [content: "C2"]},
          %{type: :label, attrs: [content: "C3"]}
        ]
      }

      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :text, x: 0, y: 0, text: "C1"},
               %{type: :text, x: 0, y: 2, text: "C2"},
               %{type: :text, x: 0, y: 4, text: "C3"}
             ]
    end

    test "literal :row with explicit attrs (justify: :center, align: :center, gap: 2)" do
      tree = %{
        type: :row,
        attrs: %{justify: :center, align: :center, gap: 2},
        children: [
          %{type: :label, attrs: [content: "X1"]},
          %{type: :label, attrs: [content: "X2"]}
        ]
      }

      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :text, x: 12, y: 4, text: "X1"},
               %{type: :text, x: 16, y: 4, text: "X2"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # Real playground demo view trees (not synthetic-only)
  # ---------------------------------------------------------------------
  describe "real playground demo trees" do
    test "TextInputDemo.view/1 with empty model" do
      model = %{value: "", char_count: 0}
      tree = Raxol.Playground.Demos.TextInputDemo.view(model)

      assert layout(tree, %{width: 60, height: 24}) == [
               %{type: :text, x: 0, y: 0, text: "TextInput Demo"},
               %{type: :divider, x: 0, y: 2, width: 60, height: 1},
               %{type: :text, x: 0, y: 4, text: "Input:"},
               %{type: :box, x: 0, y: 6, width: 40, height: 3},
               %{type: :text, x: 2, y: 7, text: "(type to enter text)_"},
               %{type: :box, x: 0, y: 10, width: 16, height: 3},
               %{type: :text, x: 2, y: 11, text: "Type here..."},
               %{type: :divider, x: 0, y: 14, width: 60, height: 1},
               %{type: :box, x: 0, y: 16, width: 40, height: 4},
               %{type: :text, x: 2, y: 17, text: "Value: \"\""},
               %{type: :text, x: 2, y: 18, text: "Length: 0 chars"},
               %{
                 type: :text,
                 x: 0,
                 y: 21,
                 text: "[type] to enter text  [backspace] to delete"
               }
             ]
    end

    test "CheckboxDemo.view/1 with a two-item model" do
      model = %{
        items: [
          %{label: "Enable notifications", checked: false},
          %{label: "Dark mode", checked: true}
        ],
        cursor: 0
      }

      tree = Raxol.Playground.Demos.CheckboxDemo.view(model)

      assert layout(tree, %{width: 60, height: 24}) == [
               %{type: :text, x: 0, y: 0, text: "Checkbox Demo"},
               %{type: :divider, x: 0, y: 2, width: 60, height: 1},
               %{type: :text, x: 0, y: 4, text: "> [ ] Enable notifications"},
               %{type: :text, x: 0, y: 5, text: "  [x] Dark mode"},
               %{type: :divider, x: 0, y: 7, width: 60, height: 1},
               %{type: :text, x: 0, y: 9, text: "Checked: 1/2"},
               %{
                 type: :text,
                 x: 0,
                 y: 11,
                 text: "[j/k] navigate  [space] toggle  [a] toggle all"
               }
             ]
    end
  end

  # ---------------------------------------------------------------------
  # Property check (not a literal pin): every positioned element carries
  # :type and integer :x/:y; sized types also carry non-negative :width/:height.
  # ---------------------------------------------------------------------
  describe "output contract (Engine.apply_layout/2 across all trees above)" do
    defp all_trees do
      grow =
        box(style: %{height: 3, border: :single}, do: text("G"))
        |> Map.put(:attrs, %{flex: %{grow: 1}})

      [
        {row(style: %{gap: 1}, do: [text("A"), text("B"), text("C")]),
         %{width: 40, height: 20}},
        {column(style: %{gap: 3}, do: [text("A"), text("B"), text("C")]),
         %{width: 40, height: 20}},
        {row(style: %{justify_content: :space_evenly}, do: three_wide_ct()),
         %{width: 30, height: 5}},
        {row(style: %{align_items: :stretch}, do: align_children_ct()),
         %{width: 30, height: 10}},
        {box(style: %{width: 10, height: 4}, do: text("hi")),
         %{width: 40, height: 20}},
        {box(style: %{padding: {1, 2, 1, 2}, border: :single}, do: text("hi")),
         %{width: 40, height: 20}},
        {row(
           style: %{gap: 0},
           do: [
             box(style: %{width: 5, height: 3, border: :single}, do: text("F")),
             grow
           ]
         ), %{width: 30, height: 5}},
        {%{
           type: :flex,
           attrs: %{flex_direction: :row, flex_wrap: :wrap, gap: 0},
           children: [text("AAAAAA"), text("BBBBBB"), text("CCCCCC")]
         }, %{width: 10, height: 10}},
        {%{
           type: :row,
           children: [
             %{type: :label, attrs: [content: "R1"]},
             %{type: :label, attrs: [content: "R2"]}
           ]
         }, %{width: 30, height: 10}},
        {%{
           type: :column,
           children: [
             %{type: :label, attrs: [content: "C1"]},
             %{type: :label, attrs: [content: "C2"]}
           ]
         }, %{width: 30, height: 10}},
        {Raxol.Playground.Demos.TextInputDemo.view(%{value: "", char_count: 0}),
         %{width: 60, height: 24}}
      ]
    end

    defp three_wide_ct, do: [text("AA"), text("BB"), text("CC")]

    defp align_children_ct do
      [
        box(style: %{width: 3, height: 1}, do: text("X")),
        box(style: %{width: 3, height: 3}, do: text("Y"))
      ]
    end

    test "every positioned element has :type and integer, non-nil :x/:y" do
      for {tree, dims} <- all_trees() do
        elements = Engine.apply_layout(tree, dims)
        assert elements != [], "expected non-empty layout for #{inspect(dims)}"

        for el <- elements do
          assert Map.has_key?(el, :type)
          assert is_integer(el.x), "non-integer x: #{inspect(el)}"
          assert is_integer(el.y), "non-integer y: #{inspect(el)}"
        end
      end
    end

    test ":box elements have non-negative integer :width/:height" do
      for {tree, dims} <- all_trees() do
        elements = Engine.apply_layout(tree, dims)

        for %{type: :box} = el <- elements do
          assert is_integer(el.width) and el.width >= 0,
                 "bad box width: #{inspect(el)}"

          assert is_integer(el.height) and el.height >= 0,
                 "bad box height: #{inspect(el)}"
        end
      end
    end
  end
end
