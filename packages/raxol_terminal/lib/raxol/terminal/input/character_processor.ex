defmodule Raxol.Terminal.Input.CharacterProcessor do
  @moduledoc """
  Handles character processing, translation, and writing to the terminal buffer.
  """

  alias Raxol.Terminal.ANSI.CharacterSets
  alias Raxol.Terminal.{CharacterHandling, Emulator, ScreenBuffer}
  alias Raxol.Terminal.ModeManager
  alias Raxol.Terminal.ScreenBuffer.Operations

  @doc """
  Processes a single character codepoint.
  Delegates to C0 handlers or printable character handlers.
  """
  def process_character(emulator, char_codepoint)
      when (char_codepoint >= 0 and char_codepoint <= 31) or
             char_codepoint == 127 do
    Raxol.Terminal.ControlCodes.handle_c0(emulator, char_codepoint)
  end

  def process_character(emulator, char_codepoint) do
    process_printable_character(emulator, char_codepoint)
  end

  def process_printable_character(emulator, char_codepoint) do
    buffer_width = get_buffer_width(emulator)
    buffer_height = get_buffer_height(emulator)

    {_initial_cursor_row, _initial_cursor_col} =
      get_cursor_position_safe(emulator.cursor)

    _char_str = <<char_codepoint::utf8>>

    {_translated_char, new_charset_state} =
      CharacterSets.translate_char(char_codepoint, emulator.charset_state)

    {_write_col, _write_row, next_cursor_col, next_cursor_row, next_last_col_exceeded} =
      calculate_positions(emulator, buffer_width, char_codepoint)

    # Check if autowrap would cause an out-of-bounds write
    auto_wrap_mode = ModeManager.mode_enabled?(emulator.mode_manager, :decawm)

    # Get the original write_row before adjustment to detect autowrap
    {_original_write_col, original_write_row, _, _, _} =
      calculate_write_and_cursor_position(
        # col
        get_cursor_position_safe(emulator.cursor) |> elem(1),
        # row
        get_cursor_position_safe(emulator.cursor) |> elem(0),
        buffer_width,
        buffer_height,
        CharacterHandling.get_char_width(char_codepoint),
        emulator.last_col_exceeded,
        auto_wrap_mode
      )

    autowrap_out_of_bounds =
      original_write_row >= buffer_height and auto_wrap_mode and
        emulator.last_col_exceeded

    # If autowrap will cause a scroll, skip the initial write and handle after scroll
    handle_autowrap_scroll(
      autowrap_out_of_bounds and original_write_row >= buffer_height,
      emulator,
      next_cursor_col,
      next_cursor_row,
      next_last_col_exceeded,
      new_charset_state,
      char_codepoint,
      buffer_height
    )
    |> case do
      :continue ->
        # Normal path: write the character, update state, and handle scroll if needed
        emulator_after_write =
          write_character(
            emulator,
            char_codepoint,
            emulator.style
          )

        updated_emulator =
          update_emulator_state(
            emulator_after_write,
            next_cursor_col,
            next_cursor_row,
            next_last_col_exceeded,
            new_charset_state
          )

        handle_scroll_after_write(
          original_write_row >= buffer_height,
          autowrap_out_of_bounds,
          updated_emulator,
          char_codepoint,
          emulator,
          buffer_height
        )

      %Raxol.Terminal.Emulator{} = processed_emulator ->
        # Autowrap scroll already handled, return the processed emulator
        processed_emulator
    end
  end

  defp get_buffer_width(emulator) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    ScreenBuffer.get_width(active_buffer)
  end

  defp get_buffer_height(emulator) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    ScreenBuffer.get_height(active_buffer)
  end

  defp calculate_positions(emulator, buffer_width, char_codepoint) do
    char_width = CharacterHandling.get_char_width(char_codepoint)
    auto_wrap_mode = ModeManager.mode_enabled?(emulator.mode_manager, :decawm)
    buffer_height = get_buffer_height(emulator)

    {current_cursor_row, current_cursor_col} =
      get_cursor_position_safe(emulator.cursor)

    {write_col, write_row, next_cursor_col, next_cursor_row, next_last_col_exceeded} =
      calculate_write_and_cursor_position(
        current_cursor_col,
        current_cursor_row,
        buffer_width,
        buffer_height,
        char_width,
        emulator.last_col_exceeded,
        auto_wrap_mode
      )

    # Check if autowrap would cause an out-of-bounds write
    # If so, adjust the positions to stay within bounds
    {adjusted_write_col, adjusted_write_row, adjusted_next_cursor_col, adjusted_next_cursor_row,
     adjusted_next_last_col_exceeded} =
      adjust_positions_for_autowrap(
        write_row >= buffer_height and auto_wrap_mode and
          emulator.last_col_exceeded,
        {current_cursor_col, current_cursor_row, next_cursor_col, next_cursor_row,
         next_last_col_exceeded},
        {write_col, write_row, next_cursor_col, next_cursor_row, next_last_col_exceeded}
      )

    # No per-character debug log here (removed): this function runs once
    # per PRINTABLE CHARACTER, and a `Log.debug` in that loop eagerly
    # interpolates its message on every call regardless of level, then
    # (under the test env's `level: :debug` + global `capture_log`)
    # funnels every character of every emulator replay through ExUnit's
    # single CaptureServer -- serializing the whole async suite and
    # pushing replay-oracle tests from seconds into minutes. A
    # per-character cursor trace is reconstructible from the input bytes
    # whenever it is actually needed; it earns neither the production
    # interpolation cost nor the test-suite serialization.

    {adjusted_write_col, adjusted_write_row, adjusted_next_cursor_col, adjusted_next_cursor_row,
     adjusted_next_last_col_exceeded}
  end

  defp get_cursor_position_safe(cursor) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           case cursor do
             cursor when is_pid(cursor) ->
               position = Raxol.Terminal.Cursor.Manager.get_position(cursor)
               position

             cursor when is_map(cursor) ->
               Raxol.Terminal.Cursor.Manager.get_position(cursor)

             _ ->
               log_cursor_debug("unknown cursor type", cursor)
               {0, 0}
           end
         end) do
      {:ok, result} -> result
      {:error, _} -> {0, 0}
    end
  end

  defp log_cursor_debug(cursor_type, cursor) do
    Raxol.Core.Runtime.Log.debug(
      "[calculate_positions] Getting position from #{cursor_type}: #{inspect(cursor)}"
    )
  end

  defp write_character(emulator, char_codepoint, opts) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           {translated_char, _new_charset_state} =
             CharacterSets.translate_char(
               char_codepoint,
               emulator.charset_state
             )

           _active_charset_module =
             CharacterSets.get_active_charset(emulator.charset_state)

           translated_char_str = <<translated_char::utf8>>

           validate_translated_char(translated_char_str)

           buffer_height = get_buffer_height(emulator)

           {write_col, write_row, _next_cursor_col, _next_cursor_row, _next_last_col_exceeded} =
             calculate_positions(
               emulator,
               get_buffer_width(emulator),
               char_codepoint
             )

           # Check if autowrap would cause an out-of-bounds write
           _auto_wrap_mode =
             ModeManager.mode_enabled?(emulator.mode_manager, :decawm)

           write_character_if_in_bounds(
             write_row < buffer_height,
             emulator,
             write_col,
             write_row,
             translated_char_str,
             opts,
             buffer_height
           )
         end) do
      {:ok, result} ->
        result

      {:error, exception} ->
        # ERROR in write_character/3: #{inspect(exception)}
        Raxol.Core.Runtime.Log.error("write_character failed: #{inspect(exception)}")

        emulator
    end
  end

  defp update_emulator_state(
         emulator,
         next_cursor_col,
         next_cursor_row,
         next_last_col_exceeded,
         new_charset_state
       ) do
    # Update cursor position by calling the cursor manager
    updated_emulator =
      case emulator.cursor do
        cursor when is_pid(cursor) ->
          # For PID cursors, just call set_position - the PID manages its own state
          Raxol.Terminal.Cursor.Manager.set_position(
            cursor,
            {next_cursor_row, next_cursor_col}
          )

          # Don't update the emulator's cursor field - the PID is the cursor
          emulator

        cursor when is_map(cursor) ->
          updated_cursor =
            Raxol.Terminal.Cursor.Manager.set_position(
              cursor,
              {next_cursor_row, next_cursor_col}
            )

          %{emulator | cursor: updated_cursor}

        _ ->
          emulator
      end

    %{
      updated_emulator
      | last_col_exceeded: next_last_col_exceeded,
        charset_state: new_charset_state
    }
  end

  @doc false
  def calculate_write_and_cursor_position(
        current_x,
        current_y,
        buffer_width,
        buffer_height,
        char_width,
        last_col_exceeded,
        auto_wrap_mode
      ) do
    do_calculate_position(
      {current_x, current_y},
      buffer_width,
      buffer_height,
      char_width,
      last_col_exceeded,
      auto_wrap_mode
    )
  end

  # Last column exceeded with auto-wrap
  defp do_calculate_position(
         {current_x, current_y},
         buffer_width,
         buffer_height,
         char_width,
         true,
         true
       ) do
    # For autowrap, stay at current position for writing
    # and advance cursor to next line, column 0
    # But clamp to buffer height
    write_y = min(current_y + 1, buffer_height - 1)
    {current_x, current_y, 0, write_y, char_width >= buffer_width}
  end

  # Last column exceeded without auto-wrap
  defp do_calculate_position(
         {_current_x, current_y},
         buffer_width,
         _buffer_height,
         _char_width,
         true,
         false
       ) do
    write_x = buffer_width - 1
    write_y = current_y
    next_cursor_x = buffer_width - 1
    next_cursor_y = current_y
    next_flag = true
    {write_x, write_y, next_cursor_x, next_cursor_y, next_flag}
  end

  # Current position + char width fits within buffer
  defp do_calculate_position(
         {current_x, current_y},
         buffer_width,
         _buffer_height,
         char_width,
         _last_col_exceeded,
         _auto_wrap_mode
       )
       when current_x + char_width < buffer_width do
    {current_x, current_y, current_x + char_width, current_y, false}
  end

  # Default case - at or beyond buffer edge
  defp do_calculate_position(
         {current_x, current_y},
         buffer_width,
         buffer_height,
         _char_width,
         _last_col_exceeded,
         auto_wrap_mode
       ) do
    case auto_wrap_mode do
      true ->
        # Auto-wrap: write at buffer edge and move cursor to next line
        # But clamp to buffer height
        write_x = buffer_width - 1
        write_y = current_y
        next_cursor_x = 0
        next_cursor_y = min(current_y + 1, buffer_height - 1)
        {write_x, write_y, next_cursor_x, next_cursor_y, false}

      false ->
        # No auto-wrap: stay at buffer edge
        {current_x, current_y, buffer_width - 1, current_y, true}
    end
  end

  # Helper functions for if statement elimination

  defp handle_autowrap_scroll(
         false,
         _emulator,
         _next_cursor_col,
         _next_cursor_row,
         _next_last_col_exceeded,
         _new_charset_state,
         _char_codepoint,
         _buffer_height
       ) do
    :continue
  end

  defp handle_autowrap_scroll(
         true,
         emulator,
         next_cursor_col,
         next_cursor_row,
         next_last_col_exceeded,
         new_charset_state,
         char_codepoint,
         buffer_height
       ) do
    updated_emulator =
      update_emulator_state(
        emulator,
        next_cursor_col,
        next_cursor_row,
        next_last_col_exceeded,
        new_charset_state
      )

    # Only scroll if the cursor is actually at the bottom of the buffer
    {current_cursor_row, _current_cursor_col} =
      get_cursor_position_safe(updated_emulator.cursor)

    handle_cursor_at_bottom(
      current_cursor_row >= buffer_height - 1,
      updated_emulator,
      char_codepoint,
      emulator,
      buffer_height
    )
  end

  defp handle_cursor_at_bottom(
         false,
         updated_emulator,
         _char_codepoint,
         _emulator,
         _buffer_height
       ) do
    updated_emulator
  end

  defp handle_cursor_at_bottom(
         true,
         updated_emulator,
         char_codepoint,
         emulator,
         buffer_height
       ) do
    scrolled_emulator = Emulator.maybe_scroll(updated_emulator)
    new_cursor_row = buffer_height - 1

    updated_cursor =
      update_cursor_position(scrolled_emulator.cursor, new_cursor_row)

    scrolled_emulator = %{scrolled_emulator | cursor: updated_cursor}

    handle_character_after_scroll(char_codepoint, scrolled_emulator, emulator)
  end

  defp handle_character_after_scroll(10, scrolled_emulator, _emulator) do
    scrolled_emulator
  end

  defp handle_character_after_scroll(
         char_codepoint,
         scrolled_emulator,
         emulator
       ) do
    {current_cursor_row, current_cursor_col} =
      get_cursor_position_safe(scrolled_emulator.cursor)

    char_str = <<char_codepoint::utf8>>
    buffer_for_write = Emulator.get_screen_buffer(scrolled_emulator)

    buffer_after_write =
      Operations.write_char(
        buffer_for_write,
        current_cursor_col,
        current_cursor_row,
        char_str,
        emulator.style
      )

    Emulator.update_active_buffer(scrolled_emulator, buffer_after_write)
  end

  defp update_cursor_position(cursor, new_cursor_row) when is_pid(cursor) do
    Raxol.Terminal.Cursor.Manager.set_position(cursor, {new_cursor_row, 0})
    cursor
  end

  defp update_cursor_position(cursor, new_cursor_row) when is_map(cursor) do
    Raxol.Terminal.Cursor.Manager.set_position(cursor, {new_cursor_row, 0})
  end

  defp update_cursor_position(cursor, _new_cursor_row), do: cursor

  defp handle_scroll_after_write(
         false,
         _autowrap_out_of_bounds,
         updated_emulator,
         _char_codepoint,
         _emulator,
         _buffer_height
       ) do
    updated_emulator
  end

  defp handle_scroll_after_write(
         true,
         autowrap_out_of_bounds,
         updated_emulator,
         char_codepoint,
         emulator,
         buffer_height
       ) do
    handle_autowrap_after_write(
      autowrap_out_of_bounds,
      updated_emulator,
      char_codepoint,
      emulator,
      buffer_height
    )
  end

  defp handle_autowrap_after_write(
         false,
         updated_emulator,
         _char_codepoint,
         _emulator,
         _buffer_height
       ) do
    updated_emulator
  end

  defp handle_autowrap_after_write(
         true,
         updated_emulator,
         char_codepoint,
         emulator,
         buffer_height
       ) do
    {current_cursor_row, _current_cursor_col} =
      get_cursor_position_safe(updated_emulator.cursor)

    handle_cursor_scroll_after_write(
      current_cursor_row >= buffer_height - 1,
      updated_emulator,
      char_codepoint,
      emulator,
      buffer_height
    )
  end

  defp handle_cursor_scroll_after_write(
         false,
         updated_emulator,
         _char_codepoint,
         _emulator,
         _buffer_height
       ) do
    updated_emulator
  end

  defp handle_cursor_scroll_after_write(
         true,
         updated_emulator,
         char_codepoint,
         emulator,
         buffer_height
       ) do
    scrolled_emulator = Emulator.maybe_scroll(updated_emulator)
    new_cursor_row = buffer_height - 1

    updated_cursor =
      update_cursor_position(scrolled_emulator.cursor, new_cursor_row)

    scrolled_emulator = %{scrolled_emulator | cursor: updated_cursor}

    handle_character_after_scroll(char_codepoint, scrolled_emulator, emulator)
  end

  defp validate_translated_char(translated_char_str) do
    case is_binary(translated_char_str) do
      true ->
        :ok

      false ->
        Raxol.Core.Runtime.Log.error(
          "Expected translated_char to be a string, got: #{inspect(translated_char_str)}"
        )
    end
  end

  defp write_character_if_in_bounds(
         true,
         emulator,
         write_col,
         write_row,
         translated_char_str,
         opts,
         _buffer_height
       ) do
    buffer_for_write = Emulator.get_screen_buffer(emulator)

    buffer_after_write =
      Operations.write_char(
        buffer_for_write,
        write_col,
        write_row,
        translated_char_str,
        opts
      )

    Emulator.update_active_buffer(emulator, buffer_after_write)
  end

  defp write_character_if_in_bounds(
         false,
         emulator,
         _write_col,
         write_row,
         _translated_char_str,
         _opts,
         buffer_height
       ) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Attempted write out of bounds (row=#{write_row}, height=#{buffer_height}), handling autowrap after scroll.",
      %{}
    )

    # For autowrap that would go out of bounds, we need to write the character after scrolling
    # First, let the emulator scroll, then write the character to the new line
    emulator
  end

  defp adjust_positions_for_autowrap(
         true,
         autowrap_positions,
         _normal_positions
       ) do
    autowrap_positions
  end

  defp adjust_positions_for_autowrap(
         false,
         _autowrap_positions,
         normal_positions
       ) do
    normal_positions
  end
end
