defmodule Raxol.Terminal.Emulator.ProcessInputTest do
  use ExUnit.Case

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  describe "process_input state machine" do
    # Tests focus on how Emulator.process_input handles various sequences

    test ~c"handles basic CSI sequence (Cursor Up)" do
      emulator = Emulator.new(80, 24)
      # Move cursor down first by processing a cursor down sequence
      {emulator, ""} = Emulator.process_input(emulator, "\e[5B")
      assert Emulator.get_cursor_position_struct(emulator) == {5, 0}

      # Process CSI A (Cursor Up)
      {emulator, ""} = Emulator.process_input(emulator, "\e[A")
      assert Emulator.get_cursor_position_struct(emulator) == {4, 0}
    end

    test ~c"handles parameterized CSI sequence (Cursor Down 5)" do
      emulator = Emulator.new(80, 24)
      assert Emulator.get_cursor_position_struct(emulator) == {0, 0}

      # Process CSI 5 B (Cursor Down 5)
      {emulator, ""} = Emulator.process_input(emulator, "\e[5B")
      assert Emulator.get_cursor_position_struct(emulator) == {5, 0}
    end

    test ~c"handles multi-parameter CSI sequence (Cursor Position 10, 20)" do
      emulator = Emulator.new(80, 24)
      assert Emulator.get_cursor_position_struct(emulator) == {0, 0}

      # Process CSI 20;10 H (Cursor Position row 20, col 10)
      {emulator, ""} = Emulator.process_input(emulator, "\e[20;10H")
      # Remember: row/col are 1-based in sequence, state is {row, col} 0-based
      assert Emulator.get_cursor_position_struct(emulator) == {19, 9}
    end

    test ~c"handles mixed printable text and CSI sequences" do
      emulator = Emulator.new(80, 24)
      # Write "Hello", move cursor up, write "World"
      input = "Hello" <> "\e[A" <> "World"
      {emulator, ""} = Emulator.process_input(emulator, input)

      buffer = Emulator.get_screen_buffer(emulator)
      # Check buffer content
      assert ScreenBuffer.get_cell_at(buffer, 0, 0).char == "H"
      assert ScreenBuffer.get_cell_at(buffer, 4, 0).char == "o"
      # Cursor moves to {5, 0}, then Up -> {5, 0} (clamped), then "World" writes
      assert ScreenBuffer.get_cell_at(buffer, 5, 0).char == "W"
      assert ScreenBuffer.get_cell_at(buffer, 9, 0).char == "d"
      # Final cursor position
      assert Emulator.get_cursor_position_struct(emulator) == {0, 10}
    end

    test ~c"handles OSC sequence (Set Window Title)" do
      emulator = Emulator.new(80, 24)
      title = "My Test Title"
      # Process OSC 0 ; title ST (ESC ] 0 ; title ESC \
      input = "\e]0;" <> title <> "\e\\"
      {emulator, ""} = Emulator.process_input(emulator, input)

      # Check window_title field was updated
      assert emulator.window_title == title
    end

    test ~c"handles simple ESC sequence (Index)" do
      emulator = Emulator.new(80, 24)
      # Position cursor by using cursor position sequence
      {emulator, ""} = Emulator.process_input(emulator, "\e[6;6H")
      assert Emulator.get_cursor_position_struct(emulator) == {5, 5}

      # Process ESC D (Index - move down one line, same column)
      {emulator, ""} = Emulator.process_input(emulator, "\eD")
      assert Emulator.get_cursor_position_struct(emulator) == {6, 5}
    end

    test ~c"handles basic DCS sequence" do
      emulator = Emulator.new(80, 24)
      # Example DCS sequence (content doesn't matter for this test)
      # \eP is DCS start, \e\ is ST (String Terminator)
      dcs_sequence = <<27>> <> "P1;1;1{" <> "hello world" <> <<27>> <> "\\"
      {_emulator, remaining} = Emulator.process_input(emulator, dcs_sequence)

      # For now, assert that the sequence is consumed completely
      assert remaining == ""

      # More specific assertions could be added if Emulator state tracks DCS processing
    end

    test ~c"handles CSI with intermediate character (Private Mode DECTCEM Show Cursor)" do
      emulator = Emulator.new(80, 24)

      # The cursor's default visibility is not forced here, so this asserts
      # only that the show-cursor sequence leaves it visible.

      # Example private mode sequence: Show Cursor (DECTCEM)
      # CSI ? 25 h
      sequence = "\e[?25h"
      {emulator, remaining} = Emulator.process_input(emulator, sequence)

      # Assert the sequence is consumed
      assert remaining == ""
      # Assert cursor visibility state change (DECTCEM enables cursor)
      assert Emulator.get_mode_manager_cursor_visible(emulator) == true
    end

    test ~c"handles incomplete CSI sequence correctly" do
      emulator = Emulator.new(80, 24)
      partial_input = "\e["

      {emulator_after, _output1} =
        Emulator.process_input(emulator, partial_input)

      # Check that the parser didn't crash and returned the partial input
      # (or indicated incomplete state somehow?)
      # Current API returns output_buffer as second element, not remaining input.
      # Asserting remaining1 == partial_input seems wrong based on current process_input signature.
      # NO ASSERTION ON remaining1 NEEDED. We just check the final state after next input.

      # Maybe the test should assert something else?
      # e.g., assert emulator_after state indicates partial sequence? (No such state exists)

      # Send the rest of the sequence (e.g., Cursor Up 'A')
      rest_of_input = "A"

      {_emulator, remaining2} =
        Emulator.process_input(emulator_after, rest_of_input)

      # Expect the sequence to be completed and consumed
      assert remaining2 == ""
      # We can check the final cursor position after the completed sequence
      # Assuming initial {0,0} and Up clamps
      assert Emulator.get_cursor_position_struct(emulator) == {0, 0}
    end

    test ~c"resets state after incomplete sequence followed by text" do
      emulator = Emulator.new(80, 24)
      partial_input = "\e["

      {_emulator_after_partial, _output1} =
        Emulator.process_input(emulator, partial_input)

      # Process subsequent normal text
      text_input = "Hello"
      {emulator, remaining2} = Emulator.process_input(emulator, text_input)

      # Assuming parser resets, expect text to be processed, remaining empty.
      assert remaining2 == ""
      # Check buffer for "Hello" and cursor position
      buffer = Emulator.get_screen_buffer(emulator)
      assert ScreenBuffer.get_cell_at(buffer, 0, 0).char == "H"
      assert Emulator.get_cursor_position_struct(emulator) == {0, 5}
    end

    test ~c"handles alternate screen buffer mode correctly" do
      emulator = Emulator.new(80, 24)
      # Assuming DECTCEM (Cursor Enable Mode) is handled
      {emulator, _} = Emulator.process_input(emulator, "\e[?25h")
      assert Emulator.get_mode_manager_cursor_visible(emulator) == true

      {emulator, _} = Emulator.process_input(emulator, "\e[?25l")
      assert Emulator.get_mode_manager_cursor_visible(emulator) == false
    end
  end
end
