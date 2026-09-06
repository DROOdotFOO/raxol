defmodule Raxol.Core.Box do
  @moduledoc """
  Box drawing utilities for Raxol.Core.Buffer.

  Provides functions to draw boxes and fill areas on buffers.
  """

  alias Raxol.Core.Buffer

  # Glyph sets come from `Raxol.UI.Theming.BorderChars`. This module's five
  # style names are preserved exactly: `single`/`double`/`rounded` were
  # byte-identical to two other copies, `heavy` shares its glyphs with
  # `ViewTypes`' `bold`, and this module's `dashed` (double-dash `╌`/`╎`) is
  # kept distinct from `ViewTypes`' finer `┄`/`┆` variant rather than one
  # being silently chosen.
  @box_chars Raxol.UI.Theming.BorderChars.subset([
               :single,
               :double,
               :rounded,
               :heavy,
               :dashed
             ])

  @doc """
  Draw a box border on the buffer.

  ## Parameters
    - buffer: The buffer to draw on
    - x: Left edge x coordinate
    - y: Top edge y coordinate
    - width: Box width (including borders)
    - height: Box height (including borders)
    - border_style: One of :single, :double, :rounded, :heavy, :dashed

  ## Example
      buffer = Buffer.create_blank_buffer(40, 10)
      buffer = Box.draw_box(buffer, 0, 0, 40, 10, :double)
  """
  def draw_box(buffer, x, y, width, height, border_style \\ :single)

  def draw_box(buffer, _x, _y, width, _height, _border_style) when width < 2,
    do: buffer

  def draw_box(buffer, _x, _y, _width, height, _border_style) when height < 2,
    do: buffer

  def draw_box(buffer, x, y, width, height, border_style) do
    chars = Map.get(@box_chars, border_style, @box_chars.single)

    buffer
    |> draw_corners(x, y, width, height, chars)
    |> draw_horizontal_edges(x, y, width, height, chars)
    |> draw_vertical_edges(x, y, width, height, chars)
  end

  @doc """
  Fill a rectangular area with a character.

  ## Parameters
    - buffer: The buffer to fill
    - x: Left edge x coordinate
    - y: Top edge y coordinate
    - width: Area width
    - height: Area height
    - char: Character to fill with
    - style: Style map for the fill character

  ## Example
      buffer = Box.fill_area(buffer, 1, 1, 10, 5, " ", %{bg_color: :blue})
  """
  def fill_area(buffer, x, y, width, height, char, style \\ %{}) do
    Enum.reduce(0..(height - 1), buffer, fn dy, acc ->
      Enum.reduce(0..(width - 1), acc, fn dx, inner_acc ->
        Buffer.set_cell(inner_acc, x + dx, y + dy, char, style)
      end)
    end)
  end

  @doc """
  Draw a horizontal line.
  """
  def draw_horizontal_line(buffer, x, y, length, char \\ "─", style \\ %{}) do
    Enum.reduce(0..(length - 1), buffer, fn i, acc ->
      Buffer.set_cell(acc, x + i, y, char, style)
    end)
  end

  @doc """
  Draw a vertical line.
  """
  def draw_vertical_line(buffer, x, y, length, char \\ "│", style \\ %{}) do
    Enum.reduce(0..(length - 1), buffer, fn i, acc ->
      Buffer.set_cell(acc, x, y + i, char, style)
    end)
  end

  # Private helpers

  defp draw_corners(buffer, x, y, width, height, chars) do
    buffer
    |> Buffer.set_cell(x, y, chars.top_left, %{})
    |> Buffer.set_cell(x + width - 1, y, chars.top_right, %{})
    |> Buffer.set_cell(x, y + height - 1, chars.bottom_left, %{})
    |> Buffer.set_cell(x + width - 1, y + height - 1, chars.bottom_right, %{})
  end

  defp draw_horizontal_edges(buffer, x, y, width, height, chars) do
    buffer
    |> draw_horizontal_line(x + 1, y, width - 2, chars.horizontal)
    |> draw_horizontal_line(x + 1, y + height - 1, width - 2, chars.horizontal)
  end

  defp draw_vertical_edges(buffer, x, y, width, height, chars) do
    buffer
    |> draw_vertical_line(x, y + 1, height - 2, chars.vertical)
    |> draw_vertical_line(x + width - 1, y + 1, height - 2, chars.vertical)
  end
end
