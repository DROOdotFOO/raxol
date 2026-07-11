defmodule Raxol.CrossTerminal.LayoutCharacterizationTest do
  @moduledoc """
  Characterization net for the live layout engine.

  Pins the CURRENT geometry of `Raxol.UI.Layout.Engine.apply_layout/2`
  across the two flex-like dialects it dispatches:

    1. `:flex` elements (View DSL `row`/`column`/`flex` macros) -> the real
       `Raxol.UI.Layout.Flexbox` path.
    2. Literal `:row`/`:column` elements -> the engine's Containers-dialect
       compat map (`containers_compat_to_flex/2`), which has its own
       gap/align/justify defaults distinct from dialect 1's.

  Pins document behavior AS-IS, including quirks and outright bugs; each
  quirk carries a comment. These are not "correct" assertions — they are
  a tripwire: if a change alters a number here, the change was either
  intentional (re-pin consciously) or a regression.
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
      base = Map.take(el, [:type, :x, :y, :width, :height])

      case el do
        %{type: :text, text: t} -> Map.put(base, :text, t)
        _ -> base
      end
    end)
  end

  defp layout(tree, dims \\ %{width: 40, height: 20}) do
    tree |> Engine.apply_layout(dims) |> simplify()
  end

  # ---------------------------------------------------------------------
  # 1. gap conventions: row/column, gap 0/1/3, both `style: %{gap: n}` and
  #    the top-level `gap:` opt. `enrich_flex_attrs`/`build_flex_attrs`
  #    (engine.ex) read `style.gap` first, falling back to the top-level
  #    `flex.gap` field that `Flex.row/column` always sets (default 0) --
  #    so both conventions must produce identical geometry here. That
  #    equivalence is itself part of what's pinned.
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
  # 2. justify_content, all six values, via `style: %{justify_content: j}`
  #    (top-level `justify:` on the DSL is a red herring: `Flex.row/column`
  #    default it to the literal atom `:start`, which does not match any
  #    `Positioner.calculate_justify_positioning/4` clause and silently
  #    falls through to the `{0, gap}` catch-all -- i.e. behaves like
  #    `:flex_start` by accident, not by design. Not separately pinned
  #    here since it's redundant with the flex_start case below.)
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
  # 3. align_items on the cross axis (row, height 10; children a 1-tall
  #    box "X" and a 3-tall box "Y", both with EXPLICIT style height).
  #
  #    Known-wrong (problems backlog #4, cited by the caller): the
  #    proposal expects `align_items: :stretch` to blindly overwrite
  #    explicit cross sizes. Empirically it does NOT for `:box` elements
  #    with an explicit style height -- `Positioner.align_cross/4` DOES
  #    stretch the child's `space.height` to the container's full cross
  #    size, but `Engine.process_element(%{type: :box}, ...)` then
  #    re-derives its own height via `min(explicit_h, space.height)`,
  #    which clamps back down to the explicit style height. So stretch
  #    is a no-op whenever the box declares its own height.
  #
  #    Stretch DOES take effect for boxes with NO explicit height (see
  #    the "stretch with no explicit height" test below) -- there,
  #    `space.height` flows straight through as the box's own height.
  #    Pin both cases: they characterize the actual boundary of the bug.
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

    test "stretch is a no-op when children declare an explicit height (problems backlog #4)" do
      tree = row(style: %{align_items: :stretch}, do: align_children())

      # Identical to flex_start -- NOT stretched to height 10, because box's
      # own min(explicit_h, space.height) clamp wins. This is the surprising
      # half of #4: the bug is real but narrower than "stretch always wins".
      assert layout(tree, %{width: 30, height: 10}) == [
               %{type: :box, x: 0, y: 0, width: 3, height: 1},
               %{type: :text, x: 0, y: 0, text: "X"},
               %{type: :box, x: 3, y: 0, width: 3, height: 3},
               %{type: :text, x: 3, y: 0, text: "Y"}
             ]
    end

    test "stretch DOES override when the box has no explicit height (problems backlog #4)" do
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
  # 4. box explicit sizing conventions
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
  # 5. nesting: column-in-row, row-in-column, box-in-column-in-row (3 deep)
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
  # 6. grow child (attrs.flex.grow) beside a fixed-size sibling
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
  # 7. flex_wrap
  #
  #    Finding on the "flex macro crashed" lead from the task brief: the
  #    View DSL `flex/2` macro (`Raxol.Core.Renderer.View.flex(opts, do:
  #    block)`) is NOT re-exported by `Raxol.View.Elements` (Elements only
  #    re-exports a `def flex(constraints)` arity-1 function, a totally
  #    different thing -- `LayoutHelpers.flex/1`, a size calculator, not a
  #    container builder). Calling the macro form without first doing
  #    `require Raxol.Core.Renderer.View` raises
  #    `UndefinedFunctionError: function Raxol.Core.Renderer.View.flex/2 is
  #    undefined or private` because macros can't be invoked as remote
  #    calls without `require`. That is almost certainly what the earlier
  #    probe script hit. With `require`, the macro builds a normal
  #    `%{type: :flex, style: %{flex_wrap: :wrap}, ...}` map without
  #    crashing -- see the "style-based flex_wrap is silently ignored"
  #    test below.
  #
  #    Deeper finding: even once built correctly, `style: %{flex_wrap:
  #    :wrap}}` never reaches `Flexbox.process_flex/3` on the live path.
  #    `Engine.build_flex_attrs/1` (engine.ex) only lifts
  #    `justify_content`, `align_items`, `gap`, and `padding` from style
  #    into `:attrs` -- `flex_wrap` is never lifted, from style OR from
  #    the top-level `:wrap` field `Flex.container/1` sets. So flex_wrap
  #    is UNREACHABLE from the View DSL on the live engine; the only way
  #    to reach `Flexbox.Wrapper` is a hand-built element with
  #    `attrs: %{flex_wrap: :wrap}` directly, exactly as the task brief
  #    suspected.
  # ---------------------------------------------------------------------
  describe "flex_wrap" do
    test "View DSL flex/2 macro requires `require Raxol.Core.Renderer.View`, else UndefinedFunctionError" do
      # Reproduces the crash lead: flex/2 is a macro, not a function: it
      # cannot be dispatched without require in scope. This module already
      # has `require Raxol.Core.Renderer.View` at the top, so calling it
      # here succeeds -- the assertion documents WHY an un-required call
      # site would blow up.
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

      # engine's build_flex_attrs lifts flex_wrap (plus
      # flex_direction/align_content) from style. Container 10
      # wide, words 4 wide: two fit on line 0, third wraps to line 1.
      # Output order is line-reversed (pre-existing Wrapper accumulation
      # quirk, pinned elsewhere) - sort for a stable assertion.
      result =
        layout(tree, %{width: 10, height: 10})
        |> Enum.sort_by(&{&1.y, &1.x})

      assert result == [
               %{type: :text, x: 0, y: 0, text: "AAAA"},
               %{type: :text, x: 4, y: 0, text: "BBBB"},
               %{type: :text, x: 0, y: 1, text: "CCCC"}
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

      # Container is 10 wide; each 6-wide word alone fits (6<=10) but two
      # together don't (6+6=12>10), so each word gets its own line. NOTE
      # the returned order: lines come back reverse-of-visual-order
      # (C, B, A) even though the Y coordinates are correctly ascending --
      # `Wrapper.place_lines_cross/5` builds the accumulator via
      # `positioned_line ++ acc`. Pinned as-is.
      #
      # align-content defaults to :stretch (CSS initial value): three
      # 1-tall lines in a 10-tall container get stretched allocations
      # 4/3/3, so lines start at y=0/4/7.
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

      # First item is 20 wide against a 10-wide container -- Wrapper still
      # places it (an empty `current_line` always accepts the first item
      # regardless of fit), then "B" can't share the line (20+0+1 > 10) so
      # it starts its own line. Same reversed-order quirk as above.
      #
      # default align-content :stretch expands the two 1-tall lines to
      # 5/5, so line two starts at y=5.
      assert layout(tree, %{width: 10, height: 10}) == [
               %{type: :text, x: 0, y: 5, text: "B"},
               %{type: :text, x: 0, y: 0, text: "AAAAAAAAAAAAAAAAAAAA"}
             ]
    end
  end

  # ---------------------------------------------------------------------
  # 8. Literal :row / :column element types -- routed through the
  #    engine's Containers-dialect compat map (`containers_compat_to_flex/2`
  #    in engine.ex), which is a different dialect from the View DSL
  #    row/column macros (those build :flex maps processed by Flexbox
  #    directly):
  #
  #      gap     1        (Flexbox's default is 0 -- MISMATCH)
  #      justify :start
  #      align   :start   (Flexbox's default is :stretch -- MISMATCH)
  #
  #    Children come back in document order.
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
  # 9. Real playground demo view trees (not synthetic-only)
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
  # 10. Output contract (proposal "Output contract (eng-review G1)"):
  #     every positioned element carries :type and integer :x/:y; sized
  #     types additionally carry non-negative integer :width/:height; no
  #     coordinate is ever nil. Exercised across every tree built above,
  #     re-derived at test time (not a literal pin -- a property check).
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
