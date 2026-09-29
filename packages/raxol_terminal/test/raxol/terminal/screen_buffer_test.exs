defmodule Raxol.Terminal.ScreenBufferTest do
  use ExUnit.Case
  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cell
  alias Raxol.Terminal.ScreenBuffer

  # Helper to convert a list of cells to a string for easier assertions
  defp line_to_string(line) when is_list(line) do
    Enum.map_join(line, "", &Cell.get_char/1)
  end

  defp line_to_string(nil), do: ""

  describe "initialization" do
    test ~c"creates a new buffer with correct dimensions" do
      buffer = ScreenBuffer.new(10, 5)
      assert length(buffer.cells) == 5
      assert length(List.first(buffer.cells)) == 10
      assert buffer.width == 10
      assert buffer.height == 5
    end

    test ~c"initializes with empty cells" do
      buffer = ScreenBuffer.new(10, 5)

      assert Enum.all?(buffer.cells, fn row ->
               Enum.all?(row, fn cell -> Cell.get_char(cell) == " " end)
             end)
    end

    # The grid is allocated up front, so an unchecked size is the memory: a
    # remote client's 100000x100000 pty-req asked for ~5.4 TB.
    test "clamps the grid to the terminal size ceiling" do
      buffer = ScreenBuffer.new(100_000, 100_000)

      assert {buffer.width, buffer.height} == {4096, 256}
      assert length(buffer.cells) == 256
      assert Enum.all?(buffer.cells, &(length(&1) == 4096))
    end

    test "keeps a size at the ceiling" do
      buffer = ScreenBuffer.new(1024, 1024)

      assert {buffer.width, buffer.height} == {1024, 1024}
      assert length(buffer.cells) == 1024
    end
  end

  describe "character writing" do
    test ~c"writes a single character" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "A")
      assert Cell.get_char(Enum.at(buffer.cells, 0) |> Enum.at(0)) == "A"
    end

    test ~c"writes a wide character" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "中")
      assert Cell.get_char(Enum.at(buffer.cells, 0) |> Enum.at(0)) == "中"
      assert Cell.get_char(Enum.at(buffer.cells, 0) |> Enum.at(1)) == " "
    end

    test ~c"writes a string" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Hello")
      first_row = Enum.at(buffer.cells, 0)

      assert Enum.map(Enum.take(first_row, 5), &Cell.get_char/1) == [
               "H",
               "e",
               "l",
               "l",
               "o"
             ]
    end

    test ~c"writes a string with wide characters" do
      buffer = ScreenBuffer.new(10, 1)
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Hi 中国")
      first_row = ScreenBuffer.get_line(buffer, 0)

      # Wide characters take up two cells
      assert Enum.map(Enum.take(first_row, 6), &Cell.get_char/1) == [
               "H",
               "i",
               " ",
               "中",
               " ",
               "国"
             ]

      assert Enum.at(first_row, 4) |> Cell.get_char() == " "
      assert Enum.at(first_row, 3) |> Cell.get_char() == "中"
      assert Enum.at(first_row, 5) |> Cell.get_char() == "国"
    end
  end

  describe "scrolling" do
    test ~c"scrolling up moves lines correctly" do
      buffer = ScreenBuffer.new(10, 5)

      buffer =
        Enum.reduce(0..4, buffer, fn i, buf ->
          ScreenBuffer.write_string(buf, 0, i, "Line #{i}")
        end)

      {buffer, scrolled_lines} = ScreenBuffer.scroll_up(buffer, 2)

      assert length(scrolled_lines) == 2
      # Use helper for scrolled lines
      assert String.contains?(line_to_string(hd(scrolled_lines)), "Line 0")
      assert String.contains?(line_to_string(hd(tl(scrolled_lines))), "Line 1")

      # Use helper for remaining lines
      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 0)),
               "Line 2"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 1)),
               "Line 3"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 2)),
               "Line 4"
             )

      # Check for empty/whitespace line
      assert line_to_string(ScreenBuffer.get_line(buffer, 3)) =~ ~r/^\s*$/
      # Check for empty/whitespace line
      assert line_to_string(ScreenBuffer.get_line(buffer, 4)) =~ ~r/^\s*$/
    end

    test ~c"scrolling down inserts lines correctly (no scrollback)" do
      buffer = ScreenBuffer.new(10, 5)

      buffer =
        Enum.reduce(0..4, buffer, fn i, buf ->
          ScreenBuffer.write_string(buf, 0, i, "Line #{i}")
        end)

      buffer = ScreenBuffer.scroll_down(buffer, [], 2)

      # Use helper
      assert line_to_string(ScreenBuffer.get_line(buffer, 0)) =~ ~r/^\s*$/
      assert line_to_string(ScreenBuffer.get_line(buffer, 1)) =~ ~r/^\s*$/

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 2)),
               "Line 0"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 3)),
               "Line 1"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 4)),
               "Line 2"
             )
    end

    test ~c"scrolling scrolls up within scroll region" do
      buffer = ScreenBuffer.new(10, 5)

      buffer =
        Enum.reduce(0..4, buffer, fn i, buf ->
          ScreenBuffer.write_string(buf, 0, i, "Line #{i}")
        end)

      buffer = ScreenBuffer.set_scroll_region(buffer, 1, 3)

      {buffer, scrolled_lines} = ScreenBuffer.scroll_up(buffer, 1)

      assert length(scrolled_lines) == 1
      # Use helper
      assert String.contains?(line_to_string(hd(scrolled_lines)), "Line 1")

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 0)),
               "Line 0"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 4)),
               "Line 4"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 1)),
               "Line 2"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 2)),
               "Line 3"
             )

      assert line_to_string(ScreenBuffer.get_line(buffer, 3)) =~ ~r/^\s*$/
    end

    test ~c"scrolling scrolls down within scroll region" do
      buffer = ScreenBuffer.new(10, 5)

      buffer =
        Enum.reduce(0..4, buffer, fn i, buf ->
          ScreenBuffer.write_string(buf, 0, i, "Line #{i}")
        end)

      buffer = ScreenBuffer.set_scroll_region(buffer, 1, 3)

      buffer = ScreenBuffer.scroll_down(buffer, [], 1)

      # Use helper
      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 0)),
               "Line 0"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 4)),
               "Line 4"
             )

      assert line_to_string(ScreenBuffer.get_line(buffer, 1)) =~ ~r/^\s*$/

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 2)),
               "Line 1"
             )

      assert String.contains?(
               line_to_string(ScreenBuffer.get_line(buffer, 3)),
               "Line 2"
             )
    end

    # Add more tests for edge cases like scrolling by 0, scrolling full region, etc.
  end

  describe "selection" do
    test ~c"starts and updates selection" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.start_selection(buffer, 1, 1)
      assert buffer.selection == {1, 1, 1, 1}

      buffer = ScreenBuffer.update_selection(buffer, 3, 2)
      assert buffer.selection == {1, 1, 3, 2}
    end

    test ~c"gets selected text" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Hello")
      buffer = ScreenBuffer.write_string(buffer, 0, 1, "World")
      buffer = ScreenBuffer.start_selection(buffer, 0, 0)
      buffer = ScreenBuffer.update_selection(buffer, 4, 1)

      assert ScreenBuffer.get_selection(buffer) == "Hello\nWorld"
    end

    test ~c"checks if position is in selection" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.start_selection(buffer, 1, 1)
      buffer = ScreenBuffer.update_selection(buffer, 3, 2)

      assert ScreenBuffer.in_selection?(buffer, 2, 1)
      assert ScreenBuffer.in_selection?(buffer, 1, 2)
      refute ScreenBuffer.in_selection?(buffer, 0, 0)
      refute ScreenBuffer.in_selection?(buffer, 4, 3)
    end

    test ~c"gets selection boundaries" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.start_selection(buffer, 1, 1)
      buffer = ScreenBuffer.update_selection(buffer, 3, 2)

      assert ScreenBuffer.get_selection_boundaries(buffer) == {{1, 1}, {3, 2}}
    end
  end

  describe "scroll region" do
    test ~c"sets and clears scroll region" do
      buffer = ScreenBuffer.new(10, 5)
      buffer = ScreenBuffer.set_scroll_region(buffer, 1, 3)
      assert buffer.scroll_region == {1, 3}

      buffer = ScreenBuffer.clear_scroll_region(buffer)
      assert buffer.scroll_region == nil
    end

    test ~c"gets scroll region boundaries" do
      buffer = ScreenBuffer.new(10, 5)
      assert ScreenBuffer.get_scroll_region_boundaries(buffer) == {0, 4}

      buffer = ScreenBuffer.set_scroll_region(buffer, 1, 3)
      assert ScreenBuffer.get_scroll_region_boundaries(buffer) == {1, 3}
    end
  end

  describe "clearing" do
    test ~c"clears the screen buffer" do
      # Setup: Create a buffer and fill it
      initial_buffer = ScreenBuffer.new(10, 5)

      filled_buffer =
        Enum.reduce(0..4, initial_buffer, fn y, buf ->
          Enum.reduce(0..9, buf, fn x, buf ->
            # Use TextFormatting.new() for the default style here when writing
            ScreenBuffer.write_char(buf, x, y, "X", TextFormatting.new())
          end)
        end)

      # The action being tested: clear the buffer using the correct function and style
      default_style = TextFormatting.new()
      # Renamed clear_buffer -> clear and added style
      buffer = ScreenBuffer.clear(filled_buffer, default_style)

      # The assertion: check if the cleared buffer matches a newly created one's cells
      initial_cells = ScreenBuffer.new(10, 5).cells
      assert buffer.cells == initial_cells
    end

    # Maybe add a test specifically for Eraser.clear_screen if direct testing is desired
    # test 'Eraser.clear_screen resets cells' do ... end
  end

  describe "resize" do
    test ~c"clears selection and scroll region after resizing" do
      buffer = ScreenBuffer.new(10, 5)
      # Set a selection
      buffer = ScreenBuffer.start_selection(buffer, 1, 1)
      buffer = ScreenBuffer.update_selection(buffer, 3, 2)
      assert buffer.selection == {1, 1, 3, 2}
      # Set a scroll region
      buffer = ScreenBuffer.set_scroll_region(buffer, 1, 3)
      assert buffer.scroll_region == {1, 3}

      # Resize the buffer
      buffer = ScreenBuffer.resize(buffer, 8, 4)

      # Both selection and scroll_region should be cleared
      assert buffer.selection == nil
      assert buffer.scroll_region == nil
    end

    test ~c"clamps the new grid to the terminal size ceiling" do
      buffer = ScreenBuffer.write_string(ScreenBuffer.new(10, 5), 0, 0, "hi")
      buffer = ScreenBuffer.resize(buffer, 100_000, 100_000)

      assert {buffer.width, buffer.height} == {4096, 256}
      assert length(buffer.cells) == 256
      assert Enum.all?(buffer.cells, &(length(&1) == 4096))
      assert ScreenBuffer.get_char(buffer, 1, 0) == "i"
    end
  end
end
