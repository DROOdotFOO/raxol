defmodule Raxol.Terminal.Buffer.CharEditor do
  @moduledoc """
  Manages terminal character editing operations.
  """

  alias Raxol.Terminal.Cell

  @doc """
  Inserts a character at the current position.
  """
  def insert_char(%Cell{} = cell, char) when is_binary(char) do
    %{cell | char: char}
  end

  @doc """
  Deletes a character at the current position.
  """
  def delete_char(%Cell{} = cell) do
    %{cell | char: " "}
  end

  @doc """
  Replaces a character at the current position.
  """
  def replace_char(%Cell{} = cell, char) when is_binary(char) do
    %{cell | char: char}
  end

  @doc """
  Inserts a string of characters.
  """
  def insert_string(%Cell{} = cell, string) when is_binary(string) do
    case String.length(string) do
      0 -> cell
      1 -> insert_char(cell, string)
      _ -> %{cell | char: string}
    end
  end

  @doc """
  Deletes a string of characters.
  """
  def delete_string(%Cell{} = cell, length)
      when is_integer(length) and length > 0 do
    case length do
      1 -> delete_char(cell)
      _ -> %{cell | char: " "}
    end
  end

  @doc """
  Replaces a string of characters.
  """
  def replace_string(%Cell{} = cell, string) when is_binary(string) do
    case String.length(string) do
      0 -> cell
      1 -> replace_char(cell, string)
      _ -> %{cell | char: string}
    end
  end

  @doc """
  Checks if a character is a control character.
  """
  def control_char?(char) when is_binary(char) do
    case String.to_charlist(char) do
      [c] when c < 32 or c == 127 -> true
      _ -> false
    end
  end

  @doc """
  Checks if a character is a printable character.
  """
  def printable_char?(char) when is_binary(char) do
    case String.to_charlist(char) do
      [c] when c >= 32 and c != 127 -> true
      _ -> false
    end
  end

  @doc """
  Checks if a character is a whitespace character.
  """
  def whitespace_char?(char) when is_binary(char) do
    char in [" ", "\t", "\n", "\r"]
  end

  @doc """
  Gets the width of a character.
  """
  def char_width(char) when is_binary(char) do
    case String.to_charlist(char) do
      [c] when c < 32 or c == 127 -> 0
      [c] when c < 128 -> 1
      _ -> 2
    end
  end

  @doc """
  Gets the width of a string.
  """
  def string_width(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> Enum.map(&char_width/1)
    |> Enum.sum()
  end

  @doc """
  Determines the content length of a line (number of non-blank characters).
  """
  def content_length(line) do
    line
    |> Enum.take_while(fn cell -> cell.char != " " end)
    |> length()
  end

  @doc """
  Truncates a line to the specified content length, padding with blank cells if needed.
  """
  def truncate_to_content_length(line, content_length) do
    case length(line) <= content_length do
      true ->
        # Pad with blank cells if line is shorter than content length
        padding = List.duplicate(Cell.new(" "), content_length - length(line))
        line ++ padding

      false ->
        # Truncate to content length
        Enum.take(line, content_length)
    end
  end

  defp pad_or_truncate_line(line, width) when length(line) < width do
    # Use the style of the last cell if present, else defaults
    last_cell = List.last(line) || Cell.new(" ")
    style = Map.get(last_cell, :style)
    len = length(line)

    # Padding cells should always have dirty: false since they don't represent changes
    padding =
      Enum.map(1..(width - len), fn _ ->
        %Cell{
          char: " ",
          style: style,
          dirty: false,
          wide_placeholder: false
        }
      end)

    line ++ padding
  end

  defp pad_or_truncate_line(line, width) when length(line) > width do
    Enum.take(line, width)
  end

  defp pad_or_truncate_line(line, _width), do: line

  @doc """
  Inserts a specified number of characters at the given position.
  Characters to the right of the insertion point are shifted right.
  Characters shifted off the end of the line are discarded.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `row` - The row to insert characters in
  * `col` - The column to start inserting at
  * `count` - The number of characters to insert

  ## Returns

  The updated screen buffer.
  """
  @spec insert_chars(
          Raxol.Terminal.ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Raxol.Terminal.ScreenBuffer.t()

  def insert_chars(buffer, row, col, count) do
    insert_chars_if_valid(buffer, row, col, count)
  end

  defp can_insert_at_position?(buffer, row, col, count) do
    case buffer.cells do
      nil ->
        # Return false if cells is nil
        false

      cells ->
        col + count <= buffer.width and
          col <= content_length(Enum.at(cells, row))
    end
  end

  defp valid_insert_params?(buffer, row, col, count) do
    is_struct(buffer) and
      is_integer(row) and is_integer(col) and is_integer(count) and
      row >= 0 and col >= 0 and count > 0 and
      row < buffer.height and col < buffer.width
  end

  @doc """
  Inserts a specified number of characters at the given position.
  Characters to the right of the insertion point are shifted right.
  Characters shifted off the end of the line are discarded.
  Uses the provided default style for new characters.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `row` - The row to insert characters in
  * `col` - The column to start inserting at
  * `count` - The number of characters to insert
  * `default_style` - The style to apply to new characters

  ## Returns

  The updated screen buffer.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> style = %{fg: :red, bg: :blue}
      iex> buffer = CharEditor.insert_characters(buffer, 0, 0, 5, style)
      iex> CharEditor.get_char(buffer, 0, 0)
      " "
  """
  @spec insert_characters(
          Raxol.Terminal.ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Raxol.Terminal.ANSI.TextFormatting.text_style()
        ) :: Raxol.Terminal.ScreenBuffer.t()
  def insert_characters(buffer, row, col, count, default_style)
      when row >= 0 and col >= 0 and count > 0 do
    insert_chars_in_bounds(buffer, row, col, count, default_style)
  end

  @doc """
  Inserts characters into a line at the specified position.

  ## Parameters

  * `line` - The line to modify
  * `col` - The column to start inserting at
  * `count` - The number of characters to insert
  * `default_style` - The style to apply to new characters

  ## Returns

  The updated line with inserted characters.

  ## Examples

      iex> line = List.duplicate(%Cell{}, 10)
      iex> style = %{fg: :red, bg: :blue}
      iex> new_line = CharEditor.insert_into_line(line, 5, 3, style)
      iex> length(new_line)
      10
  """
  @spec insert_into_line(
          list(Cell.t()),
          non_neg_integer(),
          non_neg_integer(),
          Raxol.Terminal.ANSI.TextFormatting.text_style()
        ) :: list(Cell.t())
  def insert_into_line(line, col, count, default_style) do
    line_length = length(line)
    # As in xterm, ICH inserts at most up to the right margin: anything past it
    # would be shifted off the line anyway, so never build more blanks than fit.
    count = min(count, max(line_length - col, 0))
    {left_part, right_part} = Enum.split(line, col)
    # Inserted blanks are not dirty (for consistency with delete_from_line)
    blank_cell = %Cell{
      char: " ",
      style: default_style,
      dirty: false,
      wide_placeholder: false
    }

    blank_cells = List.duplicate(blank_cell, count)
    shifted_right = Enum.take(right_part, line_length - col - count)
    result = left_part ++ blank_cells ++ shifted_right
    pad_or_truncate_line(result, line_length)
  end

  @doc """
  Deletes a specified number of characters starting from the given position.
  Characters to the right of the deleted characters are shifted left.
  Blank characters are added at the end of the line.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `row` - The row to delete characters from
  * `col` - The column to start deleting from
  * `count` - The number of characters to delete

  ## Returns

  The updated screen buffer.
  """
  @spec delete_chars(
          Raxol.Terminal.ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Raxol.Terminal.ScreenBuffer.t()
  def delete_chars(buffer, row, col, count) do
    case valid_delete_params?(buffer, row, col, count) do
      true -> delete_characters(buffer, row, col, count, buffer.default_style)
      false -> buffer
    end
  end

  defp valid_delete_params?(buffer, row, col, count) do
    is_struct(buffer) and
      is_integer(row) and is_integer(col) and is_integer(count) and
      row >= 0 and col >= 0 and count > 0 and
      row < buffer.height and col < buffer.width
  end

  @doc """
  Deletes a specified number of characters starting from the given position.
  Characters to the right of the deleted characters are shifted left.
  Blank characters are added at the end of the line with the specified style.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `row` - The row to delete characters from
  * `col` - The column to start deleting from
  * `count` - The number of characters to delete
  * `default_style` - The style to apply to new blank characters

  ## Returns

  The updated screen buffer.
  """
  @spec delete_characters(
          Raxol.Terminal.ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Raxol.Terminal.ANSI.TextFormatting.text_style()
        ) :: Raxol.Terminal.ScreenBuffer.t()
  def delete_characters(buffer, row, col, count, default_style)
      when row >= 0 and col >= 0 and count > 0 do
    delete_chars_in_bounds(buffer, row, col, count, default_style)
  end

  @doc """
  Deletes characters from a line at the specified position.

  ## Parameters

  * `line` - The line to modify
  * `col` - The column to start deleting from
  * `count` - The number of characters to delete
  * `default_style` - The style to apply to new blank characters

  ## Returns

  The updated line with deleted characters replaced by blanks.

  ## Examples

      iex> line = List.duplicate(%Cell{}, 10)
      iex> style = %{fg: :red, bg: :blue}
      iex> new_line = CharEditor.delete_from_line(line, 5, 3, style)
      iex> length(new_line)
      10
  """
  @spec delete_from_line(
          list(Cell.t()),
          non_neg_integer(),
          non_neg_integer(),
          Raxol.Terminal.ANSI.TextFormatting.text_style()
        ) :: list(Cell.t())
  def delete_from_line(line, col, count, default_style) do
    line_length = length(line)
    left_part = Enum.take(line, col)
    right_part = Enum.drop(line, col + count)

    blank_cell = %Cell{
      char: " ",
      style: default_style,
      dirty: false,
      wide_placeholder: false
    }

    blanks_needed = line_length - length(left_part) - length(right_part)
    blank_cells = List.duplicate(blank_cell, blanks_needed)
    result = left_part ++ right_part ++ blank_cells
    Enum.take(result, line_length)
  end

  @doc """
  Writes a character at the specified position in the buffer.
  """
  def write_char(buffer, row, col, char) when is_binary(char) do
    write_char_if_in_bounds(buffer, row, col, char)
  end

  @doc """
  Writes a string at the specified position in the buffer.
  """
  def write_string(buffer, row, col, string) when is_binary(string) do
    # Check if position is valid
    write_string_if_valid_position(buffer, row, col, string)
  end

  defp update_line_with_chars_wide_aware(line, col, chars, width) do
    Enum.reduce(Enum.with_index(chars), {line, col}, fn {char, _index}, {acc_line, current_col} ->
      process_char_in_line(acc_line, current_col, char, width)
    end)
    |> elem(0)
  end

  defp process_char_in_line(line, col, char, width) do
    process_char_if_fits(line, col, char, width)
  end

  def update_line_with_string(line, col, string, width) do
    chars = String.graphemes(string)

    Enum.reduce(Enum.with_index(chars), line, fn {char, index}, acc_line ->
      pos = col + index

      replace_char_if_in_width(acc_line, pos, char, width)
    end)
  end

  @doc """
  Erases a specified number of characters starting from the given position.
  Characters to the right of the erased characters are shifted left.
  Blank characters are added at the end of the line.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `row` - The row to erase characters from
  * `col` - The column to start erasing from
  * `count` - The number of characters to erase

  ## Returns

  The updated screen buffer.
  """
  @spec erase_chars(
          Raxol.Terminal.ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Raxol.Terminal.ScreenBuffer.t()
  def erase_chars(buffer, row, col, count) do
    case valid_erase_params?(buffer, row, col, count) do
      true -> erase_chars_in_buffer(buffer, row, col, count)
      false -> buffer
    end
  end

  @doc """
  Erases a specified number of characters starting from the given position with a specific style.
  Characters to the right of the erased characters are shifted left.
  Blank characters are added at the end of the line with the specified style.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `row` - The row to erase characters from
  * `col` - The column to start erasing from
  * `count` - The number of characters to erase
  * `style` - The style to apply to new blank characters

  ## Returns

  The updated screen buffer.
  """
  @spec erase_chars(
          Raxol.Terminal.ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          Raxol.Terminal.ANSI.TextFormatting.text_style()
        ) :: Raxol.Terminal.ScreenBuffer.t()
  def erase_chars(buffer, row, col, count, style) do
    case valid_erase_params?(buffer, row, col, count) do
      true -> erase_chars_in_buffer_with_style(buffer, row, col, count, style)
      false -> buffer
    end
  end

  defp valid_erase_params?(buffer, row, col, count) do
    is_struct(buffer) and
      is_integer(row) and is_integer(col) and is_integer(count) and
      row >= 0 and col >= 0 and count > 0 and
      row < buffer.height and col < buffer.width
  end

  defp erase_chars_in_buffer_with_style(buffer, row, col, count, style) do
    line = Enum.at(buffer.cells, row)

    updated_line =
      erase_chars_in_line_with_style(line, col, count, buffer.width, style)

    cells = List.replace_at(buffer.cells, row, updated_line)
    %{buffer | cells: cells}
  end

  defp erase_chars_in_line_with_style(line, col, count, width, style) do
    {left, _} = Enum.split(line, col)
    right = Enum.slice(line, col + count, width - (col + count))

    new_line = left ++ right
    padding_needed = max(0, width - length(new_line))

    (new_line ++ List.duplicate(Cell.new(" ", style), padding_needed))
    |> Enum.take(width)
  end

  defp erase_chars_in_buffer(buffer, row, col, count) do
    line = Enum.at(buffer.cells, row)

    updated_line =
      erase_chars_in_line(line, col, count, buffer.width, buffer.default_style)

    cells = List.replace_at(buffer.cells, row, updated_line)
    %{buffer | cells: cells}
  end

  defp erase_chars_in_line(line, col, count, width, default_style) do
    {left, _} = Enum.split(line, col)
    right = Enum.slice(line, col + count, width - (col + count))

    new_line = left ++ right
    padding_needed = max(0, width - length(new_line))

    (new_line ++ List.duplicate(Cell.new(" ", default_style), padding_needed))
    |> Enum.take(width)
  end

  def replace_chars(buffer, row, col, string, style \\ nil) do
    replace_chars_if_valid_params(buffer, row, col, string, style)
  end

  defp valid_replace_params?(buffer, row, col, string) do
    is_struct(buffer) and
      is_integer(row) and is_integer(col) and is_binary(string) and
      row >= 0 and col >= 0 and
      row < buffer.height and col < buffer.width
  end

  defp replace_chars_in_buffer(buffer, row, col, string, style) do
    line = Enum.at(buffer.cells, row)
    updated_line = replace_chars_in_line(line, col, string, style, buffer.width)
    cells = List.replace_at(buffer.cells, row, updated_line)
    %{buffer | cells: cells}
  end

  defp replace_chars_in_line(line, col, string, style, width) do
    line_len = length(line)
    max_replace = max(0, line_len - col)
    chars = String.graphemes(string) |> Enum.take(max_replace)
    rep_len = length(chars)

    {left, right} = split_line_for_replacement(line, col, rep_len, line_len)
    rep_cells = create_replacement_cells(line, col, chars, style)

    new_line = left ++ rep_cells ++ right
    pad_or_truncate_line(new_line, width)
  end

  defp split_line_for_replacement(line, col, rep_len, line_len) do
    {left, _} = Enum.split(line, col)

    right =
      get_right_part_after_replacement(line, col, rep_len, line_len)

    {left, right}
  end

  defp create_replacement_cells(line, col, chars, style) do
    Enum.with_index(chars)
    |> Enum.map(fn {c, i} ->
      orig_cell = Enum.at(line, col + i)
      update_cell_with_style(orig_cell, c, style)
    end)
  end

  defp update_cell_with_style(orig_cell, char, style) do
    case style do
      nil -> %{orig_cell | char: char, dirty: true}
      s -> %{orig_cell | char: char, style: s, dirty: true}
    end
  end

  ## Helper functions for refactored if statements

  defp insert_chars_if_valid(buffer, row, col, count) do
    case valid_insert_params?(buffer, row, col, count) and
           can_insert_at_position?(buffer, row, col, count) do
      true -> insert_characters(buffer, row, col, count, buffer.default_style)
      false -> buffer
    end
  end

  defp insert_chars_in_bounds(buffer, row, col, _count, _default_style)
       when row >= buffer.height or col >= buffer.width do
    buffer
  end

  defp insert_chars_in_bounds(buffer, row, col, count, default_style) do
    case buffer.cells do
      nil ->
        # Return buffer unchanged if cells is nil
        buffer

      cells ->
        new_cells =
          List.replace_at(
            cells,
            row,
            insert_into_line(Enum.at(cells, row), col, count, default_style)
          )

        %{buffer | cells: new_cells}
    end
  end

  defp delete_chars_in_bounds(buffer, row, col, _count, _default_style)
       when row >= buffer.height or col >= buffer.width do
    buffer
  end

  defp delete_chars_in_bounds(buffer, row, col, count, default_style) do
    case buffer.cells do
      nil ->
        # Return buffer unchanged if cells is nil
        buffer

      cells ->
        new_cells =
          List.replace_at(
            cells,
            row,
            delete_from_line(Enum.at(cells, row), col, count, default_style)
          )

        %{buffer | cells: new_cells}
    end
  end

  defp write_char_if_in_bounds(buffer, row, col, char)
       when row >= 0 and row < buffer.height and col >= 0 and col < buffer.width do
    line = Enum.at(buffer.cells, row)
    updated_line = List.replace_at(line, col, Cell.new(char))
    cells = List.replace_at(buffer.cells, row, updated_line)
    %{buffer | cells: cells}
  end

  defp write_char_if_in_bounds(buffer, _row, _col, _char), do: buffer

  defp write_string_if_valid_position(buffer, row, col, _string)
       when row < 0 or row >= buffer.height or col < 0 or col >= buffer.width do
    buffer
  end

  defp write_string_if_valid_position(buffer, row, col, string) do
    line = Enum.at(buffer.cells, row)
    chars = String.graphemes(string)

    # Only write if we have characters to write
    write_chars_if_present(buffer, line, row, col, chars)
  end

  defp write_chars_if_present(buffer, _line, _row, _col, []), do: buffer

  defp write_chars_if_present(buffer, line, row, col, chars) do
    updated_line =
      update_line_with_chars_wide_aware(line, col, chars, buffer.width)

    updated_line = pad_or_truncate_line(updated_line, buffer.width)
    cells = List.replace_at(buffer.cells, row, updated_line)
    %{buffer | cells: cells}
  end

  defp process_char_if_fits(line, col, char, width) do
    char_w = char_width(char)

    process_char_with_width_check(
      col < width and col + char_w <= width,
      line,
      col,
      char,
      char_w
    )
  end

  defp process_char_with_width_check(true, line, col, char, char_w) do
    updated_line =
      List.replace_at(line, col, %{Enum.at(line, col) | char: char, dirty: true})

    final_line = handle_wide_char_if_needed(updated_line, col, char, char_w)
    {final_line, col + char_w}
  end

  defp process_char_with_width_check(false, line, col, _char, _char_w),
    do: {line, col}

  defp handle_wide_char_if_needed(updated_line, col, _char, char_w)
       when char_w > 1 do
    List.replace_at(updated_line, col + 1, %{
      Enum.at(updated_line, col + 1)
      | wide_placeholder: true,
        dirty: true
    })
  end

  defp handle_wide_char_if_needed(updated_line, _col, _char, _char_w),
    do: updated_line

  defp replace_char_if_in_width(acc_line, pos, char, width) when pos < width do
    List.replace_at(acc_line, pos, Cell.new(char))
  end

  defp replace_char_if_in_width(acc_line, _pos, _char, _width), do: acc_line

  defp replace_chars_if_valid_params(buffer, row, col, string, style) do
    case valid_replace_params?(buffer, row, col, string) do
      true ->
        chars = String.graphemes(string)
        max_replace = max(0, buffer.width - col)
        truncated_chars = Enum.take(chars, max_replace)

        replace_truncated_chars_if_present(
          buffer,
          row,
          col,
          truncated_chars,
          style
        )

      false ->
        buffer
    end
  end

  defp replace_truncated_chars_if_present(buffer, _row, _col, [], _style),
    do: buffer

  defp replace_truncated_chars_if_present(
         buffer,
         row,
         col,
         truncated_chars,
         style
       ) do
    replace_chars_in_buffer(
      buffer,
      row,
      col,
      Enum.join(truncated_chars),
      style || buffer.default_style
    )
  end

  defp get_right_part_after_replacement(line, col, rep_len, line_len)
       when col + rep_len < line_len do
    Enum.slice(line, col + rep_len, line_len - (col + rep_len))
  end

  defp get_right_part_after_replacement(_line, _col, _rep_len, _line_len),
    do: []
end
