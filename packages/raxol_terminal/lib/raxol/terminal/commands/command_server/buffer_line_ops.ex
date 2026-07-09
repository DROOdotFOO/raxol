defmodule Raxol.Terminal.Commands.CommandServer.BufferLineOps do
  @moduledoc false
  @compile {:no_warn_undefined, Raxol.Terminal.Commands.CommandServer.Helpers}


  alias Raxol.Terminal.Cell
  alias Raxol.Terminal.Commands.CommandServer.Helpers
  alias Raxol.Terminal.Emulator

  def handle_insert_lines(emulator, %{params: params}, _context) do
    count = Helpers.get_param(params, 0, 1)
    perform_insert_lines(emulator, count)
  end

  def handle_delete_lines(emulator, %{params: params}, _context) do
    count = Helpers.get_param(params, 0, 1)
    perform_delete_lines(emulator, count)
  end

  def handle_delete_characters(emulator, %{params: params}, _context) do
    count = Helpers.get_param(params, 0, 1)
    perform_delete_characters(emulator, count)
  end

  def handle_insert_characters(emulator, %{params: params}, _context) do
    count = Helpers.get_param(params, 0, 1)
    perform_insert_characters(emulator, count)
  end

  defp perform_insert_lines(emulator, count) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    {y, _} = Helpers.get_cursor_position(emulator)
    style = Helpers.get_default_style(active_buffer)

    case Map.get(emulator, :scroll_region) do
      {scroll_top, scroll_bottom} when y >= scroll_top and y <= scroll_bottom ->
        updated_buffer =
          insert_lines_within_scroll_region(
            active_buffer,
            y,
            count,
            style,
            scroll_top,
            scroll_bottom
          )

        {:ok, Helpers.update_emulator_buffer(emulator, updated_buffer)}

      _ ->
        updated_buffer = insert_lines_normal(active_buffer, y, count, style)
        {:ok, Helpers.update_emulator_buffer(emulator, updated_buffer)}
    end
  end

  defp perform_delete_lines(emulator, count) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    {y, _} = Helpers.get_cursor_position(emulator)
    style = Helpers.get_default_style(active_buffer)

    case Map.get(emulator, :scroll_region) do
      {scroll_top, scroll_bottom} when y >= scroll_top and y <= scroll_bottom ->
        updated_buffer =
          delete_lines_within_scroll_region(
            active_buffer,
            y,
            count,
            style,
            scroll_top,
            scroll_bottom
          )

        {:ok, Helpers.update_emulator_buffer(emulator, updated_buffer)}

      {_scroll_top, _scroll_bottom} ->
        {:ok, emulator}

      nil ->
        updated_buffer = delete_lines_normal(active_buffer, y, count, style)
        {:ok, Helpers.update_emulator_buffer(emulator, updated_buffer)}
    end
  end

  defp perform_delete_characters(emulator, count) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    {y, x} = Helpers.get_cursor_position(emulator)
    style = Helpers.get_default_style(active_buffer)
    updated_buffer = delete_characters(active_buffer, y, x, count, style)
    {:ok, Helpers.update_emulator_buffer(emulator, updated_buffer)}
  end

  defp perform_insert_characters(emulator, count) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    {y, x} = Helpers.get_cursor_position(emulator)
    style = Helpers.get_default_style(active_buffer)
    updated_buffer = insert_characters(active_buffer, y, x, count, style)
    {:ok, Helpers.update_emulator_buffer(emulator, updated_buffer)}
  end

  defp insert_lines_normal(buffer, y, count, style) do
    blank_cell = Cell.new(" ", style)
    blank_line = List.duplicate(blank_cell, buffer.width)
    blank_lines = List.duplicate(blank_line, count)

    {lines_before, lines_after} = Enum.split(buffer.cells, y)
    lines_to_keep = max(0, buffer.height - y - count)
    kept_lines = Enum.take(lines_after, lines_to_keep)

    final_cells = lines_before ++ blank_lines ++ kept_lines
    %{buffer | cells: final_cells}
  end

  defp insert_lines_within_scroll_region(
         buffer,
         y,
         count,
         style,
         scroll_top,
         scroll_bottom
       ) do
    blank_cell = Cell.new(" ", style)
    blank_line = List.duplicate(blank_cell, buffer.width)
    blank_lines_to_insert = List.duplicate(blank_line, count)

    {lines_before_scroll, rest} = Enum.split(buffer.cells, scroll_top)

    {scroll_region_lines, lines_after_scroll} =
      Enum.split(rest, scroll_bottom - scroll_top + 1)

    insertion_point = y - scroll_top

    {scroll_before, scroll_after} =
      Enum.split(scroll_region_lines, insertion_point)

    max_lines_in_region = scroll_bottom - scroll_top + 1
    available_space_after = max_lines_in_region - insertion_point - count

    kept_lines =
      if available_space_after > 0 do
        Enum.take(scroll_after, available_space_after)
      else
        []
      end

    new_scroll_region = scroll_before ++ blank_lines_to_insert ++ kept_lines

    padded_scroll_region =
      if length(new_scroll_region) < max_lines_in_region do
        new_scroll_region ++
          List.duplicate(
            blank_line,
            max_lines_in_region - length(new_scroll_region)
          )
      else
        Enum.take(new_scroll_region, max_lines_in_region)
      end

    final_cells =
      lines_before_scroll ++ padded_scroll_region ++ lines_after_scroll

    %{buffer | cells: final_cells}
  end

  defp delete_lines_within_scroll_region(
         buffer,
         y,
         count,
         style,
         scroll_top,
         scroll_bottom
       ) do
    blank_cell = Cell.new(" ", style)
    blank_line = List.duplicate(blank_cell, buffer.width)
    blank_lines_to_add = List.duplicate(blank_line, count)

    {lines_before_scroll, rest} = Enum.split(buffer.cells, scroll_top)

    {scroll_region_lines, lines_after_scroll} =
      Enum.split(rest, scroll_bottom - scroll_top + 1)

    deletion_point = y - scroll_top

    {scroll_before, scroll_after} =
      Enum.split(scroll_region_lines, deletion_point)

    remaining_lines = Enum.drop(scroll_after, count)

    max_lines_in_region = scroll_bottom - scroll_top + 1
    new_scroll_region = scroll_before ++ remaining_lines ++ blank_lines_to_add

    padded_scroll_region =
      if length(new_scroll_region) < max_lines_in_region do
        new_scroll_region ++
          List.duplicate(
            blank_line,
            max_lines_in_region - length(new_scroll_region)
          )
      else
        Enum.take(new_scroll_region, max_lines_in_region)
      end

    final_cells =
      lines_before_scroll ++ padded_scroll_region ++ lines_after_scroll

    %{buffer | cells: final_cells}
  end

  defp delete_lines_normal(buffer, y, count, style) do
    blank_cell = Cell.new(" ", style)
    blank_line = List.duplicate(blank_cell, buffer.width)

    {lines_before, lines_after} = Enum.split(buffer.cells, y)
    remaining_lines = Enum.drop(lines_after, count)

    blank_lines_needed = min(count, buffer.height - y)
    blank_lines = List.duplicate(blank_line, blank_lines_needed)

    final_cells = lines_before ++ remaining_lines ++ blank_lines
    %{buffer | cells: final_cells}
  end

  defp delete_characters(buffer, y, x, count, style) do
    case Enum.at(buffer.cells, y) do
      nil ->
        buffer

      line ->
        {chars_before, chars_after} = Enum.split(line, x)
        remaining_chars = Enum.drop(chars_after, count)

        blank_cell = Cell.new(" ", style)
        blank_chars = List.duplicate(blank_cell, count)

        new_line = chars_before ++ remaining_chars ++ blank_chars
        final_line = Enum.take(new_line, buffer.width)

        updated_cells = List.replace_at(buffer.cells, y, final_line)
        %{buffer | cells: updated_cells}
    end
  end

  defp insert_characters(buffer, y, x, count, style) do
    case Enum.at(buffer.cells, y) do
      nil ->
        buffer

      line ->
        {chars_before, chars_after} = Enum.split(line, x)

        blank_cell = Cell.new(" ", style)
        blank_chars = List.duplicate(blank_cell, count)

        new_line = chars_before ++ blank_chars ++ chars_after
        final_line = Enum.take(new_line, buffer.width)

        updated_cells = List.replace_at(buffer.cells, y, final_line)
        %{buffer | cells: updated_cells}
    end
  end
end
