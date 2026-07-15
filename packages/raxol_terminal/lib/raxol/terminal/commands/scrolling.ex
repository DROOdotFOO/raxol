defmodule Raxol.Terminal.Commands.Scrolling do
  @moduledoc """
  Handles scrolling operations for the terminal screen buffer.
  """

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cell
  alias Raxol.Terminal.ScreenBuffer

  # NOTE (harness-ui unit TE): this scroll_up is the function the harness
  # roadmap and `Raxol.Harness.Test.SealOracle` historically named as the
  # scrollback-dropping culprit ("commands/scrolling.ex scroll_up blanks
  # vacated rows"). It is NOT on any live emulator scroll path today --
  # only ScrollOps.scroll_down_with_count/3 and tests reach it. The live
  # paths, where the TE scrollback feed is wired, are:
  #   * Raxol.Terminal.Commands.Screen.scroll_up/2 (DECSTBM region path,
  #     also invoked by ControlCodes.handle_lf/1 at the bottom margin and
  #     Emulator.maybe_scroll/1 on cursor overflow)
  #   * Raxol.Terminal.Operations.ScrollOperations.scroll_up/2
  # both feeding Emulator.BufferOperations.feed_scrollback_from_region_scroll/3.
  @spec scroll_up(
          map(),
          non_neg_integer(),
          {integer(), integer()} | nil,
          any()
        ) :: map()

  def scroll_up(buffer, _count, {region_top, region_bottom}, _blank_style)
      when is_integer(region_top) and is_integer(region_bottom) and
             region_top > region_bottom do
    Raxol.Core.Runtime.Log.debug(
      "Scroll Up: Invalid region (top > bottom). Region: #{inspect({region_top, region_bottom})}. No scroll."
    )

    buffer
  end

  def scroll_up(%{__struct__: _} = buffer, count, scroll_region, blank_style)
      when count > 0 do
    {effective_top, effective_bottom} = get_scroll_region(buffer, scroll_region)
    region_height = effective_bottom - effective_top + 1

    case {count > 0, region_height > 0} do
      {true, true} ->
        actual_scroll_count = min(count, region_height)
        preserved_lines_source_start = effective_top + actual_scroll_count
        _preserved_lines_count = region_height - actual_scroll_count

        new_buffer =
          shift_lines_up(
            buffer,
            effective_top,
            preserved_lines_source_start,
            region_height,
            blank_style
          )

        %{
          new_buffer
          | scroll_position:
              min(
                (buffer.scroll_position || 0) + actual_scroll_count,
                effective_bottom
              )
        }

      _ ->
        buffer
    end
  end

  def scroll_up(buffer, _count, _scroll_region, _blank_style)
      when is_tuple(buffer) do
    raise ArgumentError,
          "Expected buffer struct, got tuple (did you pass result of get_dimensions/1?)"
  end

  def scroll_up(buffer, count, _scroll_region, _blank_style) when count <= 0,
    do: buffer

  @spec scroll_down(
          map(),
          non_neg_integer(),
          {integer(), integer()} | nil,
          any()
        ) :: map()

  def scroll_down(buffer, _count, {region_top, region_bottom}, _blank_style)
      when is_integer(region_top) and is_integer(region_bottom) and
             region_top > region_bottom do
    Raxol.Core.Runtime.Log.debug(
      "Scroll Down: Invalid region (top > bottom). Region: #{inspect({region_top, region_bottom})}. No scroll."
    )

    buffer
  end

  def scroll_down(%{__struct__: _} = buffer, count, scroll_region, blank_style)
      when count > 0 do
    {effective_top, effective_bottom} = get_scroll_region(buffer, scroll_region)
    region_height = effective_bottom - effective_top + 1

    case {count > 0, region_height > 0} do
      {true, true} ->
        actual_scroll_count = min(count, region_height)

        new_buffer =
          shift_lines_down(
            buffer,
            effective_top + actual_scroll_count,
            effective_top,
            region_height,
            blank_style
          )

        %{
          new_buffer
          | scroll_position:
              max(
                (buffer.scroll_position || 0) - actual_scroll_count,
                effective_top
              )
        }

      _ ->
        buffer
    end
  end

  def scroll_down(buffer, _count, _scroll_region, _blank_style)
      when is_tuple(buffer) do
    raise ArgumentError,
          "Expected buffer struct, got tuple (did you pass result of get_dimensions/1?)"
  end

  def scroll_down(buffer, count, _scroll_region, _blank_style) when count <= 0,
    do: buffer

  @spec insert_lines(
          ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: ScreenBuffer.t()

  def insert_lines(buffer, lines, y, top, bottom)
      when is_struct(buffer, ScreenBuffer) and
             is_integer(lines) and is_integer(y) and lines > 0 and
             is_integer(top) and is_integer(bottom) do
    # Ensure y is within the scroll region
    y = max(top, min(y, bottom))

    # Create blank lines with the default style
    blank_style = buffer.default_style || TextFormatting.new()
    blank_cell = Cell.new(" ", blank_style)
    blank_line = List.duplicate(blank_cell, buffer.width)
    blank_lines_to_insert = List.duplicate(blank_line, lines)

    # Split the buffer cells at the insertion row
    {top_part, bottom_part} = Enum.split(buffer.cells, y)

    # Take only the lines from the bottom part that will fit within the scroll region
    max_lines_in_region = bottom - top + 1
    lines_after_insertion = y - top + lines
    lines_to_keep = max(0, max_lines_in_region - lines_after_insertion)

    # Keep lines from the bottom part that fit within the scroll region
    kept_bottom_part = Enum.take(bottom_part, lines_to_keep)

    # Add blank lines at the bottom of the scroll region if needed
    remaining_lines =
      max_lines_in_region - lines_after_insertion - lines_to_keep

    additional_blank_lines =
      case remaining_lines > 0 do
        true -> List.duplicate(blank_line, remaining_lines)
        false -> []
      end

    # Combine the parts
    new_cells =
      top_part ++
        blank_lines_to_insert ++ kept_bottom_part ++ additional_blank_lines

    # Ensure we don't exceed the buffer height
    final_cells = Enum.take(new_cells, buffer.height)

    %{buffer | cells: final_cells}
  end

  defp get_scroll_region(buffer, scroll_region) do
    case scroll_region do
      {top, bottom}
      when is_integer(top) and is_integer(bottom) and top >= 0 and
             bottom <= buffer.height ->
        {top, bottom}

      _ ->
        case Raxol.Terminal.Buffer.ScrollRegion.get_region(buffer) do
          {top, bottom} -> {top, bottom}
          nil -> {0, buffer.height - 1}
        end
    end
  end

  defp shift_lines_up(
         buffer,
         region_start,
         region_start_plus_n,
         region_height,
         blank_style
       ) do
    cells = buffer.cells
    _region_end = region_start + region_height - 1
    n = region_start_plus_n - region_start

    new_cells =
      Enum.with_index(cells)
      |> Enum.map(fn {line, idx} ->
        map_line_for_shift_up(
          idx,
          cells,
          line,
          region_start,
          region_start + region_height - 1,
          n,
          buffer.width,
          blank_style
        )
      end)

    %{buffer | cells: new_cells}
  end

  defp map_line_for_shift_up(
         idx,
         cells,
         line,
         region_start,
         region_end,
         n,
         width,
         blank_style
       ) do
    select_line_for_shift_up(
      idx,
      cells,
      line,
      region_start,
      region_end,
      n,
      width,
      blank_style
    )
  end

  defp select_line_for_shift_up(
         idx,
         cells,
         line,
         region_start,
         region_end,
         n,
         _width,
         _blank_style
       )
       when idx >= region_start and idx <= region_end - n do
    get_source_line(cells, idx + n, line)
  end

  defp select_line_for_shift_up(
         idx,
         _cells,
         _line,
         _region_start,
         region_end,
         n,
         width,
         blank_style
       )
       when idx > region_end - n and idx <= region_end do
    # Create empty line for this position
    List.duplicate(Cell.new(" ", blank_style), width)
  end

  defp select_line_for_shift_up(
         _idx,
         _cells,
         line,
         _region_start,
         _region_end,
         _n,
         _width,
         _blank_style
       ) do
    line
  end

  defp shift_lines_down(
         buffer,
         region_start_plus_n,
         region_start,
         count,
         blank_style
       ) do
    cells = buffer.cells
    region_height = count
    n = region_start_plus_n - region_start
    region_end = region_start + region_height - 1

    new_cells =
      Enum.with_index(cells)
      |> Enum.map(fn {line, idx} ->
        map_line_for_shift_down(
          idx,
          cells,
          line,
          region_start,
          region_end,
          n,
          buffer.width,
          blank_style
        )
      end)

    %{buffer | cells: new_cells}
  end

  defp map_line_for_shift_down(
         idx,
         cells,
         line,
         region_start,
         region_end,
         n,
         width,
         blank_style
       ) do
    select_line_for_shift_down(
      idx,
      cells,
      line,
      region_start,
      region_end,
      n,
      width,
      blank_style
    )
  end

  defp select_line_for_shift_down(
         idx,
         cells,
         line,
         region_start,
         region_end,
         n,
         _width,
         _blank_style
       )
       when idx >= region_start + n and idx <= region_end do
    get_source_line(cells, idx - n, line)
  end

  defp select_line_for_shift_down(
         idx,
         _cells,
         _line,
         region_start,
         _region_end,
         n,
         width,
         blank_style
       )
       when idx >= region_start and idx < region_start + n do
    # Create empty line for this position
    List.duplicate(Cell.new(" ", blank_style), width)
  end

  defp select_line_for_shift_down(
         _idx,
         _cells,
         line,
         _region_start,
         _region_end,
         _n,
         _width,
         _blank_style
       ) do
    line
  end

  defp get_source_line(cells, source_idx, fallback_line) do
    case source_idx >= 0 and source_idx < length(cells) do
      true -> Enum.at(cells, source_idx) || fallback_line
      false -> fallback_line
    end
  end
end
