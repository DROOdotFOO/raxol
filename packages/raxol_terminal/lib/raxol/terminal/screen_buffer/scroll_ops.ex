defmodule Raxol.Terminal.ScreenBuffer.ScrollOps do
  @moduledoc """
  Scroll operations for ScreenBuffer: region management and scroll up/down.
  """

  alias Raxol.Terminal.Cell
  alias Raxol.Terminal.ScreenBuffer.Operations

  # ========================================
  # Region management
  # ========================================

  def scroll_to(buffer, top, bottom, line) do
    Operations.scroll_to(buffer, top, bottom, line)
  end

  def reset_scroll_region(buffer), do: clear_scroll_region(buffer)

  def get_scroll_top(buffer) do
    case buffer.scroll_region do
      nil -> 0
      {top, _} -> top
    end
  end

  def get_scroll_bottom(buffer) do
    case buffer.scroll_region do
      nil -> buffer.height - 1
      {_, bottom} -> bottom
    end
  end

  def set_scroll_region(buffer, {top, bottom}) do
    Operations.set_region(buffer, top, bottom)
  end

  def set_scroll_region(buffer, top, bottom)
      when is_integer(top) and is_integer(bottom) do
    Operations.set_region(buffer, top, bottom)
  end

  def clear_scroll_region(buffer), do: %{buffer | scroll_region: nil}

  def get_scroll_region_boundaries(buffer) do
    case buffer.scroll_region do
      nil -> {0, buffer.height - 1}
      {top, bottom} -> {top, bottom}
    end
  end

  def get_scroll_position(buffer), do: buffer.scroll_position || 0

  def get_scroll_region(buffer), do: Operations.get_region(buffer)

  def shift_region_to_line(buffer, region, target_line) do
    Operations.shift_region_to_line(buffer, region, target_line)
  end

  def scroll_down_with_count(buffer, lines, count)
      when is_integer(lines) and is_integer(count) do
    Raxol.Terminal.Commands.Scrolling.scroll_down(
      buffer,
      lines,
      buffer.scroll_region,
      %{}
    )
  end

  def scroll_down_with_count(buffer, _lines, count) when is_integer(count) do
    scroll_down(buffer, count)
  end

  # ========================================
  # Scroll content (formerly in Scrolling)
  # ========================================

  @doc """
  Scrolls the buffer content up by the specified number of lines within the scroll region.
  Returns {buffer, scrolled_lines}.
  """
  def scroll_up(buffer, lines) when lines > 0 do
    {top, bottom} = get_effective_scroll_region(buffer)

    if top < bottom do
      cells = buffer.cells || []
      {before_region, region_and_after} = Enum.split(cells, top)
      {region, after_region} = Enum.split(region_and_after, bottom - top + 1)

      lines_to_scroll = min(lines, length(region))
      scrolled_out = Enum.take(region, lines_to_scroll)
      remaining_region = Enum.drop(region, lines_to_scroll)
      empty_lines = List.duplicate(create_empty_line(buffer.width), lines_to_scroll)
      scrolled_region = remaining_region ++ empty_lines
      new_cells = before_region ++ scrolled_region ++ after_region
      {%{buffer | cells: new_cells}, scrolled_out}
    else
      {buffer, []}
    end
  end

  def scroll_up(buffer, _), do: {buffer, []}

  @doc """
  Scrolls the buffer content down by the specified number of lines within the scroll region.
  """
  def scroll_down(buffer, lines) when lines > 0 do
    {top, bottom} = get_effective_scroll_region(buffer)

    if top < bottom do
      cells = buffer.cells || []
      {before_region, region_and_after} = Enum.split(cells, top)
      {region, after_region} = Enum.split(region_and_after, bottom - top + 1)

      lines_to_scroll = min(lines, length(region))
      empty_lines = List.duplicate(create_empty_line(buffer.width), lines_to_scroll)
      kept_region = Enum.take(region, length(region) - lines_to_scroll)
      scrolled_region = empty_lines ++ kept_region
      new_cells = before_region ++ scrolled_region ++ after_region
      %{buffer | cells: new_cells}
    else
      buffer
    end
  end

  def scroll_down(buffer, _), do: buffer

  @doc """
  Scrolls up within an explicit top/bottom region.

  Returns `{buffer, scrolled_out_rows}` -- the rows evicted from the top of
  the region, oldest-first -- mirroring `scroll_up/2`'s two-arg contract.
  Whether `scrolled_out_rows` is scrollback-eligible depends on the region:
  callers feeding an effective top of 0 (screen row 1, including the
  no-region/full-screen case) should treat them as real scrollback history;
  callers with an interior region (top > 0) discard them, matching
  real-terminal behavior where only a top-anchored scroll region feeds
  native scrollback.
  """
  def scroll_up(buffer, top, bottom, lines) do
    {effective_top, effective_bottom} = normalize_scroll_region(buffer, top, bottom)
    cells = buffer.cells || []

    if effective_top < effective_bottom and lines > 0 do
      {before_region, region_and_after} = Enum.split(cells, effective_top)
      {region, after_region} = Enum.split(region_and_after, effective_bottom - effective_top + 1)

      lines_to_scroll = min(lines, length(region))
      scrolled_out = Enum.take(region, lines_to_scroll)
      kept_region = Enum.drop(region, lines_to_scroll)
      empty_lines = List.duplicate(create_empty_line(buffer.width), lines_to_scroll)
      scrolled_region = kept_region ++ empty_lines
      new_cells = before_region ++ scrolled_region ++ after_region
      {%{buffer | cells: new_cells}, scrolled_out}
    else
      {buffer, []}
    end
  end

  @doc """
  Scrolls down within an explicit top/bottom region.
  """
  def scroll_down(buffer, top, bottom, lines) do
    {effective_top, effective_bottom} = normalize_scroll_region(buffer, top, bottom)
    cells = buffer.cells || []

    if effective_top < effective_bottom and lines > 0 do
      {before_region, region_and_after} = Enum.split(cells, effective_top)
      {region, after_region} = Enum.split(region_and_after, effective_bottom - effective_top + 1)

      lines_to_scroll = min(lines, length(region))
      empty_lines = List.duplicate(create_empty_line(buffer.width), lines_to_scroll)
      kept_region = Enum.take(region, length(region) - lines_to_scroll)
      scrolled_region = empty_lines ++ kept_region
      new_cells = before_region ++ scrolled_region ++ after_region
      %{buffer | cells: new_cells}
    else
      buffer
    end
  end

  # Private helpers

  defp get_effective_scroll_region(buffer) do
    case buffer.scroll_region do
      nil -> {0, buffer.height - 1}
      {top, bottom} -> {top, min(bottom, buffer.height - 1)}
    end
  end

  defp normalize_scroll_region(buffer, top, bottom) do
    {max(0, top), min(buffer.height - 1, bottom)}
  end

  defp create_empty_line(width) when is_integer(width) and width > 0 do
    List.duplicate(Cell.new(), width)
  end

  defp create_empty_line(_width), do: []
end
