defmodule Raxol.Terminal.Buffer.LineOperations.Management do
  @moduledoc """
  Line management operations for terminal buffers.
  Handles line creation, retrieval, and manipulation.
  """

  @doc """
  Get a line from the buffer.
  """
  def get_line(buffer, y) do
    Map.get(
      buffer.lines,
      y,
      create_empty_line(Map.get(buffer, :width, 80), %{})
    )
  end

  @doc """
  Set a line in the buffer.
  """
  def set_line(buffer, y, line) do
    lines = Map.put(buffer.lines, y, line)
    %{buffer | lines: lines}
  end

  @doc """
  Update a line with a function.
  """
  def update_line(buffer, y, fun) when is_function(fun, 1) do
    line = get_line(buffer, y)
    new_line = fun.(line)
    set_line(buffer, y, new_line)
  end

  @doc """
  Clear a line to spaces.
  """
  def clear_line(buffer, y, style \\ %{}) do
    width = Map.get(buffer, :width, 80)
    empty_line = create_empty_line(width, style)
    set_line(buffer, y, empty_line)
  end

  @doc """
  Splits a list of rows for IL/DL at `y`: the rows above it, the region from
  `y` to `bottom` (clamped to the rows there are, so a region set for a
  taller screen cannot grow the list) and the rows below, with `count`
  clamped to the region's height.
  """
  @spec split_region(list(), non_neg_integer(), non_neg_integer(), integer()) ::
          {list(), list(), list(), non_neg_integer()}
  def split_region(cells, y, count, bottom) do
    region_rows = max(min(bottom, length(cells) - 1) - y + 1, 0)
    {above, from_cursor} = Enum.split(cells, y)
    {region, below} = Enum.split(from_cursor, region_rows)
    {above, region, below, min(count, region_rows)}
  end

  @doc """
  Create an empty line with the given width.
  """
  def create_empty_line(width, style) do
    Enum.map(0..(width - 1), fn _ -> %{char: " ", style: style} end)
  end

  @doc """
  Create multiple empty lines.
  """
  def create_empty_lines(count, width) do
    create_empty_lines(count, width, %{})
  end

  def create_empty_lines(count, width, style) do
    Enum.map(1..count, fn _ -> create_empty_line(width, style) end)
  end

  @doc """
  Remove lines from the top of the buffer.
  """
  def pop_top_lines(buffer, count) do
    alias Raxol.Terminal.ScreenBuffer.DataAdapter

    # Use adapter to work with buffer in lines format
    DataAdapter.with_lines_format(buffer, fn buffer_with_lines ->
      lines = Map.get(buffer_with_lines, :lines, %{})
      height = Map.get(buffer_with_lines, :height, 24)

      # Extract top lines
      popped = Enum.map(0..(count - 1), fn y -> Map.get(lines, y) end)

      # Shift remaining lines up
      new_lines =
        Enum.reduce(0..(height - 1), %{}, fn y, acc ->
          if y < height - count do
            Map.put(acc, y, Map.get(lines, y + count))
          else
            # Fill bottom with empty lines
            Map.put(
              acc,
              y,
              create_empty_line(Map.get(buffer_with_lines, :width, 80), %{})
            )
          end
        end)

      # Return both popped lines and modified buffer
      {popped, %{buffer_with_lines | lines: new_lines}}
    end)
  end

  @doc """
  Add blank lines or provided lines to the beginning of the buffer.
  """
  def prepend_lines(buffer, count) when is_integer(count) do
    width = Map.get(buffer, :width, 80)
    default_style = Map.get(buffer, :default_style, %{})
    new_lines = create_empty_lines(count, width, default_style)
    prepend_lines(buffer, new_lines)
  end

  def prepend_lines(buffer, new_lines) when is_list(new_lines) do
    alias Raxol.Terminal.ScreenBuffer.DataAdapter

    # Use adapter to work with buffer in lines format
    DataAdapter.with_lines_format(buffer, fn buffer_with_lines ->
      lines = Map.get(buffer_with_lines, :lines, %{})
      height = Map.get(buffer_with_lines, :height, 24)
      count = length(new_lines)

      # Build new line mapping
      shifted_lines =
        Enum.reduce(0..(height - 1), %{}, fn y, acc ->
          cond do
            y < count ->
              # Add new lines at top
              Map.put(acc, y, Enum.at(new_lines, y))

            y < height ->
              # Shift existing lines down
              source_y = y - count

              if source_y < height - count do
                Map.put(acc, y, Map.get(lines, source_y))
              else
                acc
              end

            true ->
              acc
          end
        end)

      %{buffer_with_lines | lines: shifted_lines}
    end)
  end
end
