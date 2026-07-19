defmodule Raxol.Terminal.Buffer.WriterFillCellsTest do
  @moduledoc """
  F0-buffer: `Writer.fill_cells/3` is the bulk row-pass equivalent of a
  sequential `write_char` fold. `write_char` stays (it has other callers)
  and is the ORACLE here: for any buffer and write list, `fill_cells`
  must produce exactly the buffer the per-cell fold produces -- ordering,
  overwrite, wide-char placeholders, bounds handling, and resolver-visible
  intermediate state included.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Buffer.Writer
  alias Raxol.Terminal.Cell
  alias Raxol.Terminal.ScreenBuffer

  # --- oracle -------------------------------------------------------------
  # The pre-existing semantics: one write_char per cell, in list order. The
  # resolver (when given) sees the cell currently at the target position --
  # including cells written earlier in the same batch -- and only runs for
  # in-bounds writes (an out-of-bounds write is skipped entirely; resolving
  # for it was always unobservable since the style is pure and discarded).
  defp oracle(buffer, cells, resolver \\ nil) do
    Enum.reduce(cells, buffer, fn {x, y, char, style}, acc ->
      ScreenBuffer.write_char(acc, x, y, char, oracle_resolve(acc, x, y, style, resolver))
    end)
  end

  defp oracle_resolve(_acc, _x, _y, style, nil), do: style

  defp oracle_resolve(acc, x, y, style, resolver) do
    case x < acc.width and y < acc.height do
      true -> resolver.(style, acc.cells |> Enum.at(y) |> Enum.at(x))
      false -> style
    end
  end

  # The backends inheritance policy, restated: an unpainted background
  # inherits the background of whatever is currently at the coordinate.
  defp inherit_bg(style, current) when is_map(style) do
    case Map.get(style, :background) do
      nil -> Map.put(style, :background, current_bg(current))
      _painted -> style
    end
  end

  defp inherit_bg(style, _current), do: style

  defp current_bg(%{style: %{background: bg}}), do: bg
  defp current_bg(_), do: nil

  defp cell_at(buffer, x, y), do: buffer.cells |> Enum.at(y) |> Enum.at(x)

  # --- basic equivalence --------------------------------------------------

  test "empty write list returns the buffer unchanged" do
    buffer = ScreenBuffer.new(10, 4)
    assert Writer.fill_cells(buffer, []) == buffer
  end

  test "single write equals write_char" do
    buffer = ScreenBuffer.new(10, 4)
    cells = [{3, 1, "A", %{foreground: :red}}]
    assert Writer.fill_cells(buffer, cells) == oracle(buffer, cells)
  end

  test "unsorted input across rows and columns equals the sequential fold" do
    buffer = ScreenBuffer.new(12, 5)

    cells = [
      {7, 3, "d", %{foreground: :blue}},
      {0, 0, "a", nil},
      {11, 4, "z", %{background: :green}},
      {2, 3, "c", %{bold: true}},
      {5, 0, "b", %{foreground: :red, background: :black}},
      {1, 2, "m", %{}},
      {0, 3, "q", %{underline: true}}
    ]

    assert Writer.fill_cells(buffer, cells) == oracle(buffer, cells)
  end

  test "rows untouched by the write list keep their original cells" do
    buffer = ScreenBuffer.new(6, 4)
    cells = [{1, 1, "x", nil}]
    filled = Writer.fill_cells(buffer, cells)

    assert Enum.at(filled.cells, 0) == Enum.at(buffer.cells, 0)
    assert Enum.at(filled.cells, 2) == Enum.at(buffer.cells, 2)
    assert Enum.at(filled.cells, 3) == Enum.at(buffer.cells, 3)
  end

  # --- overwrite ordering -------------------------------------------------

  test "last write at a position wins" do
    buffer = ScreenBuffer.new(8, 2)

    cells = [
      {4, 1, "1", %{foreground: :red}},
      {4, 1, "2", %{foreground: :green}},
      {4, 1, "3", %{foreground: :blue}}
    ]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)
    assert cell_at(filled, 4, 1).char == "3"
    assert cell_at(filled, 4, 1).style.foreground == :blue
  end

  test "out-of-x-order writes within a row follow input order, not x order" do
    buffer = ScreenBuffer.new(8, 1)

    # narrow at x=5 first, wide at x=4 second: the wide char's placeholder
    # must overwrite the earlier x=5 write (input order wins).
    cells = [
      {5, 0, "A", %{foreground: :red}},
      {4, 0, "字", %{foreground: :green}}
    ]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)
    assert cell_at(filled, 4, 0).char == "字"
    assert cell_at(filled, 5, 0).wide_placeholder == true
  end

  # --- wide characters ----------------------------------------------------

  test "wide char writes a placeholder sharing the primary cell's style" do
    buffer = ScreenBuffer.new(8, 1)
    cells = [{2, 0, "字", %{foreground: :cyan, background: :black}}]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)

    primary = cell_at(filled, 2, 0)
    placeholder = cell_at(filled, 3, 0)
    assert primary.char == "字"
    assert placeholder.wide_placeholder == true
    assert placeholder.char == " "
    assert placeholder.style == primary.style
    assert :erts_debug.same(placeholder.style, primary.style)
  end

  test "a later narrow write overwrites the wide placeholder" do
    buffer = ScreenBuffer.new(8, 1)

    cells = [
      {2, 0, "字", %{foreground: :cyan}},
      {3, 0, "B", %{foreground: :yellow}}
    ]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)
    assert cell_at(filled, 3, 0).char == "B"
    assert cell_at(filled, 3, 0).wide_placeholder == false
  end

  # BEHAVIOR CHANGE: this used to assert the glyph was written anyway (with
  # no placeholder). That left the terminal drawing a two-column glyph into
  # a one-column space, so the row painted one column wider than its own
  # buffer and shoved whatever framed it out of alignment -- the same class
  # of corruption as the renderer emitting placeholders. A wide glyph with
  # nowhere to put its second half is now dropped to a blank instead of
  # being half-placed, which is what a terminal does when it cannot fit
  # one. (`fill_cells/3` writes at explicit coordinates and has no
  # authority to wrap to the next row, so dropping is the only option here.)
  test "wide char at the last column is dropped, not half-placed" do
    buffer = ScreenBuffer.new(8, 1)
    cells = [{7, 0, "字", %{foreground: :red}}]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)
    assert cell_at(filled, 7, 0).char == " "
    assert cell_at(filled, 7, 0).wide_placeholder == false
    # The style still lands, so a painted background is not punched through.
    assert cell_at(filled, 7, 0).style.foreground == :red
  end

  test "emoji from the pictographs range is wide" do
    buffer = ScreenBuffer.new(8, 1)
    cells = [{1, 0, "🎉", nil}]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)
    assert cell_at(filled, 2, 0).wide_placeholder == true
  end

  # --- bounds -------------------------------------------------------------

  test "writes beyond width or height are skipped" do
    buffer = ScreenBuffer.new(6, 3)

    cells = [
      {6, 0, "A", nil},
      {99, 1, "B", nil},
      {0, 3, "C", nil},
      {0, 99, "D", nil},
      {2, 2, "E", nil}
    ]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)
    assert cell_at(filled, 2, 2).char == "E"
  end

  test "a write list that is entirely out of bounds returns the buffer unchanged" do
    buffer = ScreenBuffer.new(4, 2)
    cells = [{4, 0, "A", nil}, {0, 2, "B", nil}]
    assert Writer.fill_cells(buffer, cells) == buffer
  end

  # --- style handling -----------------------------------------------------

  test "nil style falls back to the default TextFormatting, like write_char" do
    buffer = ScreenBuffer.new(6, 2)
    cells = [{1, 0, "A", nil}]
    assert Writer.fill_cells(buffer, cells) == oracle(buffer, cells)
  end

  test "fg/bg atom keys are renamed like write_char's create_cell_style" do
    buffer = ScreenBuffer.new(6, 2)
    cells = [{1, 0, "A", %{fg: :red, bg: :blue}}]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)
    assert cell_at(filled, 1, 0).style.foreground == :red
    assert cell_at(filled, 1, 0).style.background == :blue
  end

  test "cells with equal styles share one merged style term" do
    buffer = ScreenBuffer.new(10, 2)
    style = %{foreground: :red, background: :black, bold: true}

    cells = [
      {0, 0, "a", style},
      {3, 0, "b", style},
      {5, 1, "c", style},
      {7, 1, "d", %{foreground: :green}}
    ]

    filled = Writer.fill_cells(buffer, cells)
    assert filled == oracle(buffer, cells)

    s1 = cell_at(filled, 0, 0).style
    s2 = cell_at(filled, 3, 0).style
    s3 = cell_at(filled, 5, 1).style
    assert :erts_debug.same(s1, s2)
    assert :erts_debug.same(s1, s3)
    refute cell_at(filled, 7, 1).style == s1
  end

  # --- resolver (interleaved style resolution) ----------------------------

  test "resolver sees a cell written earlier in the same batch at the same position" do
    buffer = ScreenBuffer.new(6, 1)

    # modal/button chain: first write paints the background; the second
    # write at the same coordinate has no background and must inherit the
    # FIRST write's background, not the pristine buffer's.
    cells = [
      {2, 0, " ", %{foreground: :white, background: :magenta}},
      {2, 0, "B", %{foreground: :black}}
    ]

    filled = Writer.fill_cells(buffer, cells, &inherit_bg/2)
    assert filled == oracle(buffer, cells, &inherit_bg/2)
    assert cell_at(filled, 2, 0).char == "B"
    assert cell_at(filled, 2, 0).style.background == :magenta
  end

  test "resolver inherits from a wide placeholder written earlier in the batch" do
    buffer = ScreenBuffer.new(8, 1)

    cells = [
      {2, 0, "字", %{foreground: :cyan, background: :blue}},
      {3, 0, "x", %{foreground: :red}}
    ]

    filled = Writer.fill_cells(buffer, cells, &inherit_bg/2)
    assert filled == oracle(buffer, cells, &inherit_bg/2)
    assert cell_at(filled, 3, 0).style.background == :blue
  end

  test "resolver sees the pristine cell where nothing was written yet" do
    buffer = ScreenBuffer.new(6, 1)
    cells = [{1, 0, "A", %{foreground: :red}}]

    filled = Writer.fill_cells(buffer, cells, &inherit_bg/2)
    assert filled == oracle(buffer, cells, &inherit_bg/2)
    assert cell_at(filled, 1, 0).style.background == nil
  end

  test "with a resolver, style sharing keys on the resolved style" do
    buffer = ScreenBuffer.new(10, 2)

    # Same raw style at two positions over different painted backgrounds
    # resolves to different styles; over equal backgrounds it must share.
    cells = [
      {0, 0, " ", %{background: :red}},
      {1, 0, " ", %{background: :red}},
      {0, 0, "a", %{foreground: :white}},
      {1, 0, "b", %{foreground: :white}}
    ]

    filled = Writer.fill_cells(buffer, cells, &inherit_bg/2)
    assert filled == oracle(buffer, cells, &inherit_bg/2)
    assert cell_at(filled, 0, 0).style.background == :red
    assert :erts_debug.same(cell_at(filled, 0, 0).style, cell_at(filled, 1, 0).style)
  end

  # --- ScreenBuffer delegate ----------------------------------------------

  test "ScreenBuffer.fill_cells/2,3 delegates to Writer.fill_cells" do
    buffer = ScreenBuffer.new(6, 2)
    cells = [{1, 0, "A", %{foreground: :red}}, {2, 1, "字", nil}]

    assert ScreenBuffer.fill_cells(buffer, cells) == Writer.fill_cells(buffer, cells)

    assert ScreenBuffer.fill_cells(buffer, cells, &inherit_bg/2) ==
             Writer.fill_cells(buffer, cells, &inherit_bg/2)
  end

  # --- randomized equivalence against the write_char fold ------------------

  test "randomized write lists match the sequential write_char fold exactly" do
    :rand.seed(:exsss, {1121, 2233, 3345})

    chars = ["A", "b", " ", "字", "漢", "🎉", "-", "│"]

    styles = [
      nil,
      %{},
      %{foreground: :red},
      %{background: :blue},
      %{foreground: :white, background: :black},
      %{foreground: :green, bold: true},
      %{fg: :yellow},
      %{underline: true, italic: true},
      %{foreground: {255, 128, 0}, background: {0, 0, 0}}
    ]

    for round <- 1..12 do
      width = 4 + :rand.uniform(12)
      height = 1 + :rand.uniform(5)
      buffer = ScreenBuffer.new(width, height)

      cells =
        for _ <- 1..(20 + :rand.uniform(180)) do
          # positions deliberately spill past the grid on both axes
          x = :rand.uniform(width + 3) - 1
          y = :rand.uniform(height + 2) - 1
          {x, y, Enum.random(chars), Enum.random(styles)}
        end

      plain = Writer.fill_cells(buffer, cells)
      assert plain == oracle(buffer, cells), "plain mismatch in round #{round}"

      resolved = Writer.fill_cells(buffer, cells, &inherit_bg/2)

      assert resolved == oracle(buffer, cells, &inherit_bg/2),
             "resolver mismatch in round #{round}"
    end
  end
end
