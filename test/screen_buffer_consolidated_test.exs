defmodule ScreenBufferTest do
  use ExUnit.Case
  doctest Raxol.Terminal.ScreenBuffer.Core

  alias Raxol.Terminal.Cell

  alias Raxol.Terminal.ScreenBuffer.{
    Attributes,
    Core,
    Manager,
    Operations,
    ScrollOps,
    Selection
  }

  describe "Core module" do
    test "creates a buffer with correct dimensions" do
      buffer = Core.new(80, 24)
      assert buffer.width == 80
      assert buffer.height == 24
      assert length(buffer.cells) == 24
      assert length(hd(buffer.cells)) == 80
    end

    test "gets cell from buffer" do
      buffer = Core.new(10, 10)
      cell = Core.get_cell(buffer, 5, 5)
      assert %Cell{} = cell
    end

    test "gets character from buffer" do
      buffer = Core.new(10, 10)
      char = Core.get_char(buffer, 5, 5)
      assert is_binary(char)
    end

    test "resizes buffer correctly" do
      buffer = Core.new(10, 10)
      resized = Core.resize(buffer, 15, 15)
      assert resized.width == 15
      assert resized.height == 15
      assert length(resized.cells) == 15
      assert length(hd(resized.cells)) == 15
    end

    test "clears buffer" do
      buffer = Core.new(10, 10)
      cleared = Core.clear(buffer)
      assert cleared.width == 10
      assert cleared.height == 10
      # All cells should be empty
      cell = Core.get_cell(cleared, 0, 0)
      assert cell.char == " "
    end
  end

  describe "Operations module" do
    test "writes character to buffer" do
      buffer = Core.new(10, 10)
      updated = Operations.write_char(buffer, 5, 5, "A")
      cell = Core.get_cell(updated, 5, 5)
      assert cell.char == "A"
    end

    test "writes text to buffer" do
      buffer = Core.new(10, 10)
      updated = Operations.write_text(buffer, 0, 0, "Hello")

      assert Core.get_char(updated, 0, 0) == "H"
      assert Core.get_char(updated, 1, 0) == "e"
      assert Core.get_char(updated, 2, 0) == "l"
      assert Core.get_char(updated, 3, 0) == "l"
      assert Core.get_char(updated, 4, 0) == "o"
    end

    test "puts line correctly" do
      buffer = Core.new(10, 10)
      line = for _ <- 1..10, do: Cell.new("X")
      updated = Operations.put_line(buffer, 5, line)

      # Check that line 5 has all X's
      for x <- 0..9 do
        assert Core.get_char(updated, x, 5) == "X"
      end
    end

    test "clear line operation" do
      buffer = Core.new(10, 10)
      # Write some text first
      buffer = Operations.write_text(buffer, 0, 5, "Test line")
      # Clear the line
      cleared = Operations.clear_line(buffer, 5)

      # Check that line 5 is cleared
      for x <- 0..9 do
        assert Core.get_char(cleared, x, 5) == " "
      end
    end
  end

  describe "Scroll module" do
    test "scrolls up correctly" do
      buffer = Core.new(10, 10)
      # Fill buffer with identifiable content
      buffer =
        Enum.reduce(0..9, buffer, fn y, acc ->
          line = for _ <- 0..9, do: Cell.new(Integer.to_string(y))
          Operations.put_line(acc, y, line)
        end)

      # Scroll up by 1 line (returns {buffer, scrolled_out})
      {scrolled, _scrolled_out} = ScrollOps.scroll_up(buffer, 1)

      # Line 0 should now have content from line 1 (which was "1")
      assert Core.get_char(scrolled, 0, 0) == "1"
      # Last line should be empty
      assert Core.get_char(scrolled, 0, 9) == " "
    end

    test "scrolls down correctly" do
      buffer = Core.new(10, 10)
      # Fill buffer with identifiable content
      buffer =
        Enum.reduce(0..9, buffer, fn y, acc ->
          line = for _ <- 0..9, do: Cell.new(Integer.to_string(y))
          Operations.put_line(acc, y, line)
        end)

      # Scroll down by 1 line
      scrolled = ScrollOps.scroll_down(buffer, 1)

      # Line 1 should now have content from line 0 (which was "0")
      assert Core.get_char(scrolled, 0, 1) == "0"
      # First line should be empty
      assert Core.get_char(scrolled, 0, 0) == " "
    end

    test "manages scrollback" do
      # scrollback limit of 5
      buffer = Core.new(10, 10, 5)
      # Add some lines to scrollback
      line1 = for _ <- 0..9, do: Cell.new("1")
      line2 = for _ <- 0..9, do: Cell.new("2")

      scrollback = buffer.scrollback
      buffer = %{buffer | scrollback: [line1 | scrollback]}
      buffer = %{buffer | scrollback: [line2 | buffer.scrollback]}

      assert length(buffer.scrollback) == 2
    end
  end

  describe "Selection module" do
    test "starts and manages selection" do
      buffer = Core.new(10, 10)

      # Start selection
      buffer = Selection.start_selection(buffer, 2, 3)
      selection = Selection.get_selection(buffer)
      assert selection == {2, 3, 2, 3}

      # Extend selection
      buffer = Selection.extend_selection(buffer, 5, 6)
      selection = Selection.get_selection(buffer)
      assert selection == {2, 3, 5, 6}

      # Clear selection
      buffer = Selection.clear_selection(buffer)
      assert Selection.get_selection(buffer) == nil
    end

    test "extracts selected text" do
      buffer = Core.new(10, 10)
      # Write some text
      buffer = Operations.write_text(buffer, 0, 0, "Hello World")

      # Select part of it
      buffer = Selection.start_selection(buffer, 0, 0)
      buffer = Selection.extend_selection(buffer, 4, 0)

      selected_text = Selection.get_selected_text(buffer)
      assert selected_text == "Hello"
    end
  end

  describe "Attributes module" do
    test "manages cursor position" do
      buffer = Core.new(10, 10)

      # Set cursor position
      buffer = Attributes.set_cursor_position(buffer, 5, 7)
      {x, y} = Attributes.get_cursor_position(buffer)
      assert x == 5
      assert y == 7

      # Move cursor relative
      buffer = Attributes.move_cursor(buffer, 2, -1)
      {x, y} = Attributes.get_cursor_position(buffer)
      assert x == 7
      assert y == 6
    end

    test "manages cursor visibility and style" do
      buffer = Core.new(10, 10)

      # Set cursor visible
      buffer = Attributes.set_cursor_visible(buffer, false)
      assert !buffer.cursor_visible

      # Set cursor style
      buffer = Attributes.set_cursor_style(buffer, :underline)
      assert buffer.cursor_style == :underline
    end

    test "manages default style" do
      buffer = Core.new(10, 10)
      style = %{color: :red, background: :blue}

      buffer = Attributes.set_default_style(buffer, style)
      assert Attributes.get_default_style(buffer) == style
    end
  end

  describe "Manager module" do
    test "creates buffer manager with main and alternate buffers" do
      manager = Manager.new(80, 24)
      assert %Manager{} = manager
      assert manager.main_buffer.width == 80
      assert manager.main_buffer.height == 24
      assert manager.alternate_buffer.width == 80
      assert manager.alternate_buffer.height == 24
      assert manager.active_buffer_type == :main
    end

    test "switches between main and alternate buffers" do
      manager = Manager.new(80, 24)

      # Switch to alternate
      manager = Manager.switch_to_alternate(manager)
      assert manager.active_buffer_type == :alternate

      # Switch back to main
      manager = Manager.switch_to_main(manager)
      assert manager.active_buffer_type == :main
    end

    test "gets active buffer" do
      manager = Manager.new(80, 24)
      active = Manager.get_active_buffer(manager)
      assert active == manager.main_buffer

      manager = Manager.switch_to_alternate(manager)
      active = Manager.get_active_buffer(manager)
      assert active == manager.alternate_buffer
    end

    test "tracks memory usage" do
      manager = Manager.new(80, 24)
      usage = Manager.get_memory_usage(manager)
      assert is_integer(usage)
      assert usage > 0
    end

    test "tracks metrics" do
      manager = Manager.new(80, 24)
      metrics = Manager.get_metrics(manager)
      assert is_map(metrics)
      assert Map.has_key?(metrics, :writes)
      assert Map.has_key?(metrics, :scrolls)
    end
  end

  describe "Integration test" do
    test "full workflow works correctly" do
      # Create buffer manager
      manager = Manager.new(80, 24)

      # Get active buffer
      buffer = Manager.get_active_buffer(manager)

      # Write some text
      buffer = Operations.write_text(buffer, 0, 0, "Hello, World!")

      # Verify text was written
      assert Core.get_char(buffer, 0, 0) == "H"
      assert Core.get_char(buffer, 7, 0) == "W"

      # Start selection
      buffer = Selection.start_selection(buffer, 0, 0)
      buffer = Selection.extend_selection(buffer, 4, 0)

      # Get selected text
      selected = Selection.get_selected_text(buffer)
      assert selected == "Hello"

      # Move cursor
      buffer = Attributes.set_cursor_position(buffer, 10, 5)
      {x, y} = Attributes.get_cursor_position(buffer)
      assert x == 10
      assert y == 5

      # Scroll the buffer
      {buffer, _} = ScrollOps.scroll_up(buffer, 2)

      # Text should have moved up
      # Original line scrolled up
      assert Core.get_char(buffer, 0, 0) == " "

      # Update manager with modified buffer
      manager = Manager.update_active_buffer(manager, buffer)
      updated_buffer = Manager.get_active_buffer(manager)
      assert updated_buffer == buffer
    end
  end
end
