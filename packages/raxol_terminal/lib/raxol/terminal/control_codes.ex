defmodule Raxol.Terminal.ControlCodes do
  @moduledoc """
  Handles C0 control codes and simple ESC sequences.

  Extracted from Terminal.Emulator for better organization.
  Relies on Emulator state and ScreenBuffer for actions.
  """

  alias Raxol.Terminal.ANSI.CharacterSets
  alias Raxol.Terminal.Cursor.Movement
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer
  # Removed unused alias: ModeManager

  # C0 Constants
  @nul 0
  @bel 7
  @bs 8
  @ht 9
  @lf 10
  @vt 11
  @ff 12
  @cr 13
  @so 14
  @si 15
  @can 24
  @sub 26
  @esc 27
  @del 127

  @doc """
  Handles a C0 control code (0-31) or DEL (127).
  Delegates to specific handlers based on the codepoint.
  """
  @spec handle_c0(Emulator.t(), non_neg_integer()) :: Emulator.t()
  def handle_c0(emulator, char_codepoint) do
    handler = c0_handler_for(char_codepoint)
    handler.(emulator)
  end

  defp c0_handler_for(@nul),
    do: fn emulator ->
      Raxol.Core.Runtime.Log.debug("NUL received, ignoring")
      emulator
    end

  defp c0_handler_for(@bel), do: &handle_bel/1
  defp c0_handler_for(@bs), do: &handle_bs/1
  defp c0_handler_for(@ht), do: &handle_ht/1
  defp c0_handler_for(@lf), do: &handle_lf/1
  defp c0_handler_for(@vt), do: &handle_lf/1
  defp c0_handler_for(@ff), do: &handle_lf/1
  defp c0_handler_for(@cr), do: &handle_cr/1
  defp c0_handler_for(@so), do: &handle_so/1
  defp c0_handler_for(@si), do: &handle_si/1
  defp c0_handler_for(@can), do: &handle_can/1
  defp c0_handler_for(@sub), do: &handle_sub/1

  defp c0_handler_for(@esc),
    do: fn emulator ->
      Raxol.Core.Runtime.Log.debug("ESC received unexpectedly in C0 handler, ignoring")

      emulator
    end

  defp c0_handler_for(@del),
    do: fn emulator ->
      Raxol.Core.Runtime.Log.debug("DEL received, ignoring")
      emulator
    end

  defp c0_handler_for(_),
    do: fn emulator ->
      Raxol.Core.Runtime.Log.debug("Unhandled C0 control code")
      emulator
    end

  @doc """
  Handles bell control code.
  """
  def handle_bel(emulator) do
    _ = System.cmd("tput", ["bel"])
    emulator
  end

  @doc "Handle Backspace (BS)"
  def handle_bs(%Emulator{} = emulator) do
    # Move cursor left by one, respecting margins
    # Use alias
    new_cursor = Movement.move_left(emulator.cursor, 1, 80, 24)
    %{emulator | cursor: new_cursor}
  end

  @doc """
  Handles the Horizontal Tab (HT) action.
  """
  def handle_ht(%Emulator{} = emulator) do
    # Move cursor to the next tab stop
    {current_col, _} =
      Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

    active_buffer = Emulator.get_screen_buffer(emulator)
    width = ScreenBuffer.get_width(active_buffer)
    # Placeholder: move to next multiple of 8 or end of line
    next_stop = min(width - 1, div(current_col, 8) * 8 + 8)
    # Use alias
    new_cursor = Movement.move_to_column(emulator.cursor, next_stop)
    %{emulator | cursor: new_cursor}
  end

  @doc "Handle Line Feed (LF), New Line (NL), Vertical Tab (VT)"
  def handle_lf(%Emulator{} = emulator) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    buffer_height = ScreenBuffer.get_height(active_buffer)

    # Cursor.Manager positions are {row, col} (see Cursor.Movement --
    # `position: {new_row, col}`). This destructure previously read the
    # COLUMN as the row, so the at-bottom-margin branch effectively never
    # fired and LF at the bottom never scrolled (TE amend, finding 3+8).
    {current_row, _col} =
      Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

    # LF scrolls when the cursor sits on the bottom row of the EFFECTIVE
    # scroll region (DECSTBM stores it on emulator.scroll_region; full
    # screen otherwise). A cursor below an interior region (e.g. in a
    # footer) falls through to plain downward movement, clamped at the
    # screen bottom -- no scroll, matching DECSTBM semantics.
    region_bottom =
      case emulator.scroll_region do
        {top, bottom}
        when is_integer(top) and is_integer(bottom) and top <= bottom ->
          min(bottom, buffer_height - 1)

        _ ->
          buffer_height - 1
      end

    handle_lf_cursor_movement(current_row == region_bottom, emulator)
  end

  defp move_cursor_down(emulator) do
    active_buffer = Emulator.get_screen_buffer(emulator)
    {buffer_width, buffer_height} = ScreenBuffer.get_dimensions(active_buffer)
    cursor = emulator.cursor

    # Position tuples are {row, col} -- this previously destructured them
    # swapped, feeding the ROW into the LNM column adjustment below, which
    # made every LF drift the column right by the row number (TE amend,
    # finding 3+8).
    {current_row, current_col} =
      Raxol.Terminal.Cursor.Manager.get_position(cursor)

    last_row = buffer_height - 1

    moved_cursor =
      move_cursor_down_if_needed(
        cursor,
        current_row,
        last_row,
        buffer_width,
        buffer_height
      )

    # Check LNM mode to determine if we should move to column 0
    line_feed_mode =
      Raxol.Terminal.ModeManager.mode_enabled?(
        emulator.mode_manager,
        :line_feed_mode
      )

    final_cursor =
      apply_line_feed_cursor_adjustment(
        moved_cursor,
        cursor,
        current_col,
        line_feed_mode
      )

    log_cursor_position(final_cursor)
    %{emulator | cursor: final_cursor}
  end

  defp move_cursor_down_if_needed(
         cursor,
         _current_row,
         _last_row,
         buffer_width,
         buffer_height
       ) do
    # Always move cursor down, even when at last row, to trigger scrolling
    case cursor do
      cursor when is_pid(cursor) ->
        GenServer.call(cursor, {:move_down, 1, buffer_width, buffer_height})

      cursor when is_map(cursor) ->
        Raxol.Terminal.Cursor.Manager.move_down(
          cursor,
          1,
          buffer_width,
          buffer_height
        )

      _ ->
        cursor
    end
  end

  defp log_cursor_position(cursor) do
    Raxol.Core.Runtime.Log.debug(
      "[move_cursor_down] Final: cursor=#{inspect(Raxol.Terminal.Cursor.Manager.get_position(cursor))}"
    )
  end

  defp reset_last_col_exceeded_after_scroll(emulator) do
    # After a scroll, reset the last_col_exceeded flag so that the next character
    # is written at the current row (not the next row)
    %{emulator | last_col_exceeded: false}
  end

  @doc "Handle Carriage Return (CR)"
  def handle_cr(%Emulator{} = emulator) do
    Raxol.Core.Runtime.Log.debug(
      "[handle_cr] Input: cursor=#{inspect(Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor))}, last_exceeded=#{emulator.last_col_exceeded}"
    )

    # 1. Check for pending wrap
    emulator_after_pending_wrap =
      handle_pending_wrap(emulator.last_col_exceeded, emulator)

    # 2. Perform CR logic on potentially updated state
    Raxol.Core.Runtime.Log.debug("[handle_cr] Moving cursor to column 0")
    # Keep the current row (position tuples are {row, col} and move_to is
    # (cursor, row, col) -- this previously destructured the COLUMN as the
    # row and passed the arguments swapped, so every CR teleported the
    # cursor to row 0; TE amend, finding 3+8) and move to column 0. Read
    # the row AFTER the pending wrap so CR lands on the wrapped row.
    {current_row, _col} =
      Raxol.Terminal.Cursor.Manager.get_position(emulator_after_pending_wrap.cursor)

    final_cursor =
      Raxol.Terminal.Cursor.Manager.move_to(
        emulator_after_pending_wrap.cursor,
        current_row,
        0
      )

    Raxol.Core.Runtime.Log.debug(
      "[handle_cr] Final cursor: #{inspect(Raxol.Terminal.Cursor.Manager.get_position(final_cursor))}"
    )

    %{emulator_after_pending_wrap | cursor: final_cursor}
  end

  @spec handle_so(Emulator.t()) :: Emulator.t()
  def handle_so(emulator) do
    # SO: Shift Out. Invoke G1 character set.
    %{
      emulator
      | charset_state: CharacterSets.invoke_designator(emulator.charset_state, :g1)
    }
  end

  @spec handle_si(Emulator.t()) :: Emulator.t()
  def handle_si(emulator) do
    # SI: Shift In. Invoke G0 character set.
    %{
      emulator
      | charset_state: CharacterSets.invoke_designator(emulator.charset_state, :g0)
    }
  end

  @spec handle_can(Emulator.t()) :: Emulator.t()
  def handle_can(emulator) do
    # CAN: Cancel. Parser should handle this within sequences.
    # If it reaches here, it was outside a sequence.
    Raxol.Core.Runtime.Log.debug("CAN received outside escape sequence, ignoring")

    emulator
  end

  @doc """
  Handles substitute character control code.
  """
  def handle_sub(emulator) do
    # Print a substitute character (typically displayed as ^Z)
    _ = System.cmd("echo", ["-n", "^Z"])
    emulator
  end

  @dialyzer {:nowarn_function, handle_ris: 1}
  @spec handle_ris(Emulator.t()) :: Emulator.t()
  # ESC c - Reset to Initial State
  def handle_ris(emulator) do
    Raxol.Core.Runtime.Log.info("RIS (Reset to Initial State) received")
    # Re-initialize most state components, keeping buffer dimensions
    active_buffer = Emulator.get_screen_buffer(emulator)
    width = ScreenBuffer.get_width(active_buffer)
    height = ScreenBuffer.get_height(active_buffer)
    scrollback_limit = active_buffer.scrollback_limit

    # Create a completely new default state, preserving only dimensions/limits
    Emulator.new(width, height,
      scrollback: scrollback_limit,
      memorylimit: emulator.memory_limit
    )
  end

  @spec handle_ind(Emulator.t()) :: Emulator.t()
  # ESC D - Index
  def handle_ind(emulator) do
    # Move cursor down one line, scroll if at bottom margin. Same as LF.
    handle_lf(emulator)
  end

  @spec handle_nel(Emulator.t()) :: Emulator.t()
  # ESC E - Next Line
  def handle_nel(emulator) do
    # Move cursor to start of next line. Like CR + LF.
    emulator
    # Move down/scroll
    |> handle_lf()
    # Move to col 0
    |> handle_cr()
  end

  @dialyzer {:nowarn_function, handle_hts: 1}
  @spec handle_hts(Emulator.t()) :: Emulator.t()
  # ESC H - Horizontal Tabulation Set
  def handle_hts(emulator) do
    # Set a tab stop at the current cursor column.
    {x, _y} = Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)
    new_tab_stops = MapSet.put(emulator.tab_stops, x)
    %{emulator | tab_stops: new_tab_stops}
  end

  @doc "Handle Reverse Index (RI) - ESC M"
  def handle_ri(%Emulator{} = emulator) do
    # Move cursor up one line. If at the top margin, scroll down.
    {_col, row} = Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)
    active_buffer = Emulator.get_screen_buffer(emulator)

    {top_margin, _} =
      case emulator.scroll_region do
        # Use scroll_region directly
        {top, bottom} -> {top, bottom}
        # Default to full height
        nil -> {0, ScreenBuffer.get_height(active_buffer) - 1}
      end

    handle_ri_cursor_movement(row == top_margin, emulator, active_buffer)
  end

  @spec handle_decsc(Emulator.t()) :: Emulator.t()
  # ESC 7 - Save Cursor State (DEC specific)
  def handle_decsc(emulator) do
    # Get cursor state from the PID using CursorManager
    cursor_position =
      Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

    cursor_visible =
      Raxol.Terminal.Cursor.Manager.get_visibility(emulator.cursor)

    cursor_style = Raxol.Terminal.Cursor.Manager.get_style(emulator.cursor)
    cursor_blinking = Raxol.Terminal.Cursor.Manager.get_blink(emulator.cursor)

    saved_state = %{
      cursor: %{
        position: cursor_position,
        visible: cursor_visible,
        style: cursor_style,
        blink_state: cursor_blinking
      },
      style: emulator.style,
      charset_state: emulator.charset_state,
      mode_manager: emulator.mode_manager,
      scroll_region: emulator.scroll_region,
      cursor_style: emulator.cursor_style
    }

    # Save the state to the stack
    new_stack = [saved_state | emulator.state_stack]
    %{emulator | state_stack: new_stack}
  end

  @spec handle_decrc(Emulator.t()) :: Emulator.t()
  # ESC 8 - Restore Cursor State (DEC specific)
  def handle_decrc(emulator) do
    case emulator.state_stack do
      [restored_state_data | new_stack] ->
        # Apply the restored state components
        emulator = %{
          emulator
          | state_stack: new_stack,
            style: restored_state_data.style,
            charset_state: restored_state_data.charset_state,
            mode_manager: restored_state_data.mode_manager,
            scroll_region: restored_state_data.scroll_region,
            cursor_style: Map.get(restored_state_data, :cursor_style, emulator.cursor_style)
        }

        # Restore cursor position and attributes using CursorManager
        updated_cursor =
          restore_cursor_state(restored_state_data.cursor, emulator.cursor)

        %{emulator | cursor: updated_cursor}

      [] ->
        # No saved state to restore
        emulator
    end
  end

  @escape_handlers %{
    ?7 => &Raxol.Terminal.ControlCodes.handle_decsc/1,
    ?8 => &Raxol.Terminal.ControlCodes.handle_decrc/1,
    ?c => &Raxol.Terminal.ControlCodes.handle_ris/1,
    ?D => &Raxol.Terminal.ControlCodes.handle_ind/1,
    ?E => &Raxol.Terminal.ControlCodes.handle_nel/1,
    ?H => &Raxol.Terminal.ControlCodes.handle_hts/1,
    ?M => &Raxol.Terminal.ControlCodes.handle_ri/1,
    ?n => &Raxol.Terminal.ControlCodes.handle_ls2/1,
    ?o => &Raxol.Terminal.ControlCodes.handle_ls3/1,
    ?~ => &Raxol.Terminal.ControlCodes.handle_ls1r/1,
    ?} => &Raxol.Terminal.ControlCodes.handle_ls2r/1,
    ?| => &Raxol.Terminal.ControlCodes.handle_ls3r/1,
    ?= => &Raxol.Terminal.Emulator.handle_esc_equals/1,
    ?> => &Raxol.Terminal.Emulator.handle_esc_greater/1
  }

  @doc """
  Handles simple escape sequences (ESC followed by a single byte).
  """
  @spec handle_escape(Emulator.t(), integer()) :: Emulator.t()
  def handle_escape(emulator, byte) do
    Raxol.Core.Runtime.Log.debug("ControlCodes.handle_escape called with byte=#{inspect(byte)}")

    case Map.get(@escape_handlers, byte) do
      nil ->
        Raxol.Core.Runtime.Log.debug("Unhandled escape sequence byte: #{inspect(byte)}")

        emulator

      handler ->
        Raxol.Core.Runtime.Log.debug("Found handler for byte #{inspect(byte)}, calling handler")

        result = handler.(emulator)
        Raxol.Core.Runtime.Log.debug("Handler returned: #{inspect(result)}")
        result
    end
  end

  @doc """
  Handle Locking Shift 2 (LS2) - ESC n
  Invokes G2 character set into GL
  """
  def handle_ls2(%Emulator{} = emulator) do
    %{
      emulator
      | charset_state: %{emulator.charset_state | gl: :g2}
    }
  end

  @doc """
  Handle Locking Shift 3 (LS3) - ESC o
  Invokes G3 character set into GL
  """
  def handle_ls3(%Emulator{} = emulator) do
    %{
      emulator
      | charset_state: %{emulator.charset_state | gl: :g3}
    }
  end

  @doc """
  Handle Locking Shift 1 Right (LS1R) - ESC ~
  Invokes G1 character set into GR
  """
  def handle_ls1r(%Emulator{} = emulator) do
    %{
      emulator
      | charset_state: %{emulator.charset_state | gr: :g1}
    }
  end

  @doc """
  Handle Locking Shift 2 Right (LS2R) - ESC }
  Invokes G2 character set into GR
  """
  def handle_ls2r(%Emulator{} = emulator) do
    %{
      emulator
      | charset_state: %{emulator.charset_state | gr: :g2}
    }
  end

  @doc """
  Handle Locking Shift 3 Right (LS3R) - ESC |
  Invokes G3 character set into GR
  """
  def handle_ls3r(%Emulator{} = emulator) do
    %{
      emulator
      | charset_state: %{emulator.charset_state | gr: :g3}
    }
  end

  # Helper function for line feed cursor adjustment
  defp apply_line_feed_cursor_adjustment(
         moved_cursor,
         _cursor,
         current_col,
         line_feed_mode
       )
       when is_pid(moved_cursor) do
    target_col = get_target_column(line_feed_mode, current_col)
    GenServer.call(moved_cursor, {:move_to_column, target_col})
    moved_cursor
  end

  defp apply_line_feed_cursor_adjustment(
         moved_cursor,
         cursor,
         current_col,
         line_feed_mode
       )
       when is_map(moved_cursor) do
    apply_map_cursor_adjustment(
      Map.has_key?(moved_cursor, :row) and Map.has_key?(moved_cursor, :col),
      moved_cursor,
      cursor,
      current_col,
      line_feed_mode
    )
  end

  defp apply_line_feed_cursor_adjustment(
         _moved_cursor,
         cursor,
         _current_col,
         _line_feed_mode
       ) do
    cursor
  end

  # Helper functions for refactored if statements
  #
  # LF with the cursor on the bottom row of the effective scroll region:
  # scroll the region up one line (Commands.Screen.scroll_up/2 feeds the
  # evicted row into emulator.scrollback_buffer per the TE eviction rules
  # in Emulator.BufferOperations.feed_scrollback_from_region_scroll/3).
  # The cursor row stays on the bottom margin, per VT semantics; the
  # column follows LNM exactly like the non-scrolling branch (col -> 0
  # when line_feed_mode is enabled, unchanged otherwise). The previous
  # `move_cursor_down |> Emulator.maybe_scroll` pipeline never scrolled:
  # move_cursor_down clamps at the bottom margin and Emulator.maybe_scroll
  # only fires on an out-of-bounds row, so the two composed to a no-op.
  defp handle_lf_cursor_movement(true, emulator) do
    line_feed_mode =
      Raxol.Terminal.ModeManager.mode_enabled?(
        emulator.mode_manager,
        :line_feed_mode
      )

    {row, col} = Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)
    target_col = get_target_column(line_feed_mode, col)

    scrolled = Raxol.Terminal.Commands.Screen.scroll_up(emulator, 1)

    pinned_cursor =
      Raxol.Terminal.Cursor.Manager.move_to(scrolled.cursor, row, target_col)

    reset_last_col_exceeded_after_scroll(%{scrolled | cursor: pinned_cursor})
  end

  defp handle_lf_cursor_movement(_at_last_row, emulator) do
    emulator
    |> move_cursor_down()
    |> reset_last_col_exceeded_after_scroll()
  end

  defp handle_pending_wrap(true, emulator) do
    Raxol.Core.Runtime.Log.debug("[handle_cr] Pending wrap detected")
    # Perform the deferred wrap: move cursor to col 0, next line. Position
    # tuples are {row, col} and move_to is (cursor, row, col) -- this
    # previously destructured the COLUMN as the row and passed the
    # arguments swapped (TE amend, finding 3+8). The unclamped row+1 may
    # land past the screen bottom; Emulator.maybe_scroll below detects
    # that overflow and scrolls (feeding scrollback per the TE rules).
    {current_row, _col} =
      Raxol.Terminal.Cursor.Manager.get_position(emulator.cursor)

    wrapped_cursor =
      Raxol.Terminal.Cursor.Manager.move_to(
        emulator.cursor,
        current_row + 1,
        0
      )

    Raxol.Core.Runtime.Log.debug(
      "[handle_cr] Cursor after wrap: #{inspect(Raxol.Terminal.Cursor.Manager.get_position(wrapped_cursor))}"
    )

    # Also scroll if needed after wrap (use maybe_scroll on potentially wrapped state)
    maybe_scrolled_emulator =
      Emulator.maybe_scroll(%{
        emulator
        | cursor: wrapped_cursor,
          last_col_exceeded: false
      })

    Raxol.Core.Runtime.Log.debug(
      "[handle_cr] State after pending wrap + scroll: cursor=#{inspect(Raxol.Terminal.Cursor.Manager.get_position(maybe_scrolled_emulator.cursor))}, last_exceeded=#{maybe_scrolled_emulator.last_col_exceeded}"
    )

    maybe_scrolled_emulator
  end

  defp handle_pending_wrap(_has_wrap, emulator) do
    Raxol.Core.Runtime.Log.debug("[handle_cr] No pending wrap")
    emulator
  end

  defp handle_ri_cursor_movement(true, emulator, _active_buffer) do
    Raxol.Terminal.Commands.Screen.scroll_down(emulator, 1)
  end

  defp handle_ri_cursor_movement(_at_top_margin, emulator, active_buffer) do
    cursor = emulator.cursor
    # Use alias
    cursor =
      Movement.move_up(
        cursor,
        1,
        ScreenBuffer.get_width(active_buffer),
        ScreenBuffer.get_height(active_buffer)
      )

    %{emulator | cursor: cursor}
  end

  defp restore_cursor_state(nil, emulator_cursor), do: emulator_cursor

  defp restore_cursor_state(cursor_data, emulator_cursor) do
    # Restore cursor position
    cursor =
      Raxol.Terminal.Cursor.Manager.set_position(
        emulator_cursor,
        cursor_data.position
      )

    # Restore cursor visibility
    cursor =
      Raxol.Terminal.Cursor.Manager.set_visibility(
        cursor,
        cursor_data.visible
      )

    # Restore cursor style
    cursor =
      Raxol.Terminal.Cursor.Manager.set_style(
        cursor,
        cursor_data.style
      )

    # Restore cursor blinking state
    cursor =
      Raxol.Terminal.Cursor.Manager.set_blink(
        cursor,
        cursor_data.blink_state
      )

    cursor
  end

  defp get_target_column(true, _current_col), do: 0
  defp get_target_column(_line_feed_mode, current_col), do: current_col

  defp apply_map_cursor_adjustment(
         true,
         moved_cursor,
         _cursor,
         current_col,
         line_feed_mode
       ) do
    target_col = get_target_column(line_feed_mode, current_col)
    Raxol.Terminal.Cursor.Manager.move_to_column(moved_cursor, target_col)
  end

  defp apply_map_cursor_adjustment(
         _has_keys,
         _moved_cursor,
         cursor,
         _current_col,
         _line_feed_mode
       ) do
    cursor
  end
end
