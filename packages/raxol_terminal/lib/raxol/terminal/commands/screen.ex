defmodule Raxol.Terminal.Commands.Screen do
  @moduledoc """
  Handles screen manipulation commands in the terminal.

  This module provides functions for clearing the screen or parts of it,
  inserting and deleting lines, and other screen manipulation operations.
  """

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.Terminal.ScreenBuffer.Operations

  # Use map() to accept any emulator-like struct
  @type emulator :: map()

  def clear_screen(emulator, mode) do
    buffer = Emulator.get_screen_buffer(emulator)
    {y, x} = Emulator.get_cursor_position(emulator)
    # Log.info("[DEBUG clear_screen] mode=#{mode}, cursor=(#{x},#{y})")
    scroll_region = ScreenBuffer.get_scroll_region(buffer)

    {top, bottom} =
      case scroll_region do
        nil -> {0, buffer.height - 1}
        {t, b} -> {t, b}
      end

    new_buffer =
      case mode do
        0 -> ScreenBuffer.erase_from_cursor_to_end(buffer, x, y, top, bottom)
        1 -> ScreenBuffer.erase_from_start_to_cursor(buffer, x, y, top, bottom)
        2 -> ScreenBuffer.erase_all(buffer)
        # Clear entire screen and scrollback
        3 -> ScreenBuffer.erase_all(buffer)
      end

    emulator = Emulator.update_active_buffer(emulator, new_buffer)

    # For mode 3, also clear the scrollback buffer
    case mode do
      3 -> Emulator.clear_scrollback(emulator)
      _ -> emulator
    end
  end

  def clear_line(emulator, mode) do
    buffer = Emulator.get_screen_buffer(emulator)

    {cursor_y, cursor_x} = Emulator.get_cursor_position(emulator)

    Raxol.Core.Runtime.Log.debug(
      "[Screen.clear_line] CALLED with mode: #{mode}, cursor_x: #{cursor_x}, cursor_y from emulator: #{cursor_y}"
    )

    Raxol.Core.Runtime.Log.debug("[Screen.clear_line] Buffer type: #{inspect(buffer.__struct__)}")

    _default_style = emulator.style

    # Update buffer cursor position to match emulator cursor
    buffer_with_cursor = %{buffer | cursor_position: {cursor_x, cursor_y}}

    Raxol.Core.Runtime.Log.debug(
      "[Screen.clear_line] Buffer cursor set to: #{inspect(buffer_with_cursor.cursor_position)}"
    )

    new_buffer =
      case mode do
        # Clear from cursor to end of line
        0 ->
          result = Operations.clear_to_end_of_line(buffer_with_cursor)

          Raxol.Core.Runtime.Log.debug("[Screen.clear_line] After clear_to_end_of_line operation")

          result

        # Clear from beginning of line to cursor
        1 ->
          Operations.clear_to_beginning_of_line(buffer_with_cursor)

        # Clear entire line
        2 ->
          Operations.clear_line(buffer_with_cursor, cursor_y)

        # Unknown mode, do nothing
        _ ->
          Raxol.Core.Runtime.Log.warning_with_context(
            "Unknown clear line mode: #{mode}",
            %{}
          )

          buffer
      end

    Emulator.update_active_buffer(emulator, new_buffer)
  end

  def insert_lines(emulator, count) do
    {cursor_y, _} = Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)
    buffer = Emulator.get_screen_buffer(emulator)

    # Apply scroll region constraints if active
    {top, bottom} =
      case emulator.scroll_region do
        nil -> {0, ScreenBuffer.get_height(buffer) - 1}
        region -> region
      end

    # Only insert if cursor is within the scroll region
    case cursor_y >= top && cursor_y <= bottom do
      true ->
        # Insert count lines at cursor_y, passing the scroll region
        new_buffer =
          ScreenBuffer.insert_lines(
            buffer,
            cursor_y,
            count,
            emulator.style,
            {top, bottom}
          )

        Emulator.update_active_buffer(emulator, new_buffer)

      false ->
        # Outside scroll region, do nothing
        emulator
    end
  end

  def delete_lines(emulator, count) do
    {cursor_y, _} = Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)
    buffer = Emulator.get_screen_buffer(emulator)

    # Apply scroll region constraints if active
    {top, bottom} =
      case emulator.scroll_region do
        nil -> {0, ScreenBuffer.get_height(buffer) - 1}
        region -> region
      end

    # Only delete if cursor is within the scroll region
    case cursor_y >= top && cursor_y <= bottom do
      true ->
        # Delete count lines at cursor_y, passing the scroll region
        new_buffer =
          ScreenBuffer.delete_lines(
            buffer,
            cursor_y,
            count,
            emulator.style,
            {top, bottom}
          )

        Emulator.update_active_buffer(emulator, new_buffer)

      false ->
        # Outside scroll region, do nothing
        emulator
    end
  end

  def scroll_up_screen_command(emulator, count)
      when is_integer(count) and count > 0 do
    Raxol.Core.Runtime.Log.debug("[Screen.scroll_up_screen_command] CALLED with count: #{count}")

    scrollback = Emulator.get_scrollback(emulator)
    buffer = emulator.main_screen_buffer
    {to_restore, _remaining_scrollback} = Enum.split(scrollback, count)

    # Move lines from scrollback to the top of the screen buffer
    new_buffer = ScreenBuffer.prepend_lines(buffer, Enum.reverse(to_restore))

    # Update the emulator with the new buffer and remaining scrollback
    emulator = Emulator.update_active_buffer(emulator, new_buffer)

    # Note: The scrollback is managed by the Buffer.Manager process,
    # so we don't need to update it directly here
    emulator
  end

  def scroll_down(emulator, count) when is_integer(count) and count > 0 do
    Raxol.Core.Runtime.Log.debug("[Screen.scroll_down] CALLED with count: #{count}")

    buffer = Emulator.get_screen_buffer(emulator)
    {top, bottom} = effective_scroll_region(emulator, buffer)

    # Use ScreenBuffer.scroll_down since we have a ScreenBuffer struct
    new_buffer = ScreenBuffer.scroll_down(buffer, top, bottom, count)
    Emulator.update_active_buffer(emulator, new_buffer)
  end

  def scroll_up(emulator, lines) when is_integer(lines) and lines > 0 do
    Raxol.Core.Runtime.Log.debug("[Screen.scroll_up] CALLED with lines: #{lines}")

    buffer = Emulator.get_screen_buffer(emulator)
    {top, bottom} = effective_scroll_region(emulator, buffer)

    # Use ScreenBuffer.scroll_up since we have a ScreenBuffer struct
    {new_buffer, scrolled_lines} = ScreenBuffer.scroll_up(buffer, top, bottom, lines)

    emulator
    |> Emulator.update_active_buffer(new_buffer)
    |> Raxol.Terminal.Emulator.BufferOperations.feed_scrollback_from_region_scroll(
      top,
      scrolled_lines
    )
  end

  # DECSTBM (via Emulator.CommandHandler / the CSI handlers) records the
  # scroll region on `emulator.scroll_region`; the ScreenBuffer's own
  # `scroll_region` field is a separate store that the byte path never
  # sets. The emulator-level region wins when present -- the same
  # precedence `insert_lines/2` and `delete_lines/2` above already use --
  # falling back to the buffer's boundaries (which default to full screen).
  defp effective_scroll_region(emulator, buffer) do
    height = ScreenBuffer.get_height(buffer)

    case Map.get(emulator, :scroll_region) do
      {top, bottom}
      when is_integer(top) and is_integer(bottom) and top >= 0 and
             top <= bottom ->
        {top, min(bottom, height - 1)}

      _ ->
        ScreenBuffer.get_scroll_region_boundaries(buffer)
    end
  end
end
