defmodule Raxol.Terminal.Buffer.LineOperations.Deletion do
  @moduledoc """
  Line deletion operations for terminal buffers.
  Handles deletion of single and multiple lines, with support for scroll regions.
  """

  @doc """
  Delete lines from a buffer.
  """
  def delete_lines(buffer, count) do
    {_x, y} = buffer.cursor_position
    delete_lines(buffer, y, count)
  end

  def delete_lines(buffer, start_y, count) do
    alias Raxol.Terminal.ScreenBuffer.DataAdapter

    DataAdapter.with_lines_format(buffer, fn buffer_with_lines ->
      lines = Map.get(buffer_with_lines, :lines, %{})
      height = Map.get(buffer_with_lines, :height, 24)

      # Remove the specified lines using functional patterns
      new_lines =
        0..(height - 1)
        |> Enum.map(fn new_y ->
          {new_y, map_deleted_line(lines, new_y, start_y, count, height)}
        end)
        |> Enum.reject(fn {_y, line} -> is_nil(line) end)
        |> Enum.into(%{})

      %{buffer_with_lines | lines: new_lines}
    end)
  end

  def delete_lines(buffer, start_y, count, scroll_top, scroll_bottom) do
    delete_lines_in_region(buffer, start_y, count, scroll_top, scroll_bottom)
  end

  def delete_lines(buffer, start_y, count, scroll_top, scroll_bottom, _style) do
    # delete_lines_in_region already fills with empty lines
    delete_lines_in_region(buffer, start_y, count, scroll_top, scroll_bottom)
  end

  @doc """
  Delete lines within a scroll region.

  DL on the list of rows: `count` rows from `start_y` go (clamped to the rows
  left in the region, as in xterm), the rest of the region moves up, and blank
  rows fill its bottom. Only the region's rows are touched, and every blank
  row is the same term, so the cost is one row plus the screen's height. A
  cursor outside the region deletes nothing. `bottom` is clamped to the rows
  the buffer has, so a region set for a taller screen cannot grow the row list.
  """
  def delete_lines_in_region(%{cells: cells, width: width} = buffer, start_y, count, top, bottom)
      when start_y >= top and start_y <= bottom do
    bottom = min(bottom, length(cells) - 1)
    region_rows = max(bottom - start_y + 1, 0)
    count = min(count, region_rows)
    {above, from_cursor} = Enum.split(cells, start_y)
    {region, below} = Enum.split(from_cursor, region_rows)
    blank = List.duplicate(Raxol.Terminal.Cell.new(), width)

    shifted = Enum.drop(region, count) ++ List.duplicate(blank, count)

    %{buffer | cells: above ++ shifted ++ below}
  end

  def delete_lines_in_region(buffer, _start_y, _count, _top, _bottom), do: buffer

  # Pattern match for new line positions after deletion
  # Lines before deletion stay in same position
  defp map_deleted_line(lines, new_y, start_y, _count, _height)
       when new_y < start_y do
    Map.get(lines, new_y)
  end

  # Lines after deletion get content from shifted positions
  defp map_deleted_line(lines, new_y, start_y, count, height)
       when new_y >= start_y do
    source_y = new_y + count
    map_shifted_line(lines, source_y, height)
  end

  defp create_empty_line_with_defaults do
    Enum.map(0..79, fn _ -> %{char: " ", style: %{}} end)
  end

  defp map_shifted_line(lines, source_y, height) when source_y < height do
    Map.get(lines, source_y)
  end

  defp map_shifted_line(_lines, _source_y, _height),
    do: create_empty_line_with_defaults()
end
