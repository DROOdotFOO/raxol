defmodule Raxol.Terminal.Emulator.StateStackTest do
  use ExUnit.Case

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cursor.Manager
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  # Note: CharacterSets alias might be needed if asserting charset_state fields directly
  # remove charactersets terminal ansi

  describe "Emulator State Stack (push/pop)" do
    # These tests check the side effects of ANSI sequences handled by Emulator/Parser
    # that utilize the internal state stack (managed by TerminalState).

    test ~c"DECSC/DECRC saves and restores state (ESC 7/8)" do
      emulator = Emulator.new(80, 24)

      # State 1: pos=(1,1), bold=true, G1=DEC Special Graphics
      emulator1 = %{emulator | cursor: Manager.move_to(emulator.cursor, 1, 1)}
      # Update style directly
      emulator1 = %{emulator1 | style: %{emulator1.style | bold: true}}
      # Designate G1 (ESC ) 0)
      {emulator1, ""} = Emulator.process_input(emulator1, "\e)0")
      mode_manager_state1 = emulator1.mode_manager
      # Capture charset state
      charset_state1 = emulator1.charset_state

      # Save state (DECSC - ESC 7)
      {emulator_saved1, ""} = Emulator.process_input(emulator1, "\e7")

      # State 2: pos=(2,2), underline=true, G1=US ASCII (different from state 1)
      emulator2 = %{
        emulator_saved1
        | cursor: Manager.move_to(emulator_saved1.cursor, 2, 2)
      }

      # Reset style before setting new one
      emulator2 = %{emulator2 | style: TextFormatting.new()}
      # Update style directly
      emulator2 = %{emulator2 | style: %{emulator2.style | underline: true}}
      # Designate G1 back to ASCII (ESC ) B)
      {emulator2, ""} = Emulator.process_input(emulator2, "\e)B")
      _mode_manager_state2 = emulator2.mode_manager
      # Capture charset state
      _charset_state2 = emulator2.charset_state

      # Check stack count (indirectly, by testing restore)

      # Restore state (DECRC - ESC 8)
      {emulator_restored1, ""} = Emulator.process_input(emulator2, "\e8")

      # Check state restored to State 1's values
      assert Manager.get_position(emulator_restored1.cursor) == {1, 1}
      # Check style directly
      assert emulator_restored1.style.bold == true
      assert emulator_restored1.style.underline == false
      # Check charset restored
      assert emulator_restored1.charset_state == charset_state1
      # Verify specific field if needed
      assert emulator_restored1.charset_state.g1 == :dec_special_graphics
      # Check mode state restored
      assert emulator_restored1.mode_manager == mode_manager_state1

      # Restore again (should do nothing if stack empty)
      initial_state_before_second_restore = emulator_restored1

      {emulator_restored_again, ""} =
        Emulator.process_input(emulator_restored1, "\e8")

      # Assert no change if stack was empty
      assert emulator_restored_again.cursor ==
               initial_state_before_second_restore.cursor

      assert emulator_restored_again.style ==
               initial_state_before_second_restore.style

      assert emulator_restored_again.charset_state ==
               initial_state_before_second_restore.charset_state

      assert emulator_restored_again.mode_manager ==
               initial_state_before_second_restore.mode_manager
    end

    test ~c"DEC mode 1048 saves/restores cursor state only (no buffer switch)" do
      emulator = Emulator.new(80, 24)

      # 1. Setup state on main buffer
      {emulator, _} = Emulator.process_input(emulator, "MainBuf")
      emulator = %{emulator | cursor: Manager.move_to(emulator.cursor, 10, 5)}
      # Bold (CSI 1 m) - Set some style to ensure it's NOT restored
      {emulator, ""} = Emulator.process_input(emulator, "\e[1m")
      main_buffer_snapshot = Emulator.get_screen_buffer(emulator)
      cursor_snapshot = emulator.cursor
      # Capture style BEFORE save
      style_snapshot = emulator.style

      # 2. Save state (DECSET ?1048h) - Should only save cursor according to implementation
      {emulator, ""} = Emulator.process_input(emulator, "\e[?1048h")

      # Verify buffer did NOT switch
      assert emulator.active_buffer_type == :main

      # Verify buffer content is unchanged (DECSC/DECRC should not affect it for mode 1048)
      active_buffer_after_op = Emulator.get_screen_buffer(emulator)
      line_cells = ScreenBuffer.get_line(active_buffer_after_op, 0)

      line_text =
        if line_cells, do: Enum.map_join(line_cells, & &1.char), else: ""

      # Check content roughly
      assert line_text == "MainBuf" <> String.duplicate(" ", 73)

      assert Emulator.get_screen_buffer(emulator) == main_buffer_snapshot

      # 3. Modify cursor and style on main buffer
      emulator = %{emulator | cursor: Manager.move_to(emulator.cursor, 20, 15)}
      # Underline (CSI 4 m) - Set different style
      {emulator, ""} = Emulator.process_input(emulator, "\e[4m")
      style_after_change = emulator.style

      # 4. Restore state (DECRST ?1048l) - Should only restore cursor
      {emulator, ""} = Emulator.process_input(emulator, "\e[?1048l")

      # Verify still on main buffer
      assert emulator.active_buffer_type == :main
      # Verify main buffer content is unchanged from before restore
      # (Buffer content itself is not saved/restored by 1048)
      active_buffer_after_restore = Emulator.get_screen_buffer(emulator)

      line_cells_after_restore =
        ScreenBuffer.get_line(active_buffer_after_restore, 0)

      line_text_after_restore =
        if line_cells_after_restore,
          do: Enum.map_join(line_cells_after_restore, & &1.char),
          else: ""

      assert line_text_after_restore == "MainBuf" <> String.duplicate(" ", 73)

      # Verify cursor position IS restored
      # Compare position tuple directly
      assert Manager.get_position(emulator.cursor) ==
               Manager.get_position(cursor_snapshot)

      # Verify style IS NOT restored (should remain the style set in step 3)
      assert emulator.style == style_after_change
      # Explicitly check it's different from original
      refute emulator.style == style_snapshot

      # 5. Verify stack behavior (optional: DECRC ESC 8 should restore same cursor)
      # Let's skip this as the main logic is tested above
    end

    test ~c"DEC mode 1047 switches to alternate buffer and restores state" do
      emulator = Emulator.new(80, 24)
      # Write to main buffer
      {emulator, _} = Emulator.process_input(emulator, "MainBuf")
      main_buffer_snapshot = Emulator.get_screen_buffer(emulator)
      # Switch to alternate buffer (DECSET ?1047h)
      {emulator, _} = Emulator.process_input(emulator, "\e[?1047h")
      assert emulator.active_buffer_type == :alternate
      # Write to alternate buffer
      {emulator, _} = Emulator.process_input(emulator, "AltBuf")
      alt_buffer_snapshot = Emulator.get_screen_buffer(emulator)
      # Switch back to main buffer (DECRST ?1047l)
      {emulator, _} = Emulator.process_input(emulator, "\e[?1047l")
      assert emulator.active_buffer_type == :main
      # Main buffer should be unchanged
      assert Emulator.get_screen_buffer(emulator) == main_buffer_snapshot
      # Alternate buffer should retain its content for next switch
      {emulator, _} = Emulator.process_input(emulator, "\e[?1047h")
      assert Emulator.get_screen_buffer(emulator) == alt_buffer_snapshot
    end

    test ~c"DEC mode 1049 switches to alternate buffer, clears it, and restores state" do
      emulator = Emulator.new(80, 24)
      # Write to main buffer
      {emulator, _} = Emulator.process_input(emulator, "MainBuf")
      main_buffer_snapshot = Emulator.get_screen_buffer(emulator)
      # Switch to alternate buffer (DECSET ?1049h)
      {emulator, _} = Emulator.process_input(emulator, "\e[?1049h")
      assert emulator.active_buffer_type == :alternate
      # Alternate buffer should be cleared
      alt_buffer = Emulator.get_screen_buffer(emulator)

      assert Enum.all?(alt_buffer.cells, fn row ->
               Enum.all?(row, &(&1.char == " "))
             end)

      # Write to alternate buffer
      {emulator, _} = Emulator.process_input(emulator, "AltBuf")
      # Switch back to main buffer (DECRST ?1049l)
      {emulator, _} = Emulator.process_input(emulator, "\e[?1049l")
      assert emulator.active_buffer_type == :main
      # Main buffer should be unchanged
      assert Emulator.get_screen_buffer(emulator) == main_buffer_snapshot
      # Alternate buffer should be cleared again on next switch
      {emulator, _} = Emulator.process_input(emulator, "\e[?1049h")
      alt_buffer2 = Emulator.get_screen_buffer(emulator)

      assert Enum.all?(alt_buffer2.cells, fn row ->
               Enum.all?(row, &(&1.char == " "))
             end)
    end
  end
end
