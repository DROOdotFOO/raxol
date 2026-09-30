defmodule Raxol.Terminal.Buffer.LineOperations.Insertion do
  @moduledoc """
  Line insertion operations for terminal buffers.
  Handles insertion of single and multiple lines with style support.
  """

  alias Raxol.Terminal.Buffer.LineOperations.Management

  @doc """
  Insert empty lines at the current cursor position.
  """
  def insert_lines(buffer, count) do
    {_x, y} = buffer.cursor_position
    insert_lines(buffer, y, count)
  end

  def insert_lines(buffer, y, count) do
    do_insert_lines(buffer, y, count, %{})
  end

  def insert_lines(buffer, y, count, style) do
    do_insert_lines(buffer, y, count, style)
  end

  def insert_lines(buffer, y, count, scroll_top, scroll_bottom) do
    do_insert_lines_with_style(buffer, y, count, scroll_top, scroll_bottom)
  end

  def insert_lines(buffer, y, count, scroll_top, scroll_bottom, _style) do
    # do_insert_lines_in_region already creates blank lines with style
    do_insert_lines_in_region(buffer, y, count, scroll_top, scroll_bottom)
  end

  @doc """
  Internal insertion with default style.
  """
  def do_insert_lines(buffer, y, count, style) do
    alias Raxol.Terminal.ScreenBuffer.DataAdapter

    DataAdapter.with_lines_format(buffer, fn buffer_with_lines ->
      lines = Map.get(buffer_with_lines, :lines, %{})
      height = Map.get(buffer_with_lines, :height, 24)
      width = Map.get(buffer_with_lines, :width, 80)

      # Build new lines using pattern matching
      new_lines =
        0..(height - 1)
        |> Enum.map(fn line_y ->
          {line_y, build_line_at_position(lines, line_y, y, count, width, style, height)}
        end)
        |> Enum.reject(fn {_line_y, line} -> is_nil(line) end)
        |> Enum.into(%{})

      %{buffer_with_lines | lines: new_lines}
    end)
  end

  @doc """
  Insert lines with style in a scroll region.
  """
  def do_insert_lines_with_style(buffer, y, count, scroll_top, scroll_bottom) do
    do_insert_lines_in_region(buffer, y, count, scroll_top, scroll_bottom)
  end

  # Helper functions

  # IL within the scroll region, on the list of rows: the rows from `y` down
  # move down by `count` (clamped to the rows left in the region, as in
  # xterm), those pushed past the region's bottom are dropped, and `count`
  # blank rows fill the gap. Only the region's rows are touched, and every
  # inserted row is the same blank row, so the cost is one row plus the
  # screen's height, not a cell per inserted cell. A cursor outside the
  # region inserts nothing. `bottom` is clamped to the rows the buffer has:
  # a region set for a taller screen (before a resize, or past the cell
  # ceiling) would otherwise grow the row list.
  defp do_insert_lines_in_region(%{cells: cells, width: width} = buffer, y, count, top, bottom)
       when y >= top and y <= bottom do
    {above, region, below, count} = Management.split_region(cells, y, count, bottom)
    blank = List.duplicate(Raxol.Terminal.Cell.new(), width)

    shifted =
      List.duplicate(blank, count) ++ Enum.take(region, length(region) - count)

    %{buffer | cells: above ++ shifted ++ below}
  end

  defp do_insert_lines_in_region(buffer, _y, _count, _top, _bottom), do: buffer

  defp create_empty_line(width, style) do
    Enum.map(0..(width - 1), fn _ -> %{char: " ", style: style} end)
  end

  # Pattern match on line position relative to insertion point
  defp build_line_at_position(
         lines,
         line_y,
         insert_y,
         _count,
         _width,
         _style,
         _height
       )
       when line_y < insert_y do
    # Lines before insertion point stay the same
    Map.get(lines, line_y)
  end

  defp build_line_at_position(
         _lines,
         line_y,
         insert_y,
         count,
         width,
         style,
         _height
       )
       when line_y >= insert_y and line_y < insert_y + count do
    # Insert new empty lines
    create_empty_line(width, style)
  end

  defp build_line_at_position(
         lines,
         line_y,
         _insert_y,
         count,
         _width,
         _style,
         height
       )
       when line_y < height do
    # Shift remaining lines down if they fit
    source_y = line_y - count
    build_shifted_line(lines, source_y, height - count)
  end

  defp build_line_at_position(
         _lines,
         _line_y,
         _insert_y,
         _count,
         _width,
         _style,
         _height
       ) do
    nil
  end

  defp build_shifted_line(lines, source_y, max_source)
       when source_y < max_source do
    Map.get(lines, source_y)
  end

  defp build_shifted_line(_lines, _source_y, _max_source), do: nil
end
