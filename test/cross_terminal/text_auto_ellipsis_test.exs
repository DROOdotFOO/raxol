defmodule Raxol.CrossTerminal.TextAutoEllipsisTest do
  @moduledoc """
  Text that would paint past a box's own boundary (a visible border or an
  explicit/fill width) gets a grapheme-safe ellipsis backstop at paint
  time instead of bleeding through the border (user report: fixed-width
  bordered box, "The quick brown fox..." ran straight past the right
  border). Mechanism: `Raxol.UI.Layout.Engine` stamps `:text_paint_bound`
  on the space handed to a definite-boundary box's children, which
  becomes `:max_paint_width` + `:text_overflow` on positioned `:text`
  elements; `Raxol.UI.ElementRenderer` truncates each line via
  `Raxol.UI.TextLayout.truncate/3` before emitting cells. See
  docs/core/LAYOUT.md Section 7.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Renderer.View, as: V
  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.TextLayout
  alias Raxol.UI.TextMeasure

  defp bordered_box(text, opts \\ []) do
    width = Keyword.get(opts, :width, 20)
    height = Keyword.get(opts, :height, 3)
    extra_style = Keyword.get(opts, :style, %{})

    V.box(
      style:
        Map.merge(%{border: :single, width: width, height: height}, extra_style),
      children: [V.text(text)]
    )
  end

  defp render(view, dims) do
    view
    |> Engine.apply_layout(dims)
    |> then(&{&1, Raxol.UI.Renderer.render_to_cells(&1, nil)})
  end

  # Reconstruct the painted line at row `y`, restricted to columns
  # `x_from..x_to` (inclusive), in left-to-right order. Cell tuples are
  # {x, y, char, fg, bg, attrs}; a double-width grapheme occupies exactly
  # one tuple at its start column, so x-order concatenation recreates the
  # painted string without needing to account for the "phantom" second
  # column. `render_to_cells/2` is called directly on the flat
  # `apply_layout` output here (each positioned element rendered
  # independently, matching `overflow_test.exs`), which skips the
  # box-vs-children `CellManager.merge_cells/2` compositing the full
  # pipeline does for nested rendering -- an unbordered/unsized box's
  # full-area background fill can share a coordinate with a child's text
  # cell. Last-write-wins by list order reproduces that compositing.
  defp reconstruct(cells, y, x_from, x_to) do
    cells
    |> Enum.filter(fn {x, cy, _c, _fg, _bg, _a} ->
      cy == y and x >= x_from and x <= x_to
    end)
    |> Enum.reduce(%{}, fn {x, _y, c, _fg, _bg, _a}, acc -> Map.put(acc, x, c) end)
    |> Enum.sort_by(fn {x, _c} -> x end)
    |> Enum.map_join(fn {_x, c} -> c end)
  end

  describe "bordered fixed-width box: overlong text" do
    test "renders an ellipsis at the last inner cell and nothing past the border" do
      text = "The quick brown fox jumps over the lazy dog"
      {elements, cells} = render(bordered_box(text), %{width: 40, height: 10})

      box = Enum.find(elements, &(&1.type == :box))
      inner_left = box.x + 1
      inner_right = box.x + box.width - 2
      border_right = box.x + box.width - 1
      text_row = box.y + 1

      ellipsis_cell =
        Enum.find(cells, fn {x, y, _c, _fg, _bg, _a} ->
          x == inner_right and y == text_row
        end)

      assert {^inner_right, ^text_row, "…", _fg, _bg, _attrs} = ellipsis_cell

      # Screenshot-shaped repro proof: nothing text-shaped painted at or
      # past the border column on the text row.
      refute Enum.any?(cells, fn {x, y, c, _fg, _bg, _a} ->
               y == text_row and x >= border_right and c =~ ~r/[A-Za-z]/
             end)

      expected = TextLayout.truncate(text, box.width - 2, :ellipsis)
      assert reconstruct(cells, text_row, inner_left, inner_right) == expected
    end
  end

  describe "CJK boundary" do
    test "never splits a double-width grapheme; ellipsis moves one cell earlier" do
      text = "中文测试ABCDEFGHIJKLMNOP"
      {elements, cells} =
        render(bordered_box(text, width: 14), %{width: 40, height: 10})

      box = Enum.find(elements, &(&1.type == :box))
      inner_left = box.x + 1
      inner_right = box.x + box.width - 2
      text_row = box.y + 1
      inner_width = box.width - 2

      actual = reconstruct(cells, text_row, inner_left, inner_right)
      expected = TextLayout.truncate(text, inner_width, :ellipsis)

      assert actual == expected
      assert TextMeasure.display_width(actual) <= inner_width
      assert String.last(actual) == "…"
    end
  end

  describe "text_overflow: :clip opt-out" do
    test "hard-clips without an ellipsis" do
      text = "The quick brown fox jumps over the lazy dog"

      {elements, cells} =
        render(
          bordered_box(text, style: %{text_overflow: :clip}),
          %{width: 40, height: 10}
        )

      box = Enum.find(elements, &(&1.type == :box))
      inner_left = box.x + 1
      inner_right = box.x + box.width - 2
      border_right = box.x + box.width - 1
      text_row = box.y + 1

      actual = reconstruct(cells, text_row, inner_left, inner_right)
      expected = TextLayout.truncate(text, box.width - 2, :clip)

      assert actual == expected
      refute actual =~ "…"

      refute Enum.any?(cells, fn {x, y, c, _fg, _bg, _a} ->
               y == text_row and x >= border_right and c =~ ~r/[A-Za-z]/
             end)
    end
  end

  describe "non-overflowing text" do
    test "byte-identical to unbounded rendering -- untouched by the backstop" do
      text = "short"
      {elements, cells} = render(bordered_box(text), %{width: 40, height: 10})

      box = Enum.find(elements, &(&1.type == :box))
      inner_left = box.x + 1
      inner_right = box.x + box.width - 2
      text_row = box.y + 1

      actual = reconstruct(cells, text_row, inner_left, inner_right)

      assert actual == text
      refute actual =~ "…"
    end
  end

  describe "multi-line text" do
    test "each line truncates independently" do
      text = "short\nThe quick brown fox jumps over the lazy dog\nok"

      {elements, cells} =
        render(bordered_box(text, height: 5), %{width: 40, height: 10})

      box = Enum.find(elements, &(&1.type == :box))
      inner_left = box.x + 1
      inner_right = box.x + box.width - 2
      inner_width = box.width - 2

      [line1, line2, line3] = String.split(text, "\n")
      first_row = box.y + 1

      for {expected_source, row_offset} <- [{line1, 0}, {line2, 1}, {line3, 2}] do
        row = first_row + row_offset
        expected = TextLayout.truncate(expected_source, inner_width, :ellipsis)
        assert reconstruct(cells, row, inner_left, inner_right) == expected
      end

      # The long middle line actually needed truncation; the short lines
      # didn't -- confirms per-line independence rather than a single
      # element-wide decision.
      assert reconstruct(cells, first_row + 1, inner_left, inner_right) =~ "…"
      refute reconstruct(cells, first_row, inner_left, inner_right) =~ "…"
      refute reconstruct(cells, first_row + 2, inner_left, inner_right) =~ "…"
    end
  end

  describe "boxes without a definite boundary stay unconstrained" do
    test "no border, no explicit width: overflowing text is left untouched" do
      text = "The quick brown fox jumps over the lazy dog"
      view = V.box(style: %{}, children: [V.text(text)])
      {_elements, cells} = render(view, %{width: 15, height: 10})

      actual = reconstruct(cells, 0, 0, 999)
      assert actual == text
      refute actual =~ "…"
    end
  end
end
