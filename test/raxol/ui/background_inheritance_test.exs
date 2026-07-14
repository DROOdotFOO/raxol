defmodule Raxol.UI.BackgroundInheritanceTest do
  @moduledoc """
  An unpainted background shows what is beneath it, rather than erasing it.

  Cells do not composite -- writing one replaces what was there -- so a cell
  written with an unpainted background would clear the background already at
  that coordinate, punching a hole through a filled parent. A button drawn on a
  modal would show the desktop through itself.

  "Unpainted" has to mean the same thing everywhere: *show what is beneath*. Over
  a filled parent that is the parent's fill; at the top of the tree there is
  nothing beneath, so it stays unpainted and the terminal shows through.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.CellManager

  defp bg_at(cells, x, y) do
    Enum.find_value(cells, fn
      {^x, ^y, _c, _fg, bg, _a} -> {:ok, bg}
      _ -> nil
    end)
  end

  test "an unpainted cell drawn over a filled one inherits its background" do
    fill = [{1, 1, " ", :white, :blue, []}]
    glyph = [{1, 1, "y", :white, nil, []}]

    merged = CellManager.merge_cells(fill, glyph)

    assert bg_at(merged, 1, 1) == {:ok, :blue},
           "an unpainted background must not erase the fill beneath it"

    assert [{1, 1, "y", :white, :blue, []}] = merged
  end

  test "a painted cell still overrides the one beneath it" do
    fill = [{1, 1, " ", :white, :blue, []}]
    button = [{1, 1, "y", :white, :red, []}]

    assert [{1, 1, "y", :white, :red, []}] =
             CellManager.merge_cells(fill, button)
  end

  test "with nothing beneath, an unpainted cell stays unpainted" do
    glyph = [{1, 1, "y", :white, nil, []}]

    assert [{1, 1, "y", :white, nil, []}] = CellManager.merge_cells([], glyph)
  end

  test "inheritance is positional -- only the covered coordinate inherits" do
    fill = [{1, 1, " ", :white, :blue, []}]
    glyphs = [{1, 1, "y", :white, nil, []}, {9, 9, "n", :white, nil, []}]

    merged = CellManager.merge_cells(fill, glyphs)

    assert bg_at(merged, 1, 1) == {:ok, :blue}
    assert bg_at(merged, 9, 9) == {:ok, nil}
  end
end
