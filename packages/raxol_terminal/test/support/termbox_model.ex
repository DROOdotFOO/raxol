defmodule Raxol.Terminal.Termbox.Model do
  @moduledoc """
  Pure reference model of termbox2's back-buffer cell semantics.

  This is the reference oracle for the NIF equivalence test: apply the same op
  stream here and to the termbox2 NIF, then compare the resulting cell grids.
  The model mirrors `termbox2.h` for the operations it supports:

    * the initial and cleared cell is `{0x20, 0, 0}` (space, default fg, default bg)
    * `set_cell` writes one cell when in bounds; out of bounds is a no-op
    * `print` writes the lead cell for each printable codepoint and advances x by
      one column, with `\\n` returning to the start column and moving down

  Width note: `print` advances one column per codepoint. That is exact for ASCII
  strings and for a single wide character (whose trailing advance does not affect
  the grid). Multi-codepoint strings containing wide characters are out of scope;
  cover wide characters with `set_cell` instead.

  Grid format matches `:termbox2_nif.tb_cell_buffer/0`: a row-major list of
  `{ch, fg, bg}` tuples, length `width * height`, indexed `(y * width) + x`.
  """

  @space 0x20
  @default_fg 0
  @default_bg 0
  @replacement 0xFFFD

  @type cell :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  @type op ::
          {:set_cell, integer(), integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer()}
          | {:print, integer(), integer(), non_neg_integer(), non_neg_integer(), binary()}
          | :clear

  @doc """
  Render `ops` onto a fresh `width` x `height` grid.

  Returns the row-major cell list in the same shape as
  `:termbox2_nif.tb_cell_buffer/0`.
  """
  @spec render([op()], pos_integer(), pos_integer()) :: [cell()]
  def render(ops, width, height) when width > 0 and height > 0 do
    ops
    |> Enum.reduce(blank(width, height), &apply_op(&1, &2, width, height))
    |> to_list(width, height)
  end

  defp blank(width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), into: %{} do
      {{x, y}, {@space, @default_fg, @default_bg}}
    end
  end

  defp apply_op(:clear, _grid, width, height), do: blank(width, height)

  defp apply_op({:set_cell, x, y, ch, fg, bg}, grid, width, height) do
    put_cell(grid, x, y, {ch, fg, bg}, width, height)
  end

  defp apply_op({:print, x, y, fg, bg, string}, grid, width, height) do
    print(grid, x, y, fg, bg, string, width, height)
  end

  # Mirrors tb_print_ex: an out-of-bounds start position is a no-op.
  defp print(grid, x, y, _fg, _bg, _string, width, height)
       when x < 0 or x >= width or y < 0 or y >= height,
       do: grid

  defp print(grid, x0, y0, fg, bg, string, width, height) do
    string
    |> String.to_charlist()
    |> Enum.reduce({grid, x0, y0}, fn
      ?\n, {grid, _x, y} ->
        {grid, x0, y + 1}

      cp, {grid, x, y} ->
        {put_cell(grid, x, y, {printable(cp), fg, bg}, width, height), x + 1, y}
    end)
    |> elem(0)
  end

  # Printable ASCII passes through; anything else becomes U+FFFD, matching
  # termbox2 for control characters. Print fixtures use printable ASCII and `\n`.
  defp printable(cp) when cp >= 0x20 and cp <= 0x7E, do: cp
  defp printable(_cp), do: @replacement

  defp put_cell(grid, x, y, cell, width, height)
       when x >= 0 and x < width and y >= 0 and y < height,
       do: Map.put(grid, {x, y}, cell)

  defp put_cell(grid, _x, _y, _cell, _width, _height), do: grid

  defp to_list(grid, width, height) do
    for y <- 0..(height - 1), x <- 0..(width - 1), do: Map.fetch!(grid, {x, y})
  end
end
