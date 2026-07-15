defmodule Raxol.Terminal.Commands.ScreenTest do
  use ExUnit.Case, async: false

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Commands.Screen
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  defp assert_entire_buffer_cleared(buffer, width \\ 10, height \\ 5) do
    for y <- 0..(height - 1) do
      for x <- 0..(width - 1) do
        cell = ScreenBuffer.get_cell(buffer, x, y)

        assert cell.char == " ",
               "Expected cell at (#{x},#{y}) to be cleared (space), got: #{inspect(cell)}"
      end
    end
  end

  # Set up test fixtures
  # setup do
  #   # Create a minimal emulator for testing using the constructor
  #   initial_emulator = Emulator.new(10, 5)
  #
  #   # Set cursor position using input processing
  #   # Move to (2, 2) zero-indexed
  #   {emulator, _output} = Emulator.process_input(initial_emulator, "\e[3;3H")
  #
  #   {:ok, %{emulator: emulator}}
  # end

  describe "clear_screen/2" do
    test ~c"clears from cursor to end of screen (mode 0)" do
      # Setup: Create emulator and move cursor to (2,2)
      initial_emulator = Emulator.new(10, 5)

      # Fill buffer with test data first
      filled_buffer =
        Enum.reduce(0..4, initial_emulator.main_screen_buffer, fn y, acc ->
          Enum.reduce(0..9, acc, fn x, buf ->
            ScreenBuffer.write_char(buf, x, y, "X", TextFormatting.new())
          end)
        end)

      emulator = %{initial_emulator | main_screen_buffer: filled_buffer}

      # Move cursor to (2, 2) zero-indexed
      {emulator, _output} = Emulator.process_input(emulator, "\e[3;3H")
      # Cursor movement via escape sequence doesn't work, so set directly
      emulator = Emulator.set_cursor_position(emulator, 2, 2)

      # Clear from cursor to end of screen (mode 0)
      emulator_after_clear = Screen.clear_screen(emulator, 0)

      # Check that cells before cursor are unchanged (check char)
      for y <- 0..1 do
        for x <- 0..9 do
          assert ScreenBuffer.get_cell(
                   emulator_after_clear.main_screen_buffer,
                   x,
                   y
                 ).char == "X"
        end
      end

      for x <- 0..1 do
        assert ScreenBuffer.get_cell(
                 emulator_after_clear.main_screen_buffer,
                 x,
                 2
               ).char == "X"
      end

      # Check that cells from cursor to end are cleared (check char is space)
      for y <- 2..4 do
        start_col = if y == 2, do: 2, else: 0

        for x <- start_col..9 do
          cell =
            ScreenBuffer.get_cell(emulator_after_clear.main_screen_buffer, x, y)

          assert cell.char == " ",
                 "Expected cell at (#{x},#{y}) to be cleared (space), got: #{inspect(cell)}"
        end
      end
    end

    test ~c"clears from beginning of screen to cursor (mode 1)" do
      # Setup: Create emulator and move cursor to (2,2)
      initial_emulator = Emulator.new(10, 5)
      # Move to (2, 2) zero-indexed - using direct cursor manipulation
      new_cursor = %{initial_emulator.cursor | row: 2, col: 2, position: {2, 2}}
      emulator = %{initial_emulator | cursor: new_cursor}

      # Fill buffer with test data
      filled_buffer =
        Enum.reduce(0..4, emulator.main_screen_buffer, fn y, acc ->
          Enum.reduce(0..9, acc, fn x, buf ->
            ScreenBuffer.write_char(buf, x, y, "X", TextFormatting.new())
          end)
        end)

      emulator = %{emulator | main_screen_buffer: filled_buffer}

      # Assert that the specific cell (8,0) is "X" before clearing
      assert ScreenBuffer.get_cell(emulator.main_screen_buffer, 8, 0).char ==
               "X",
             "Cell (8,0) should be \"X\" before clear_screen (mode 1) is called"

      # Clear from beginning of screen to cursor (2,2)
      emulator_after_clear = Screen.clear_screen(emulator, 1)

      # Check that cells up to cursor are cleared (check char is space)
      for y <- 0..1 do
        for x <- 0..9 do
          cell =
            ScreenBuffer.get_cell(emulator_after_clear.main_screen_buffer, x, y)

          assert cell.char == " ",
                 "Expected cell at (#{x},#{y}) to be cleared (space), got: #{inspect(cell)}"
        end
      end

      for x <- 0..2 do
        cell =
          ScreenBuffer.get_cell(emulator_after_clear.main_screen_buffer, x, 2)

        assert cell.char == " ",
               "Expected cell at (#{x},2) to be cleared (space), got: #{inspect(cell)}"
      end

      # Check that cells after cursor are unchanged (check char)
      for y <- 2..4 do
        start_col = if y == 2, do: 3, else: 0

        for x <- start_col..9 do
          cell =
            ScreenBuffer.get_cell(emulator_after_clear.main_screen_buffer, x, y)

          assert cell.char == "X",
                 "Expected cell at (#{x},#{y}) to be \"X\", got: #{inspect(cell)}"
        end
      end
    end

    test ~c"clears entire screen (mode 2)" do
      # Setup: Create emulator and move cursor to (2,2)
      initial_emulator = Emulator.new(10, 5)
      # Move to (2, 2) zero-indexed
      {emulator, _output} = Emulator.process_input(initial_emulator, "\e[3;3H")

      # Fill buffer with test data
      filled_buffer =
        Enum.reduce(0..4, emulator.main_screen_buffer, fn y, acc ->
          Enum.reduce(0..9, acc, fn x, buf ->
            ScreenBuffer.write_char(buf, x, y, "X", TextFormatting.new())
          end)
        end)

      emulator = %{emulator | main_screen_buffer: filled_buffer}

      # Clear entire screen
      result = Screen.clear_screen(emulator, 2)

      # Check that all cells are cleared
      assert_entire_buffer_cleared(result.main_screen_buffer)
    end

    test ~c"clears entire screen and scrollback (mode 3)" do
      # Setup: Create emulator and move cursor to (2,2)
      initial_emulator = Emulator.new(10, 5)
      # Move to (2, 2) zero-indexed
      {emulator, _output} = Emulator.process_input(initial_emulator, "\e[3;3H")

      # Fill buffer with test data
      filled_buffer =
        Enum.reduce(0..4, emulator.main_screen_buffer, fn y, acc ->
          Enum.reduce(0..9, acc, fn x, buf ->
            ScreenBuffer.write_char(buf, x, y, "X", TextFormatting.new())
          end)
        end)

      emulator = %{emulator | main_screen_buffer: filled_buffer}
      # Clear entire screen and scrollback
      result = Screen.clear_screen(emulator, 3)

      # Check that all cells are cleared
      assert_entire_buffer_cleared(result.main_screen_buffer)

      # Check that scrollback buffer is also cleared
      assert result.scrollback_buffer == []
    end
  end

  describe "clear_line/2" do
    test ~c"clears from cursor to end of line (mode 0)" do
      initial_emulator = Emulator.new(10, 5)
      # Move to (2, 2) zero-indexed - using direct cursor manipulation
      new_cursor = %{initial_emulator.cursor | row: 2, col: 2, position: {2, 2}}
      emulator = %{initial_emulator | cursor: new_cursor}

      filled_buffer =
        Enum.reduce(0..9, emulator.main_screen_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 2, "X", TextFormatting.new())
        end)

      emulator = %{emulator | main_screen_buffer: filled_buffer}
      result = Screen.clear_line(emulator, 0)

      for x <- 0..1 do
        cell = ScreenBuffer.get_cell(result.main_screen_buffer, x, 2)
        assert cell.char == "X"
      end

      for x <- 2..9 do
        cell = ScreenBuffer.get_cell(result.main_screen_buffer, x, 2)
        assert cell.char == " "
      end
    end

    test ~c"clears from beginning of line to cursor (mode 1)" do
      # Setup: Create emulator and move cursor to (2,2)
      initial_emulator = Emulator.new(10, 5)
      # Move to (2, 2) zero-indexed
      {emulator, _output} = Emulator.process_input(initial_emulator, "\e[3;3H")

      # Fill buffer with test data
      filled_buffer =
        Enum.reduce(0..9, emulator.main_screen_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 2, "X", TextFormatting.new())
        end)

      emulator = %{emulator | main_screen_buffer: filled_buffer}

      # Clear from beginning of line to cursor (2,2)
      result = Screen.clear_line(emulator, 1)

      # Check that cells before cursor are cleared (check char is space)
      for x <- 0..2 do
        cell = ScreenBuffer.get_cell(result.main_screen_buffer, x, 2)

        assert cell.char == " ",
               "Expected cell at (#{x},2) to be cleared (space), got: #{inspect(cell)}"
      end

      # Check that cells after cursor are unchanged (check char)
      for x <- 3..9 do
        cell = ScreenBuffer.get_cell(result.main_screen_buffer, x, 2)

        assert cell.char == "X",
               "Expected cell at (#{x},2) to be \"X\", got: #{inspect(cell)}"
      end
    end

    test ~c"clears entire line (mode 2)" do
      # Setup: Create emulator and move cursor to (2,2)
      initial_emulator = Emulator.new(10, 5)
      # Move to (2, 2) zero-indexed - using direct cursor manipulation
      new_cursor = %{initial_emulator.cursor | row: 2, col: 2, position: {2, 2}}
      emulator = %{initial_emulator | cursor: new_cursor}

      # Fill buffer with test data
      filled_buffer =
        Enum.reduce(0..9, emulator.main_screen_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 2, "X", TextFormatting.new())
        end)

      emulator = %{emulator | main_screen_buffer: filled_buffer}

      # Clear entire line
      result = Screen.clear_line(emulator, 2)

      # Check that all cells in the line are cleared (check char is space)
      for x <- 0..9 do
        cell = ScreenBuffer.get_cell(result.main_screen_buffer, x, 2)

        assert cell.char == " ",
               "Expected cell at (#{x},2) to be cleared (space), got: #{inspect(cell)}"
      end
    end
  end

  describe "EL and ED operations" do
    # Setup for EL tests specifically, providing emulator and buffer_width/height
    setup do
      # width 10, height 5
      emulator = Emulator.new(10, 5)
      {:ok, %{emulator: emulator, buffer_width: 10, buffer_height: 5}}
    end

    # test "EL erases line from cursor to end", %{
    #   emulator: emulator, buffer_width: _buffer_width
    # } do
    #   # Initial: "Hello" at (0,0), cursor at (5,0)
    #   # Move: to (2,1)
    #   # Write: "World", cursor at (7,1) (0-indexed: __World___)
    #   # Move: 3 left to (4,1) (on 'l' of "World")
    #   # Erase: \e[K (EL mode 0: from cursor to end)
    #   input_str = "Hello\e[2;3HWorld\e[3D\e[K"
    #   {emulator, _output} = Emulator.process_input(emulator, input_str)
    #   buffer = Emulator.get_screen_buffer(emulator)
    #
    #   line1_cells = ScreenBuffer.get_line(buffer, 0)
    #   line2_cells = ScreenBuffer.get_line(buffer, 1)
    #
    #   # Line 0 should remain "Hello" followed by spaces
    #   assert Enum.map(line1_cells, & &1.char) == String.graphemes("Hello") ++ List.duplicate(" ", buffer.width - 5)
    #
    #   # Line 1: After "World" at (2,1) -> "  World   "
    #   # Cursor moves to (4,1) (on 'l'). \e[K clears from 'l' to end.
    #   # Expected: "  Wo      "
    #   assert Enum.map(line2_cells, & &1.char) == ~c"  Wo" ++ List.duplicate(" ", buffer.width - 4)
    #
    #   assert Emulator.get_cursor_position(emulator) == {4, 1}
    # end

    # test "EL erases line from beginning to cursor",
    #      %{emulator: emulator, buffer_width: _buffer_width} do
    #   input_str = "Hello\e[2;3HWorld\e[3D\e[1K"
    #   {emulator, _output} = Emulator.process_input(emulator, input_str)
    #   buffer = Emulator.get_screen_buffer(emulator)
    #   line1_cells = ScreenBuffer.get_line(buffer, 0)
    #   line2_cells = ScreenBuffer.get_line(buffer, 1)
    #
    #   # Line 0 should remain "Hello" followed by spaces
    #   assert Enum.map(line1_cells, & &1.char) == String.graphemes("Hello") ++ List.duplicate(" ", buffer.width - 5)
    #   # Line 1: After "World" at (2,1) -> "  World   "
    #   # Cursor moves to (4,1) (on 'l' of "World").
    #   # Content: [' ', ' ', 'W', 'o', 'r', 'l', 'd', ' ', ' ', ' ']. Cursor x=4.
    #   # \e[1K clears from beginning up to and including cursor (index 4).
    #   # Clears indices 0, 1, 2, 3, 4. Expected: "     ld   "
    #   assert Enum.map(line2_cells, & &1.char) == List.duplicate(" ", 5) ++ String.graphemes("ld") ++ List.duplicate(" ", buffer.width - 7)
    #   assert Emulator.get_cursor_position(emulator) == {4, 1}
    # end

    # test "EL erases entire line", %{emulator: emulator, buffer_width: _buffer_width} do
    #   input_str = "Hello\e[2;3HWorld\e[3D\e[2K"
    #   {emulator, _output} = Emulator.process_input(emulator, input_str)
    #   buffer = Emulator.get_screen_buffer(emulator)
    #   line1_cells = ScreenBuffer.get_line(buffer, 0)
    #   line2_cells = ScreenBuffer.get_line(buffer, 1)
    #
    #   # Line 0: "Hello     "
    #   assert Enum.map(line1_cells, & &1.char) == String.graphemes("Hello") ++ List.duplicate(" ", buffer.width - 5)
    #   # Line 1: After "World" at (2,1) -> "  World   "
    #   # Cursor at (4,1). \e[2K clears entire line 1.
    #   assert Enum.map(line2_cells, & &1.char) == List.duplicate(" ", buffer.width)
    #   assert Emulator.get_cursor_position(emulator) == {4, 1} # Cursor position should not change
    # end

    test "ED erases screen from beginning to cursor", %{
      emulator: emulator,
      buffer_width: _buffer_width,
      buffer_height: _buffer_height
    } do
      # Fill screen with 'A's, then put 'B's on line 1, 'C's on line 2, 'D's on line 3
      # Cursor at (1,3) (0-indexed)
      # Erase: \e[1J (ED mode 1: from beginning to cursor)

      text_style = TextFormatting.new()

      # Fill each row with appropriate characters
      filled_buffer = emulator.main_screen_buffer

      # Fill row 0 with 'A's
      filled_buffer =
        Enum.reduce(0..9, filled_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 0, "A", text_style)
        end)

      # Fill row 1 with 'B's
      filled_buffer =
        Enum.reduce(0..9, filled_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 1, "B", text_style)
        end)

      # Fill row 2 with 'C's
      filled_buffer =
        Enum.reduce(0..9, filled_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 2, "C", text_style)
        end)

      # Fill row 3 with 'D's
      filled_buffer =
        Enum.reduce(0..9, filled_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 3, "D", text_style)
        end)

      # Fill row 4 with 'A's
      filled_buffer =
        Enum.reduce(0..9, filled_buffer, fn x, buf ->
          ScreenBuffer.write_char(buf, x, 4, "A", text_style)
        end)

      emulator = Emulator.update_active_buffer(emulator, filled_buffer)

      # Move to position (1,3) and erase from beginning to cursor
      # Cursor to (1,3) (0-indexed), then erase to beginning
      input_str = "\e[2;4H\e[1J"

      {emulator, _output} = Emulator.process_input(emulator, input_str)
      buffer = Emulator.get_screen_buffer(emulator)

      # Lines 0 should be all spaces (completely cleared)
      assert Enum.map(ScreenBuffer.get_line(buffer, 0), & &1.char) ==
               List.duplicate(" ", buffer.width)

      # Line 1: Cursor was at (1,3). "BBBBBBBBBB" -> "    BBBBBB"
      # Columns 0, 1, 2, 3 cleared (inclusive), leaving columns 4-9 as "B"
      line1_content = Enum.map(ScreenBuffer.get_line(buffer, 1), & &1.char)
      expected_line1 = List.duplicate(" ", 4) ++ String.graphemes("BBBBBB")
      assert line1_content == expected_line1

      # Lines 2, 3, 4 should be untouched
      assert Enum.map(ScreenBuffer.get_line(buffer, 2), & &1.char) ==
               List.duplicate("C", buffer.width)

      assert Enum.map(ScreenBuffer.get_line(buffer, 3), & &1.char) ==
               List.duplicate("D", buffer.width)

      assert Enum.map(ScreenBuffer.get_line(buffer, 4), & &1.char) ==
               List.duplicate("A", buffer.width)

      assert Emulator.get_cursor_position(emulator) == {1, 3}
    end

    test "ED erases entire screen", %{
      emulator: emulator,
      buffer_width: _buffer_width,
      buffer_height: _buffer_height
    } do
      # Fill screen with 'A's
      # Cursor at (1,1)
      # Erase: \e[2J (ED mode 2: entire screen)

      # Replace ScreenBuffer.fill/3 with manual iteration using ScreenBuffer.write_char/5
      text_style_a = TextFormatting.new()

      full_a_buffer =
        Enum.reduce(
          0..(emulator.main_screen_buffer.height - 1),
          emulator.main_screen_buffer,
          fn y, acc_buffer ->
            Enum.reduce(
              0..(emulator.main_screen_buffer.width - 1),
              acc_buffer,
              fn x, inner_acc_buffer ->
                ScreenBuffer.write_char(
                  inner_acc_buffer,
                  x,
                  y,
                  "A",
                  text_style_a
                )
              end
            )
          end
        )

      emulator = Emulator.update_active_buffer(emulator, full_a_buffer)

      # Cursor to (1,1), then erase entire screen
      input_str = "\e[2;2H\e[2J"

      {emulator, _output} = Emulator.process_input(emulator, input_str)
      buffer = Emulator.get_screen_buffer(emulator)

      # All lines should be spaces
      for y <- 0..(buffer.height - 1) do
        assert Enum.map(ScreenBuffer.get_line(buffer, y), & &1.char) ==
                 List.duplicate(" ", buffer.width)
      end

      # Cursor position does not change for ED
      assert Emulator.get_cursor_position(emulator) == {1, 1}
    end

    test "ED command clears screen correctly" do
      emulator = Emulator.new(80, 24)
      {emulator, _} = Emulator.process_input(emulator, "Hello World")
      # Move to row 4, col 2
      {emulator, _} = Emulator.process_input(emulator, "\e[4;2H")
      # Clear from cursor to end
      {emulator, _} = Emulator.process_input(emulator, "\e[J")

      position = Emulator.get_cursor_position(emulator)
      # {row, col} format: row 3, col 1
      assert position == {3, 1}
    end
  end

  describe "scroll_up/2 scrollback feed (TE unit)" do
    defp row_text(row) do
      row
      |> Enum.map_join("", fn
        %{char: char} when is_binary(char) -> char
        _ -> " "
      end)
      |> String.trim_trailing()
    end

    test "full-screen scroll (no scroll region set) feeds the evicted row into scrollback" do
      emulator = Emulator.new(10, 5)

      filled =
        ScreenBuffer.write_string(
          emulator.main_screen_buffer,
          0,
          0,
          "TOPROW",
          TextFormatting.new()
        )

      emulator = Emulator.update_active_buffer(emulator, filled)

      emulator = Screen.scroll_up(emulator, 1)

      assert [row] = Emulator.get_scrollback(emulator)
      assert row_text(row) == "TOPROW"
    end

    test "top-anchored scroll region (top row 1 / internal row 0) feeds evicted rows into scrollback" do
      emulator = Emulator.new(10, 5)

      filled =
        ScreenBuffer.write_string(
          emulator.main_screen_buffer,
          0,
          0,
          "TOPROW",
          TextFormatting.new()
        )

      filled = ScreenBuffer.set_scroll_region(filled, {0, 2})
      emulator = Emulator.update_active_buffer(emulator, filled)

      emulator = Screen.scroll_up(emulator, 1)

      assert [row] = Emulator.get_scrollback(emulator)
      assert row_text(row) == "TOPROW"
    end

    test "interior scroll region (top > 0) discards evicted rows -- no scrollback feed" do
      emulator = Emulator.new(10, 5)

      filled =
        ScreenBuffer.write_string(
          emulator.main_screen_buffer,
          0,
          1,
          "EVICTME",
          TextFormatting.new()
        )

      filled = ScreenBuffer.set_scroll_region(filled, {1, 3})
      emulator = Emulator.update_active_buffer(emulator, filled)

      emulator = Screen.scroll_up(emulator, 1)

      assert Emulator.get_scrollback(emulator) == []
    end

    test "alternate screen buffer scroll never feeds scrollback" do
      emulator = Emulator.new(10, 5)
      emulator = %{emulator | active_buffer_type: :alternate}

      filled =
        ScreenBuffer.write_string(
          emulator.alternate_screen_buffer,
          0,
          0,
          "ALTROW",
          TextFormatting.new()
        )

      emulator = Emulator.update_active_buffer(emulator, filled)

      emulator = Screen.scroll_up(emulator, 1)

      assert Emulator.get_scrollback(emulator) == []
    end

    test "respects scrollback_limit, trimming the oldest entries first" do
      emulator = Emulator.new(10, 5)
      emulator = %{emulator | scrollback_limit: 2}

      emulator =
        Enum.reduce(0..4, emulator, fn i, acc ->
          filled =
            ScreenBuffer.write_string(
              acc.main_screen_buffer,
              0,
              0,
              "R#{i}",
              TextFormatting.new()
            )

          acc
          |> Emulator.update_active_buffer(filled)
          |> Screen.scroll_up(1)
        end)

      scrollback = Emulator.get_scrollback(emulator)
      assert length(scrollback) == 2
      assert Enum.map(scrollback, &row_text/1) == ["R3", "R4"]
    end
  end
end
