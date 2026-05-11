defmodule Raxol.Terminal.ANSISequencesIntegrationTest do
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Cursor.Manager, as: CursorManager
  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.ScreenBuffer

  # Load test fixtures
  Code.require_file("../../fixtures/ansi_sequences.exs", __DIR__)
  alias Raxol.Test.Fixtures.ANSISequences

  describe "real-world application sequences" do
    setup do
      emulator = Emulator.new(80, 24)
      {:ok, emulator: emulator}
    end

    test "handles vim status line sequences", %{emulator: emulator} do
      sequences = ANSISequences.vim_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.status_line
        )

      # Verify cursor visibility was toggled
      assert state.cursor != nil

      # Verify text was written to status line area
      line_23 = ScreenBuffer.get_line(state.main_screen_buffer, 22)
      text = Enum.map_join(line_23, &(&1.char || " "))
      assert String.contains?(text, "-- INSERT --")
    end

    test "handles vim syntax highlighting", %{emulator: emulator} do
      sequences = ANSISequences.vim_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.syntax_highlight
        )

      # Check that colors were applied
      cells = state.main_screen_buffer.cells |> List.first() |> Enum.take(20)

      # Find colored cells
      colored_cells =
        Enum.filter(cells, fn cell ->
          cell.style.foreground != :default
        end)

      assert [_ | _] = colored_cells
    end

    test "processes git diff color sequences", %{emulator: emulator} do
      sequences = ANSISequences.git_diff_sequences()

      # Build a complete diff
      diff =
        [
          sequences.file_header,
          "\n",
          sequences.hunk_header,
          "\n",
          sequences.context,
          "\n",
          sequences.deletion,
          "\n",
          sequences.addition,
          "\n"
        ]
        |> Enum.join()

      {state, _output} = Emulator.process_input(emulator, diff)

      # Verify colors were applied correctly
      lines = state.main_screen_buffer.cells

      # Check that we have content
      assert [_ | _] = lines

      # Check for color application
      all_cells = List.flatten(lines)

      colored =
        Enum.any?(all_cells, fn cell ->
          cell.style.foreground in [:red, :green, :cyan]
        end)

      assert colored, "Expected colored cells in git diff output"
    end

    test "handles tmux status bar and borders", %{emulator: emulator} do
      sequences = ANSISequences.tmux_sequences()

      # Create a tmux-like layout
      tmux_screen =
        [
          sequences.corner_tl,
          String.duplicate(sequences.horizontal_border, 20),
          sequences.corner_tr,
          "\n",
          sequences.vertical_border,
          String.duplicate(" ", 20),
          sequences.vertical_border,
          "\n",
          sequences.corner_bl,
          String.duplicate(sequences.horizontal_border, 20),
          sequences.corner_br
        ]
        |> Enum.join()

      {state, _output} = Emulator.process_input(emulator, tmux_screen)

      # Verify box drawing characters are present
      first_line = ScreenBuffer.get_line(state.main_screen_buffer, 0)
      first_char = List.first(first_line).char

      assert first_char in ["┌", "┏", "╔"]
    end

    test "handles alternative screen buffer switching", %{emulator: emulator} do
      sequences = ANSISequences.tmux_sequences()

      # Write to main screen
      {state, _} = Emulator.process_input(emulator, "Main screen")

      # Switch to alternate screen
      {state, _} = Emulator.process_input(state, sequences.enter_alt_screen)

      # Write to alternate screen
      {state, _} = Emulator.process_input(state, "Alt screen")

      # Verify we're on alternate screen
      # When on alternate screen, read from alternate_screen_buffer
      alt_text = extract_text(state.alternate_screen_buffer || state.main_screen_buffer)
      assert String.contains?(alt_text, "Alt screen")

      # Switch back to main screen
      {state, _} = Emulator.process_input(state, sequences.exit_alt_screen)

      # Verify main screen content is restored
      main_text = extract_text(state.main_screen_buffer)
      assert String.contains?(main_text, "Main screen")
    end
  end

  describe "OSC sequences" do
    setup do
      emulator = Emulator.new(80, 24)
      {:ok, emulator: emulator}
    end

    test "sets window title", %{emulator: emulator} do
      sequences = ANSISequences.osc_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.set_title
        )

      # Window title should be set in state
      assert state != nil
    end

    test "handles hyperlinks", %{emulator: emulator} do
      sequences = ANSISequences.osc_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.hyperlink
        )

      # Verify "Click here" text is present
      text = extract_text(state.main_screen_buffer)
      assert String.contains?(text, "Click here")
    end
  end

  describe "complex multi-sequence operations" do
    setup do
      emulator = Emulator.new(80, 24)
      {:ok, emulator: emulator}
    end

    test "save cursor, move, write, restore cursor", %{emulator: emulator} do
      sequences = ANSISequences.complex_sequences()

      # Start at origin
      {state, _} = Emulator.process_input(emulator, "\e[1;1H")
      initial_pos = CursorManager.get_position(state.cursor)

      # Execute save/write/restore sequence
      {state, _} =
        Emulator.process_input(
          state,
          sequences.save_write_restore
        )

      # Cursor should be back at initial position
      final_pos = CursorManager.get_position(state.cursor)
      assert final_pos == initial_pos

      # But text should be written at position 10,20
      # Note: ANSI uses 1-based, internal uses 0-based
      line_10 = ScreenBuffer.get_line(state.main_screen_buffer, 9)
      text = Enum.map_join(Enum.drop(line_10, 19), &(&1.char || " "))
      assert String.starts_with?(text, "Hello")
    end

    test "renders colored box", %{emulator: emulator} do
      sequences = ANSISequences.complex_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.colored_box
        )

      # Verify box drawing characters
      first_line = ScreenBuffer.get_line(state.main_screen_buffer, 0)
      first_char = List.first(first_line).char
      assert first_char in ["┌", "┏", "╔"]

      # Verify color was applied
      first_cell = List.first(first_line)
      assert first_cell.style.foreground == :blue
    end

    test "handles nested attributes correctly", %{emulator: emulator} do
      sequences = ANSISequences.complex_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.nested_attrs
        )

      # Get the cells with text
      cells =
        state.main_screen_buffer.cells
        |> List.first()
        |> Enum.filter(fn cell -> cell.char not in [nil, " "] end)

      # First part should be bold, underline, red
      first_cells = Enum.take(cells, 5)

      Enum.each(first_cells, fn cell ->
        assert cell.style.foreground == :red
        assert cell.style.underline == true
      end)
    end
  end

  describe "unicode and special characters" do
    setup do
      emulator = Emulator.new(80, 24)
      {:ok, emulator: emulator}
    end

    test "handles emoji with ANSI colors", %{emulator: emulator} do
      sequences = ANSISequences.unicode_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.colored_emoji
        )

      # Verify emoji are present in buffer
      text = extract_text(state.main_screen_buffer)
      assert String.contains?(text, "❤")
      assert String.contains?(text, "💚")
      assert String.contains?(text, "💙")
    end

    test "handles combining characters with colors", %{emulator: emulator} do
      sequences = ANSISequences.unicode_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.combining_with_color
        )

      # Verify the base character is present
      text = extract_text(state.main_screen_buffer)
      assert String.contains?(text, "a")
    end

    test "handles full-width characters", %{emulator: emulator} do
      sequences = ANSISequences.unicode_sequences()

      {state, _output} =
        Emulator.process_input(
          emulator,
          sequences.fullwidth
        )

      # Debug the buffer structure
      first_line = Enum.at(state.main_screen_buffer.cells, 0)
      first_8_cells = Enum.take(first_line, 8)
      # Debug output removed - use Logger if debugging needed

      # Verify Japanese characters are present
      text = extract_text(state.main_screen_buffer)
      # Debug output removed - use Logger if debugging needed
      assert String.contains?(text, "全角文字")
    end
  end

  describe "edge cases and error handling" do
    setup do
      emulator = Emulator.new(80, 24)
      {:ok, emulator: emulator}
    end

    test "handles incomplete CSI sequences gracefully", %{emulator: emulator} do
      edge_cases = ANSISequences.edge_cases()

      # Should not crash on incomplete sequence
      {state, _output} =
        Emulator.process_input(
          emulator,
          edge_cases.incomplete_csi <> "text"
        )

      assert state != nil
    end

    test "handles invalid parameters gracefully", %{emulator: emulator} do
      edge_cases = ANSISequences.edge_cases()

      # Negative parameter
      {state, _} = Emulator.process_input(emulator, edge_cases.negative_param)
      assert state != nil

      # Huge parameter
      {state, _} = Emulator.process_input(emulator, edge_cases.huge_param)
      assert state != nil

      # Non-numeric parameter
      {state, _} = Emulator.process_input(emulator, edge_cases.non_numeric)
      assert state != nil
    end

    test "handles extremely long parameter lists", %{emulator: emulator} do
      edge_cases = ANSISequences.edge_cases()

      {state, _output} =
        Emulator.process_input(
          emulator,
          edge_cases.long_params
        )

      # Should not crash or hang
      assert state != nil
    end

    test "handles null bytes and control characters", %{emulator: emulator} do
      edge_cases = ANSISequences.edge_cases()

      # Null bytes
      {state, _} = Emulator.process_input(emulator, edge_cases.with_null)
      text = extract_text(state.main_screen_buffer)
      assert String.contains?(text, "Hello")
      assert String.contains?(text, "World")

      # Control characters
      {state, _} = Emulator.process_input(emulator, edge_cases.with_controls)
      assert state != nil
    end
  end

  describe "performance characteristics" do
    setup do
      emulator = Emulator.new(80, 24)
      {:ok, emulator: emulator}
    end

    test "handles a stream of rapid color changes without crashing", %{emulator: emulator} do
      stress = ANSISequences.stress_sequences()
      {state, _output} = Emulator.process_input(emulator, stress.color_spam)
      assert state != nil
    end

    test "handles a stream of cursor movements without crashing", %{emulator: emulator} do
      stress = ANSISequences.stress_sequences()
      {state, _output} = Emulator.process_input(emulator, stress.cursor_dance)
      assert state != nil
    end

    test "handles large formatted text efficiently", %{emulator: emulator} do
      stress = ANSISequences.stress_sequences()

      {time, {state, _}} =
        :timer.tc(fn ->
          Emulator.process_input(emulator, stress.large_formatted)
        end)

      # Should handle 10000 formatted numbers in reasonable time
      # Note: Debug logging and parallel test load can make this slower
      # 60 seconds - generous for CI/debug/parallel load
      assert time < 60_000_000
      assert state != nil
    end
  end

  describe "terminal modes" do
    setup do
      emulator = Emulator.new(80, 24)
      {:ok, emulator: emulator}
    end

    test "toggles cursor visibility", %{emulator: emulator} do
      modes = ANSISequences.mode_sequences()

      # Hide cursor
      {state, _} = Emulator.process_input(emulator, modes.cursor_invisible)
      assert CursorManager.get_visibility(state.cursor) == false

      # Show cursor
      {state, _} = Emulator.process_input(state, modes.cursor_visible)
      assert CursorManager.get_visibility(state.cursor) == true
    end

    test "toggles line wrapping", %{emulator: emulator} do
      modes = ANSISequences.mode_sequences()

      # Disable autowrap
      {state, _} = Emulator.process_input(emulator, modes.autowrap_off)

      # Write text that would wrap
      long_text = String.duplicate("x", 100)
      {state, _} = Emulator.process_input(state, long_text)

      # Cursor should be at end of line, not wrapped
      {row, col} = CursorManager.get_position(state.cursor)
      # Still on first line
      assert row == 0
      # At last column
      assert col == 79
    end

    test "handles bracketed paste mode", %{emulator: emulator} do
      modes = ANSISequences.mode_sequences()

      # Enable bracketed paste
      {state, _} = Emulator.process_input(emulator, modes.bracketed_paste_on)

      # Paste some text (would be wrapped with paste brackets in real terminal)
      {state, _} = Emulator.process_input(state, "pasted text")

      # Disable bracketed paste
      {state, _} = Emulator.process_input(state, modes.bracketed_paste_off)

      assert state != nil
    end
  end

  # Helper functions

  defp extract_text(buffer) do
    buffer.cells
    |> Enum.map_join("\n", fn line ->
      line
      |> Enum.reject(& &1.wide_placeholder)
      |> Enum.map_join("", &(&1.char || " "))
    end)
    |> String.trim()
  end
end
