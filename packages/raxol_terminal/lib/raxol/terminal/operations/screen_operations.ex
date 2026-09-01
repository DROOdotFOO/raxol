defmodule Raxol.Terminal.Operations.ScreenOperations do
  @moduledoc """
  Implements screen-related operations for the terminal emulator.
  """

  alias Raxol.Terminal.Buffer.Eraser
  alias Raxol.Terminal.Buffer.LineOperations
  alias Raxol.Terminal.Cursor.Manager, as: CursorManager
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.Terminal.ScreenManager
  @type emulator :: map()

  def clear_screen(emulator) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = ScreenBuffer.clear(buffer)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def clear_line(emulator) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    # Get cursor position from the emulator's buffer cursor_position
    cursor_pos =
      case Map.get(buffer, :cursor_position) do
        {_, y} -> y
        _ -> 0
      end

    new_buffer = ScreenBuffer.clear_line(buffer, cursor_pos)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def clear_line(emulator, line) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = ScreenBuffer.clear_line(buffer, line)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def erase_line(emulator) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {_, y} = ScreenBuffer.get_cursor_position(buffer)
    new_buffer = Raxol.Terminal.ScreenBuffer.Operations.clear_line(buffer, y)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def erase_line(emulator, mode) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {_, y} = ScreenBuffer.get_cursor_position(buffer)
    new_buffer = ScreenBuffer.erase_line(buffer, y, mode)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def erase_in_line(emulator, _opts) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {x, y} = CursorManager.get_position(emulator.cursor)
    updated_buffer = ScreenBuffer.set_cursor_position(buffer, x, y)
    # Erase from cursor to end of line
    new_buffer =
      Raxol.Terminal.ScreenBuffer.Operations.clear_to_end_of_line(updated_buffer)

    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def erase_from_cursor_to_end(emulator) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = Eraser.erase_from_cursor_to_end(buffer)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def erase_from_start_to_cursor(emulator) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {x, y} = CursorManager.get_position(emulator.cursor)

    # Update the buffer's cursor position before erasing
    buffer_with_cursor = ScreenBuffer.set_cursor_position(buffer, x, y)
    new_buffer = Eraser.erase_from_start_to_cursor(buffer_with_cursor)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def erase_chars(emulator, count) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {x, y} = CursorManager.get_position(emulator.cursor)
    # Update the buffer's cursor position before erasing
    buffer_with_cursor = ScreenBuffer.set_cursor_position(buffer, x, y)

    new_buffer =
      Raxol.Terminal.ScreenBuffer.Operations.erase_chars(
        buffer_with_cursor,
        count
      )

    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def delete_chars(emulator, count) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {x, y} = Raxol.Terminal.Emulator.get_cursor_position(emulator)

    # Update the buffer's cursor position before deleting
    buffer_with_cursor = ScreenBuffer.set_cursor_position(buffer, x, y)
    new_buffer = LineOperations.delete_chars(buffer_with_cursor, count)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def insert_chars(emulator, count) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {x, y} = Raxol.Terminal.Emulator.get_cursor_position(emulator)

    # Update the buffer's cursor position before inserting
    buffer_with_cursor = ScreenBuffer.set_cursor_position(buffer, x, y)
    new_buffer = LineOperations.insert_chars(buffer_with_cursor, count)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def delete_lines(emulator, count) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = LineOperations.delete_lines(buffer, count)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def insert_lines(emulator, count) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = LineOperations.insert_lines(buffer, count)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def prepend_lines(emulator, count) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = LineOperations.prepend_lines(buffer, count)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def write_string(emulator, x, y, string, style) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = ScreenManager.write_string(buffer, x, y, string, style)
    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  def get_content(emulator) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    ScreenBuffer.get_content(buffer)
  end

  def get_line(emulator, line) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    cells = ScreenBuffer.get_line(buffer, line)
    Enum.map_join(cells, "", fn cell -> cell.char end)
  end

  def set_cursor_position(emulator, x, y) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    new_buffer = ScreenBuffer.set_cursor_position(buffer, x, y)

    new_cursor =
      case emulator.cursor do
        map when is_map(map) ->
          %{map | position: {x, y}}

        other ->
          other
      end

    new_emulator = %{emulator | cursor: new_cursor}
    ScreenManager.update_active_buffer(new_emulator, new_buffer)
  end

  def get_cursor_position(emulator) do
    Raxol.Terminal.Emulator.get_cursor_position(emulator)
  end

  # Functions expected by tests
  @doc """
  Erases the entire display (1-arity version).
  """
  def erase_display(emulator) do
    erase_display(emulator, 0)
  end

  @doc """
  Erases the display based on the specified mode.
  """
  @spec erase_display(emulator(), integer()) :: emulator()
  def erase_display(emulator, mode) do
    buffer = ScreenManager.get_screen_buffer(emulator)

    new_buffer =
      case mode do
        0 ->
          Raxol.Terminal.ScreenBuffer.Operations.clear_to_end_of_screen(buffer)

        1 ->
          Raxol.Terminal.ScreenBuffer.Operations.clear_to_beginning_of_screen(buffer)

        2 ->
          Raxol.Terminal.ScreenBuffer.Core.clear(buffer)

        _ ->
          Raxol.Terminal.ScreenBuffer.Operations.clear_to_end_of_screen(buffer)
      end

    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  @doc """
  Erases from cursor to end of line (1-arity version).
  """
  def erase_in_line(emulator) do
    erase_in_line(emulator, %{})
  end

  @doc """
  Erases in display based on the specified mode.
  """
  @spec erase_in_display(emulator(), integer()) :: emulator()
  def erase_in_display(emulator, mode) do
    buffer = ScreenManager.get_screen_buffer(emulator)
    {x, y} = Raxol.Terminal.Emulator.get_cursor_position(emulator)

    # Update the buffer's cursor position before erasing
    # Note: emulator returns {col, row} but buffer expects {x, y}
    buffer_with_cursor = ScreenBuffer.set_cursor_position(buffer, x, y)

    new_buffer =
      case mode do
        0 ->
          Raxol.Terminal.ScreenBuffer.Operations.clear_to_end_of_screen(buffer_with_cursor)

        1 ->
          Raxol.Terminal.ScreenBuffer.Operations.clear_to_beginning_of_screen(buffer_with_cursor)

        2 ->
          Raxol.Terminal.ScreenBuffer.Core.clear(buffer_with_cursor)

        _ ->
          Raxol.Terminal.ScreenBuffer.Operations.clear_to_end_of_screen(buffer_with_cursor)
      end

    ScreenManager.update_active_buffer(emulator, new_buffer)
  end

  @doc """
  Erases from cursor to end of display (1-arity version).
  """
  def erase_in_display(emulator) do
    erase_in_display(emulator, 0)
  end
end
