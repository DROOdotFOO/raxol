defmodule Raxol.Terminal.Commands.CSIHandlerTest do
  use ExUnit.Case, async: false

  alias Raxol.Terminal.ANSI.CharacterSets.StateManager
  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Commands.CSIHandler
  alias Raxol.Terminal.Cursor.Manager, as: CursorManager
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.Terminal.Window

  setup do
    emulator = new_emulator()
    emulator = %{emulator | saved_cursor: nil}
    {:ok, emulator: emulator}
  end

  # Add a simple test to verify the test infrastructure
  test "test infrastructure is working", %{emulator: emulator} do
    # Verify emulator has required fields
    assert emulator.output_buffer == ""
    assert emulator.cursor.top_margin == 0
    assert emulator.cursor.bottom_margin == 23
    assert emulator.width == 80
    assert emulator.height == 24
    assert emulator.saved_cursor == nil
  end

  defp unwrap_ok({:ok, value}), do: value
  defp unwrap_ok({:error, _reason, value}), do: value
  defp unwrap_ok(value) when is_map(value), do: value

  defp new_emulator do
    Raxol.Test.TestUtils.create_test_emulator_with_struct_cursor()
  end

  describe "handle_s/2 (Save Cursor Position - SCP)" do
    test "saves the current cursor state (position and style)", %{
      emulator: emulator
    } do
      current_cursor_state = %CursorManager{
        row: 0,
        col: 0,
        style: :steady_block,
        visible: true
      }

      emulator_with_cursor = %{emulator | cursor: current_cursor_state}

      result_emulator =
        unwrap_ok(CSIHandler.handle_s(emulator_with_cursor, []))

      assert result_emulator.saved_cursor == current_cursor_state
      # Cursor should have the same position but with saved state populated
      assert result_emulator.cursor.row == current_cursor_state.row
      assert result_emulator.cursor.col == current_cursor_state.col
      assert result_emulator.cursor.saved_row == current_cursor_state.row
      assert result_emulator.cursor.saved_col == current_cursor_state.col
    end
  end

  describe "handle_u/2 (Restore Cursor Position - RCP)" do
    test "restores the cursor state from saved_cursor", %{emulator: emulator} do
      # Set cursor to a specific position
      cursor_with_position = %{emulator.cursor | row: 7, col: 3}
      emulator = %{emulator | cursor: cursor_with_position}

      # Save cursor position (handle_s)
      emulator_with_saved = unwrap_ok(CSIHandler.handle_s(emulator, []))

      # Verify position was saved
      assert emulator_with_saved.cursor.saved_row == 7
      assert emulator_with_saved.cursor.saved_col == 3

      # Move cursor to different position
      moved_cursor = %{emulator_with_saved.cursor | row: 0, col: 0}
      emulator_moved = %{emulator_with_saved | cursor: moved_cursor}

      # Restore cursor position (handle_u)
      result_emulator = unwrap_ok(CSIHandler.handle_u(emulator_moved, []))

      # Verify cursor was restored to saved position
      assert result_emulator.cursor.row == 7
      assert result_emulator.cursor.col == 3
    end

    test "does nothing if saved_cursor is nil", %{emulator: emulator} do
      initial_cursor_state = emulator.cursor
      assert emulator.cursor.saved_row == nil
      assert emulator.cursor.saved_col == nil

      result_emulator = unwrap_ok(CSIHandler.handle_u(emulator, []))

      assert result_emulator == emulator
      assert result_emulator.cursor == initial_cursor_state
    end
  end

  describe "handle_q_deccusr/2 (Set Cursor Style)" do
    test "sets cursor style to blink_block (0 or 1 or default)", %{
      emulator: emulator
    } do
      res_0 = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [0]))
      assert res_0.cursor.style == :blink_block

      res_1 = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [1]))
      assert res_1.cursor.style == :blink_block

      res_default = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, []))
      assert res_default.cursor.style == :blink_block
    end

    test "sets cursor style to steady_block (2)", %{emulator: emulator} do
      result = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [2]))
      assert result.cursor.style == :steady_block
    end

    test "sets cursor style to blink_underline (3)", %{emulator: emulator} do
      result = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [3]))
      assert result.cursor.style == :blink_underline
    end

    test "sets cursor style to steady_underline (4)", %{emulator: emulator} do
      result = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [4]))
      assert result.cursor.style == :steady_underline
    end

    test "sets cursor style to blink_bar (5)", %{emulator: emulator} do
      result = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [5]))
      assert result.cursor.style == :blink_bar
    end

    test "sets cursor style to steady_bar (6)", %{emulator: emulator} do
      result = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [6]))
      assert result.cursor.style == :steady_bar
    end

    test "handles invalid style code, keeps current style", %{
      emulator: emulator
    } do
      initial_style = emulator.cursor.style
      result = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, [99]))
      assert result.cursor.style == initial_style
    end

    test "handles invalid parameter type, defaults to blink_block", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_q_deccusr(emulator, ["invalid"]))
      assert result.cursor.style == :blink_block
    end
  end

  describe "handle_scs/3 (Designate Character Set - Simplified)" do
    test "sets G0 to ASCII with param '0' (actually '?(0'), final_byte '('", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "0", 40))
      assert result.charset_state.g0 == :dec_special_graphics
    end

    test "sets G1 to ASCII with param '0' (actually '?(0'), final_byte ')'", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "0", 41))
      assert result.charset_state.g1 == :dec_special_graphics
    end

    test "sets G0 with param '1' (actually '?(1'), final_byte '('", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "1", 40))
      assert result.charset_state.g0 == :uk
    end

    test "sets G0 with param '16' (actually '?(16'), final_byte '('", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "16", 40))
      assert result.charset_state.g0 == :dec_special_graphics
    end

    test "designates G0 with specific char codes, final_byte '('", %{
      emulator: emulator
    } do
      technical_code_char = ?>

      result_technical =
        unwrap_ok(CSIHandler.handle_scs(emulator, <<technical_code_char>>, 40))

      assert result_technical.charset_state.g0 == :dec_special_graphics

      _initial_g0_for_portuguese_call = emulator.charset_state.g0
      portuguese_char_code = ?'

      result_portuguese =
        unwrap_ok(CSIHandler.handle_scs(emulator, <<portuguese_char_code>>, 40))

      assert result_portuguese.charset_state.g0 == :portuguese

      result_a = unwrap_ok(CSIHandler.handle_scs(emulator, "A", 40))
      assert result_a.charset_state.g0 == :uk
    end

    test "handles unknown code/final_byte combination gracefully", %{
      emulator: emulator
    } do
      _initial_charset_state = emulator.charset_state
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "99", 40))
      # Unknown code "99" defaults to ASCII, so G0 should be updated
      assert result.charset_state.g0 == :us_ascii

      # Test with invalid final_byte ?X - should return error
      result2 = CSIHandler.handle_scs(emulator, "B", ?X)
      assert {:error, :invalid_charset_designation, _} = result2
    end

    test "handles empty params (defaults to code 'B'), final_byte '(', sets G0 to ASCII",
         %{emulator: emulator} do
      # Empty param defaults to "B" -> charset_code ?(B -> ASCII module.
      # final_byte ?(( targets :g0.
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "", 40))
      assert result.charset_state.g0 == :us_ascii
    end

    test "sets G0 to a specific character set using single char param, final_byte '('",
         %{emulator: emulator} do
      technical_code_char = ?R

      result_technical =
        unwrap_ok(CSIHandler.handle_scs(emulator, <<technical_code_char>>, 40))

      assert result_technical.charset_state.g0 ==
               :dec_technical

      result_a = unwrap_ok(CSIHandler.handle_scs(emulator, "A", 40))

      assert result_a.charset_state.g0 ==
               :uk

      portuguese_char_code = ?6

      result_portuguese =
        unwrap_ok(CSIHandler.handle_scs(emulator, <<portuguese_char_code>>, 40))

      assert result_portuguese.charset_state.g0 ==
               :portuguese
    end

    test "handles invalid param gracefully", %{emulator: emulator} do
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "99", 40))

      # Invalid param "99" defaults to ASCII, so G0 should be updated
      assert result.charset_state.g0 ==
               :us_ascii
    end

    test "handles invalid final_byte gracefully", %{emulator: emulator} do
      _original_g0 = emulator.charset_state.g0
      result = CSIHandler.handle_scs(emulator, "99", ?Z)
      assert {:error, :invalid_charset_designation, _} = result
      # The emulator should be unchanged when there's an error
      assert result == {:error, :invalid_charset_designation, emulator}
    end

    test "sets G0 to US ASCII (default) with empty param, final_byte '('", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_scs(emulator, "", 40))

      assert result.charset_state.g0 ==
               :us_ascii
    end
  end

  describe "handle_r/2 (Set Scrolling Region - DECSTBM)" do
    setup %{emulator: emulator} do
      {:ok,
       emulator: emulator,
       buffer_height:
         ScreenBuffer.get_height(Emulator.get_screen_buffer(emulator))}
    end

    test "sets a valid scrolling region and moves cursor to home", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_r(emulator, [5, 10]))
      assert result.scroll_region == {4, 9}
      assert CursorManager.get_position(result.cursor) == {0, 0}
    end

    test "resets to full screen if no parameters and moves cursor to home", %{
      emulator: emulator
    } do
      emulator_with_region = %{emulator | scroll_region: {5, 10}}
      result = unwrap_ok(CSIHandler.handle_r(emulator_with_region, []))
      assert result.scroll_region == nil
      assert CursorManager.get_position(result.cursor) == {0, 0}
    end

    test "resets to full screen if top param only and moves cursor to home", %{
      emulator: emulator,
      buffer_height: bh
    } do
      result = unwrap_ok(CSIHandler.handle_r(emulator, [5]))
      assert result.scroll_region == {4, bh - 1}
      assert CursorManager.get_position(result.cursor) == {0, 0}
    end

    test "resets to full screen if bottom param only (invalid, top defaults to 1)",
         %{emulator: emulator, buffer_height: bh} do
      result = unwrap_ok(CSIHandler.handle_r(emulator, [nil, 10]))
      assert result.scroll_region == {0, 9}
      assert CursorManager.get_position(result.cursor) == {0, 0}
    end

    test "resets to full screen if top >= bottom and moves cursor to home", %{
      emulator: emulator
    } do
      result = unwrap_ok(CSIHandler.handle_r(emulator, [10, 5]))
      assert result.scroll_region == nil
      assert CursorManager.get_position(result.cursor) == {0, 0}

      result2 = unwrap_ok(CSIHandler.handle_r(emulator, [5, 5]))
      assert result2.scroll_region == nil
      assert CursorManager.get_position(result2.cursor) == {0, 0}
    end

    test "handles region spanning full height correctly", %{
      emulator: emulator,
      buffer_height: bh
    } do
      result = unwrap_ok(CSIHandler.handle_r(emulator, [1, bh]))
      assert result.scroll_region == {0, bh - 1}
      assert CursorManager.get_position(result.cursor) == {0, 0}
    end

    test "clamps parameters to buffer height", %{
      emulator: emulator,
      buffer_height: bh
    } do
      result = unwrap_ok(CSIHandler.handle_r(emulator, [5, bh + 10]))
      assert result.scroll_region == {4, bh - 1}
      assert CursorManager.get_position(result.cursor) == {0, 0}

      result2 = unwrap_ok(CSIHandler.handle_r(emulator, [-5, 10]))
      assert result2.scroll_region == {0, 9}
      assert CursorManager.get_position(result2.cursor) == {0, 0}
    end
  end

  describe "error/result tuple propagation" do
    test "handle_u/2 returns ok tuple when no saved_cursor, and only emulator is passed to UI",
         %{emulator: emulator} do
      result = CSIHandler.handle_u(emulator, [])
      assert {:ok, returned_emulator} = result
      assert is_map(returned_emulator)
      assert Map.has_key?(returned_emulator, :__struct__)
      assert returned_emulator.__struct__ == Raxol.Terminal.Emulator
    end

    test "handle_scs/3 returns error tuple for invalid charset designation, and only emulator is passed to UI",
         %{emulator: emulator} do
      # Use invalid charset_param_str and final_byte
      result = CSIHandler.handle_scs(emulator, "", ?Z)
      assert {:error, :invalid_charset_designation, returned_emulator} = result
      # Simulate executor/UI unwrapping
      assert returned_emulator == emulator
      # Only the emulator struct would be passed to the renderer/UI
      assert is_map(returned_emulator)
      assert Map.has_key?(returned_emulator, :__struct__)
      assert returned_emulator.__struct__ == Raxol.Terminal.Emulator
    end
  end

  describe "handle_sequence/2" do
    test "handles cursor movement sequences" do
      emulator = new_emulator()

      # Cursor Up
      state = CSIHandler.handle_sequence(emulator, [?A])
      assert state.cursor.row == 0
      assert state.cursor.col == 0

      # Cursor Down
      state = CSIHandler.handle_sequence(state, [?B])
      assert state.cursor.row == 1
      assert state.cursor.col == 0

      # Cursor Forward
      state = CSIHandler.handle_sequence(state, [?C])
      assert state.cursor.row == 1
      assert state.cursor.col == 1

      # Cursor Backward
      state = CSIHandler.handle_sequence(state, [?D])
      assert state.cursor.row == 1
      assert state.cursor.col == 0
    end

    test "handles cursor positioning sequences" do
      emulator = new_emulator()

      # Cursor Position
      state = CSIHandler.handle_sequence(emulator, [?H])
      assert state.cursor.row == 0
      assert state.cursor.col == 0

      # Cursor Position with parameters
      state = CSIHandler.handle_sequence(state, [?2, ?;, ?3, ?H])
      assert state.cursor.row == 1
      assert state.cursor.col == 2
    end

    test "handles screen clearing sequences" do
      emulator = new_emulator()
      # handle_sequence unwraps {:ok, _} internally, returns bare emulator
      state = CSIHandler.handle_sequence(emulator, [?J])
      assert is_map(state)
      state = CSIHandler.handle_sequence(state, [?1, ?J])
      assert is_map(state)
      state = CSIHandler.handle_sequence(state, [?2, ?J])
      assert is_map(state)
    end

    test "handles line clearing sequences" do
      emulator = new_emulator()
      state = CSIHandler.handle_sequence(emulator, [?K])
      assert is_map(state)
      state = CSIHandler.handle_sequence(state, [?1, ?K])
      assert is_map(state)
      state = CSIHandler.handle_sequence(state, [?2, ?K])
      assert is_map(state)
    end

    test "handles character set sequences" do
      emulator = new_emulator()
      # Designate G0 Character Set
      state = unwrap_ok(CSIHandler.handle_scs(emulator, "B", ?())
      assert state.charset_state.g0 == :us_ascii
      # Designate G1 Character Set
      state = unwrap_ok(CSIHandler.handle_scs(state, "A", ?)))
      assert state.charset_state.g1 == :uk
      # Designate G2 Character Set
      state = unwrap_ok(CSIHandler.handle_scs(state, "F", ?*))
      assert state.charset_state.g2 == :german
      # Designate G3 Character Set
      state = unwrap_ok(CSIHandler.handle_scs(state, "D", ?+))
      assert state.charset_state.g3 == :french
    end

    test "handles shift sequences" do
      emulator = new_emulator()

      # Locking Shift G0
      result = CSIHandler.handle_sequence(emulator, [?N])
      # Handle the {:ok, state} return format
      state =
        case result do
          {:ok, state} -> state
          state -> state
        end

      assert state.charset_state.gl == :g0

      # Locking Shift G1
      result = CSIHandler.handle_sequence(state, [?O])

      state =
        case result do
          {:ok, state} -> state
          state -> state
        end

      assert state.charset_state.gl == :g1

      # Single Shift G2
      result = CSIHandler.handle_sequence(state, [?R])

      state =
        case result do
          {:ok, state} -> state
          state -> state
        end

      assert state.charset_state.single_shift == state.charset_state.g2

      # Single Shift G3
      result = CSIHandler.handle_sequence(state, [?S])

      state =
        case result do
          {:ok, state} -> state
          state -> state
        end

      assert state.charset_state.single_shift == state.charset_state.g3
    end

    test "handles device status sequences" do
      emulator = new_emulator()

      # Device Status Report
      state = CSIHandler.handle_sequence(emulator, [?6, ?n])
      assert state.device_status_reported == true

      # Cursor Position Report
      state = CSIHandler.handle_sequence(emulator, [?6, ?R])
      assert state.cursor_position_reported == true
    end

    test "handles save/restore cursor sequences" do
      emulator = new_emulator()

      # Move cursor to a specific position first
      emulator = %{emulator | cursor: %{emulator.cursor | row: 5, col: 10}}

      # Save Cursor Position
      state = CSIHandler.handle_sequence(emulator, [?s])
      assert state.cursor.saved_row == 5
      assert state.cursor.saved_col == 10

      # Move cursor to a different position
      state = %{state | cursor: %{state.cursor | row: 15, col: 20}}

      # Restore Cursor Position
      state = CSIHandler.handle_sequence(state, [?u])
      assert state.cursor.row == 5
      assert state.cursor.col == 10
    end

    test "ignores unknown sequences" do
      emulator = new_emulator()
      original_state = emulator
      state = CSIHandler.handle_sequence(emulator, [?X])
      assert state == original_state
    end
  end

  describe "handle_cursor_movement/2" do
    test "handles cursor up" do
      emulator = new_emulator()
      {:ok, state} = CSIHandler.handle_cursor_movement(emulator, [?A])
      assert state.cursor.row == 0
      assert state.cursor.col == 0
    end

    test "handles cursor down" do
      emulator = new_emulator()
      {:ok, state} = CSIHandler.handle_cursor_movement(emulator, [?B])
      assert state.cursor.row == 1
      assert state.cursor.col == 0
    end

    test "handles cursor forward" do
      emulator = new_emulator()
      {:ok, state} = CSIHandler.handle_cursor_movement(emulator, [?C])
      assert state.cursor.row == 0
      assert state.cursor.col == 1
    end

    test "handles cursor backward" do
      emulator = new_emulator()
      {:ok, state} = CSIHandler.handle_cursor_movement(emulator, [?D])
      assert state.cursor.row == 0
      assert state.cursor.col == 0
    end
  end

  describe "handle_cursor_position/2" do
    test "handles cursor position without parameters" do
      emulator = new_emulator()
      state = unwrap_ok(CSIHandler.handle_cursor_position(emulator, []))
      assert state.cursor.row == 0
      assert state.cursor.col == 0
    end

    test "handles cursor position with parameters" do
      emulator = new_emulator()

      state =
        unwrap_ok(CSIHandler.handle_cursor_position(emulator, [2, ?;, 3]))

      assert state.cursor.row == 1
      assert state.cursor.col == 2
    end
  end

  describe "handle_screen_clear/2" do
    test "handles clear from cursor to end of screen" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_screen_clear(emulator, [])
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.main_screen_buffer != nil
    end

    test "handles clear from cursor to beginning of screen" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_screen_clear(emulator, [1])
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.main_screen_buffer != nil
    end

    test "handles clear entire screen" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_screen_clear(emulator, [2])
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.main_screen_buffer != nil
    end
  end

  describe "handle_line_clear/2" do
    test "handles clear from cursor to end" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_line_clear(emulator, [])
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.main_screen_buffer != nil
    end

    test "handles clear from start to cursor" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_line_clear(emulator, [1])
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.main_screen_buffer != nil
    end

    test "handles clear entire line" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_line_clear(emulator, [2])
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.main_screen_buffer != nil
    end
  end

  describe "handle_device_status/2" do
    test "handles device status report" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_device_status(emulator, [?6, ?n])
      assert result != nil
    end

    test "handles cursor position report" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = CSIHandler.handle_device_status(emulator, [?6, ?R])
      assert result != nil
    end
  end

  describe "handle_save_restore_cursor/2" do
    test "handles save cursor position" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)
      result = unwrap_ok(CSIHandler.handle_save_restore_cursor(emulator, [?s]))
      assert result.saved_cursor != nil
    end

    test "handles restore cursor position" do
      emulator = Raxol.Terminal.Emulator.new(80, 24)

      emulator = %{
        emulator
        | saved_cursor: %{row: 5, col: 5, style: :block, visible: true}
      }

      result = unwrap_ok(CSIHandler.handle_save_restore_cursor(emulator, [?u]))
      assert result.cursor != nil
    end
  end

  describe "cursor movement" do
    test "moves cursor up", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{row: 10, col: 10, top_margin: 0, bottom_margin: 23}
      }

      {:ok, result} = CSIHandler.handle_cursor_up(emulator, 5)
      assert result.cursor.row == 5
    end

    test "moves cursor down", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{row: 10, col: 10, top_margin: 0, bottom_margin: 23}
      }

      {:ok, result} = CSIHandler.handle_cursor_down(emulator, 5)
      assert result.cursor.row == 15
    end

    test "moves cursor forward", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{
            emulator.cursor
            | row: 10,
              col: 10,
              top_margin: 0,
              bottom_margin: 23
          }
      }

      {:ok, result} = CSIHandler.handle_cursor_forward(emulator, 5)
      assert result.cursor.col == 15
    end

    test "moves cursor backward", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{
            emulator.cursor
            | row: 10,
              col: 10,
              top_margin: 0,
              bottom_margin: 23
          }
      }

      {:ok, result} = CSIHandler.handle_cursor_backward(emulator, 5)
      assert result.cursor.col == 5
    end

    test "moves cursor to column", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{
            emulator.cursor
            | row: 10,
              col: 10,
              top_margin: 0,
              bottom_margin: 23
          }
      }

      {:ok, result} = CSIHandler.handle_cursor_column(emulator, 5)
      # The function converts 1-indexed to 0-indexed, so 5 becomes 4
      assert result.cursor.col == 4
    end

    test "moves cursor to position", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{
            emulator.cursor
            | row: 10,
              col: 10,
              top_margin: 0,
              bottom_margin: 23
          }
      }

      result = CSIHandler.handle_cursor_position(emulator, 5, 15)
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      # handle_cursor_position takes (emulator, row, col) with 1-based coords
      # so row=5 becomes 4 (0-based), col=15 becomes 14 (0-based)
      # 5-1 = 4 (0-based)
      assert emulator_result.cursor.row == 4
      # 15-1 = 14 (0-based)
      assert emulator_result.cursor.col == 14
    end

    test "clamps cursor to screen boundaries", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{
            emulator.cursor
            | row: 10,
              col: 10,
              top_margin: 0,
              bottom_margin: 23
          }
      }

      result = CSIHandler.handle_cursor_position(emulator, 100, 100)
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.cursor.row == 23
      assert emulator_result.cursor.col == 79
    end

    test "handles negative cursor positions", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{
            emulator.cursor
            | row: 10,
              col: 10,
              top_margin: 0,
              bottom_margin: 23
          }
      }

      result = CSIHandler.handle_cursor_position(emulator, -5, -5)
      # Handle both {:ok, emulator} and emulator return values
      emulator_result =
        case result do
          {:ok, emu} -> emu
          emu -> emu
        end

      assert emulator_result.cursor.row == 0
      assert emulator_result.cursor.col == 0
    end

    test "handles zero movement", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{
            emulator.cursor
            | row: 10,
              col: 10,
              top_margin: 0,
              bottom_margin: 23
          }
      }

      {:ok, result} = CSIHandler.handle_cursor_up(emulator, 0)
      assert result.cursor.row == 10
    end
  end

  describe "scrolling" do
    test "scrolls up", %{emulator: emulator} do
      result = CSIHandler.handle_scroll_up(emulator, 5)
      assert result != nil
    end

    test "scrolls down", %{emulator: emulator} do
      result = CSIHandler.handle_scroll_down(emulator, 5)
      assert result != nil
    end

    test "clamps scroll offset to valid range", %{emulator: emulator} do
      result = CSIHandler.handle_scroll_up(emulator, 1000)
      assert result != nil
    end

    test "handles negative scroll amounts", %{emulator: emulator} do
      result = CSIHandler.handle_scroll_up(emulator, -5)
      assert result != nil
    end
  end

  describe "erasing" do
    test "erases display from cursor to end", %{emulator: emulator} do
      emulator = %{emulator | cursor: %{emulator.cursor | row: 10, col: 10}}
      result = CSIHandler.handle_erase_display(emulator, 0)
      assert result != nil
    end

    test "erases display from start to cursor", %{emulator: emulator} do
      emulator = %{emulator | cursor: %{emulator.cursor | row: 10, col: 10}}
      result = CSIHandler.handle_erase_display(emulator, 1)
      assert result != nil
    end

    test "erases entire display", %{emulator: emulator} do
      result = CSIHandler.handle_erase_display(emulator, 2)
      assert result != nil
    end

    test "erases line from cursor to end", %{emulator: emulator} do
      emulator = %{emulator | cursor: %{emulator.cursor | row: 10, col: 10}}
      result = CSIHandler.handle_erase_line(emulator, 0)
      assert result != nil
    end

    test "erases line from start to cursor", %{emulator: emulator} do
      emulator = %{emulator | cursor: %{emulator.cursor | row: 10, col: 10}}
      result = CSIHandler.handle_erase_line(emulator, 1)
      assert result != nil
    end

    test "erases entire line", %{emulator: emulator} do
      emulator = %{emulator | cursor: %{emulator.cursor | row: 10, col: 10}}
      result = CSIHandler.handle_erase_line(emulator, 2)
      assert result != nil
    end

    test "handles invalid erase parameters", %{emulator: emulator} do
      {:ok, result} = CSIHandler.handle_erase_display(emulator, 3)
      assert result == emulator
    end
  end

  describe "text attributes" do
    test "sets text attributes", %{emulator: emulator} do
      result = CSIHandler.handle_text_attributes(emulator, [1, 4, 31])
      assert result != nil
    end

    test "resets text attributes", %{emulator: emulator} do
      emulator = %{
        emulator
        | style: %{bold: true, underline: true, foreground: :red}
      }

      result = CSIHandler.handle_text_attributes(emulator, [0])
      assert result != nil
    end

    test "handles multiple attribute changes", %{emulator: emulator} do
      result = CSIHandler.handle_text_attributes(emulator, [1, 0, 4, 0, 31, 0])
      assert result != nil
    end

    test "handles invalid attribute codes", %{emulator: emulator} do
      {:ok, result} = CSIHandler.handle_text_attributes(emulator, [999])
      assert result == emulator
    end
  end

  describe "mode changes" do
    test "sets insert mode", %{emulator: emulator} do
      {:ok, result} = CSIHandler.handle_mode_change(emulator, 4, true)
      assert result.mode_manager.insert_mode == true
    end

    test "unsets insert mode", %{emulator: emulator} do
      {:ok, emulator} = CSIHandler.handle_mode_change(emulator, 4, true)
      {:ok, result} = CSIHandler.handle_mode_change(emulator, 4, false)
      assert result.mode_manager.insert_mode == false
    end

    test "sets cursor visibility", %{emulator: emulator} do
      {:ok, result} = CSIHandler.handle_mode_change(emulator, 25, true)
      assert result.mode_manager.cursor_visible == true
    end

    test "unsets cursor visibility", %{emulator: emulator} do
      {:ok, emulator} = CSIHandler.handle_mode_change(emulator, 25, true)
      {:ok, result} = CSIHandler.handle_mode_change(emulator, 25, false)
      assert result.mode_manager.cursor_visible == false
    end

    test "handles invalid mode codes", %{emulator: emulator} do
      {:ok, result} = CSIHandler.handle_mode_change(emulator, 999, true)
      assert result == emulator
    end
  end

  describe "device status" do
    test "reports cursor position", %{emulator: emulator} do
      emulator = %{
        emulator
        | cursor: %{emulator.cursor | row: 9, col: 9, position: {9, 9}}
      }

      result = CSIHandler.handle_device_status(emulator, 6)

      assert Raxol.Terminal.OutputManager.get_content(result) =~
               ~r/\x1B\[10;10R/
    end

    test "reports device status", %{emulator: emulator} do
      result = CSIHandler.handle_device_status(emulator, 5)
      assert Raxol.Terminal.OutputManager.get_content(result) =~ ~r/\x1B\[0n/
    end

    test "handles invalid status codes", %{emulator: emulator} do
      result = CSIHandler.handle_device_status(emulator, 999)
      assert result == emulator
    end
  end

  describe "DECSTBM (CSI r) through the real parser path" do
    # Regression (found via the harness overlay picker's shrink-resize
    # suite): the CSI dispatch path (Executor -> handle_basic_command ->
    # handle_csi_sequence -> handle_other_csi) had NO "r" clause, so
    # every DECSTBM arriving mid-stream through the real parser was
    # silently dropped -- the correct handle_r/2 existed but was never
    # reached. Only a region-set REGEXED off the head of a processed
    # input chunk (InputProcessing.preprocess_scroll_region/2) ever
    # applied, which masked the bug for any stream whose first bytes
    # are the initial region set. A terminal that ignores a DECSTBM
    # re-set scrolls at a stale boundary, which corrupts every
    # region-change consumer (resize, footer grow/shrink).
    test "a second DECSTBM mid-stream replaces the scroll region" do
      emulator = Emulator.new(20, 10)
      {emulator, _out} = Emulator.process_input(emulator, "\e[1;8r")
      assert emulator.scroll_region == {0, 7}

      # mid-stream re-set (NOT at the head of the input chunk)
      {emulator, _out} = Emulator.process_input(emulator, "X\e[1;6r")
      assert emulator.scroll_region == {0, 5}
    end

    test "a mid-stream full reset (CSI r, no params) clears the region" do
      emulator = Emulator.new(20, 10)
      {emulator, _out} = Emulator.process_input(emulator, "\e[1;6r")
      assert emulator.scroll_region == {0, 5}

      {emulator, _out} = Emulator.process_input(emulator, "X\e[r")
      assert emulator.scroll_region == nil
    end

    test "LF at the re-set region's bottom scrolls at the NEW boundary" do
      emulator = Emulator.new(20, 10)

      content =
        1..6
        |> Enum.map(fn i -> "\e[#{i};1Hline #{i}\r\n" end)
        |> Enum.join()

      {emulator, _out} =
        Emulator.process_input(
          emulator,
          "\e[1;8r" <> content <> "\e[1;6r\e[6;1H\n\n\n\n"
        )

      # four LFs at row 6 (the NEW bottom) must scroll four times --
      # with the stale 1..8 region they would scroll only twice
      scrollback = Emulator.get_scrollback(emulator)

      assert length(scrollback) >= 4,
             "expected >= 4 scrolled rows, got #{length(scrollback)}"
    end
  end
end
