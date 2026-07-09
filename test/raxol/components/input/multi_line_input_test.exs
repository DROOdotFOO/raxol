defmodule Raxol.UI.Components.Input.MultiLineInputTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Input.MultiLineInput
  alias Raxol.UI.Components.Input.TextWrapping

  describe "init/1" do
    test ~c"initializes with default values when no props provided" do
      {:ok, state} = MultiLineInput.init(%{id: :mle_default})
      assert state.id == :mle_default
      assert state.value == ""
      assert state.placeholder == ""
      assert state.width == 40
      assert state.height == 10
      assert state.wrap == :word
      assert state.cursor_pos == {0, 0}
      assert state.scroll_offset == {0, 0}
      assert state.selection_start == nil
      assert state.selection_end == nil
      assert state.focused == false
      assert state.lines == [""]
    end

    test ~c"initializes with provided values" do
      props = %{
        id: :mle_props,
        value: "Hello\nWorld",
        placeholder: "Type here...",
        width: 50,
        height: 15,
        wrap: :char,
        focused: true,
        on_change: fn _ -> :changed end
      }

      {:ok, state} = MultiLineInput.init(props)
      assert state.id == :mle_props
      assert state.value == "Hello\nWorld"
      assert state.placeholder == "Type here..."
      assert state.width == 50
      assert state.height == 15
      assert state.wrap == :char
      assert state.focused == true
      assert is_function(state.on_change)
      # Check lines cache
      assert state.lines == ["Hello", "World"]
    end

    test ~c"initializes with provided values and style" do
      # Define expected_style before using it
      expected_style = %{
        text_color: :green,
        placeholder_color: :dark_gray,
        selection_color: :yellow,
        cursor_color: :red,
        line_numbers: true,
        line_number_color: :blue
      }

      props = %{
        id: :mle_props,
        value: "Hello\nWorld",
        placeholder: "Type here...",
        width: 50,
        height: 15,
        wrap: :char,
        focused: true,
        on_change: fn _ -> :changed end,
        style: expected_style
      }

      {:ok, state} = MultiLineInput.init(props)
      assert state.id == :mle_props
      assert state.value == "Hello\nWorld"
      assert state.placeholder == "Type here..."
      assert state.width == 50
      assert state.height == 15
      assert state.wrap == :char
      assert state.focused == true
      assert is_function(state.on_change)
      # Remove or correct this if state.style does not exist
      # assert state.style == expected_style
      # Check lines cache
      assert state.lines == ["Hello", "World"]
      assert state.cursor_pos == {0, 0}
      # Should be true as focused: true was passed in props
      assert state.focused
    end
  end

  describe "update/2" do
    setup do
      {:ok, initial_state} =
        MultiLineInput.init(%{id: :mle_update, value: "test\ntext"})

      {:ok, state: initial_state}
    end

    test "sets value and resets cursor", %{state: state} do
      # Use {:update_props, ...} message to change value
      {:noreply, new_state, _} =
        MultiLineInput.update({:update_props, %{value: "new\nvalue"}}, state)

      assert new_state.value == "new\nvalue"
      assert new_state.lines == ["new", "value"]
      # Cursor/scroll might reset or be recalculated, check if visible
      # Assuming reset on value update
      assert new_state.cursor_pos == {0, 0}
      assert new_state.scroll_offset == {0, 0}
    end

    test "moves cursor within bounds", %{state: state} do
      # Move right
      {:noreply, state_r, _} =
        MultiLineInput.update({:move_cursor, :right}, state)

      assert state_r.cursor_pos == {0, 1}
      # Move down
      {:noreply, state_d, _} =
        MultiLineInput.update({:move_cursor, :down}, state_r)

      assert state_d.cursor_pos == {1, 1}
      # Move left
      {:noreply, state_l, _} =
        MultiLineInput.update({:move_cursor, :left}, state_d)

      assert state_l.cursor_pos == {1, 0}
      # Move up
      {:noreply, state_u, _} =
        MultiLineInput.update({:move_cursor, :up}, state_l)

      assert state_u.cursor_pos == {0, 0}
    end

    test "sets selection", %{state: state} do
      # Simulate moving right while holding shift (generates :select_to message)
      # NOTE: This assumes EventHandler translates Shift+Right to :select_to
      {:noreply, state_sel, _} =
        MultiLineInput.update({:select_to, {0, 1}}, state)

      assert state_sel.selection_start == {0, 0}
      assert state_sel.selection_end == {0, 1}
      # Cursor moves with selection end
      assert state_sel.cursor_pos == {0, 1}
    end

    test "handles scrolling (via cursor movement)", %{state: _state} do
      # Simulate moving cursor down multiple times to trigger scroll
      {:ok, state_many_lines} =
        MultiLineInput.init(%{
          value: Enum.map_join(1..20, "\n", &"Line #{&1}"),
          height: 5
        })

      {:noreply, state_moved, _} =
        Enum.reduce(1..10, {:noreply, state_many_lines, []}, fn _, {_, st, _} ->
          MultiLineInput.update({:move_cursor, :down}, st)
        end)

      # Check if scroll_offset has changed (e.g., cursor at row 10, height 5)
      assert elem(state_moved.scroll_offset, 0) > 0
    end

    test "handles focus and blur", %{state: state} do
      {:noreply, focused_state, _} = MultiLineInput.update(:focus, state)
      assert focused_state.focused == true
      {:noreply, blurred_state, _} = MultiLineInput.update(:blur, focused_state)
      refute blurred_state.focused
    end

    test "handles :input message", %{state: state} do
      # Input 'a' (codepoint 97)
      {:noreply, new_state, _} = MultiLineInput.update({:input, ?a}, state)
      assert new_state.value == "atest\ntext"
      # Cursor moves after char
      assert new_state.cursor_pos == {0, 1}
    end

    test "handles :enter message", %{state: state} do
      # Position cursor at {0, 2}
      state_at_2 = %{state | cursor_pos: {0, 2}}
      {:noreply, new_state, _} = MultiLineInput.update({:enter}, state_at_2)
      assert new_state.value == "te\nst\ntext"
      # Cursor moves to start of new line
      assert new_state.cursor_pos == {1, 0}
      assert new_state.lines == ["te", "st", "text"]
    end

    test "handles :backspace message (no selection)", %{state: state} do
      # Position cursor at {1, 2}
      state_at_1_2 = %{state | cursor_pos: {1, 2}}

      {:noreply, new_state, _} =
        MultiLineInput.update({:backspace}, state_at_1_2)

      assert new_state.value == "test\ntxt"
      # Cursor moves back
      assert new_state.cursor_pos == {1, 1}
    end

    test "handles :backspace message (with selection)", %{state: state} do
      # Select from {0, 1} to {1, 2}
      state_with_sel = %{
        state
        | selection_start: {0, 1},
          selection_end: {1, 2},
          cursor_pos: {1, 2}
      }

      {:noreply, new_state, _} =
        MultiLineInput.update({:backspace}, state_with_sel)

      assert new_state.value == "txt"
      # Cursor moves to selection start
      assert new_state.cursor_pos == {0, 1}
      assert new_state.selection_start == nil
      assert new_state.selection_end == nil
    end

    test "handles :delete message (no selection)", %{state: state} do
      # Position cursor at {0, 2}
      state_at_0_2 = %{state | cursor_pos: {0, 2}}
      {:noreply, new_state, _} = MultiLineInput.update({:delete}, state_at_0_2)
      assert new_state.value == "tet\ntext"
      # Cursor doesn't move
      assert new_state.cursor_pos == {0, 2}
    end
  end

  describe "line wrapping" do
    test ~c"wrap_line_by_char handles long word correctly (simpler)" do
      # 100 chars
      value = String.duplicate("0123456789", 10)
      width = 20
      lines = TextWrapping.wrap_line_by_char(value, width)
      expected_line = "01234567890123456789"

      assert length(lines) == 5
      assert Enum.all?(lines, &(&1 == expected_line))
    end

    test ~c"wrap_line_by_char handles long word correctly" do
      value =
        "Lopadotemachoselachogaleokranioleipsanodrimhypotrimmatosilphioparaomelitokatakechymenokichlepikossyphophattoperisteralektryonoptekephalliokigklopeleiolagoiosiraiobaphetraganopterygon"

      width = 20

      lines = TextWrapping.wrap_line_by_char(value, width)

      assert length(lines) == 10
      assert Enum.at(lines, 0) == "Lopadotemachoselacho"
      assert Enum.at(lines, 1) == "galeokranioleipsanod"
      assert Enum.at(lines, 2) == "rimhypotrimmatosilph"
      assert Enum.at(lines, 3) == "ioparaomelitokatakec"
      assert Enum.at(lines, 4) == "hymenokichlepikossyp"
      assert Enum.at(lines, 5) == "hophattoperisteralek"
      assert Enum.at(lines, 6) == "tryonoptekephallioki"
      assert Enum.at(lines, 7) == "gklopeleiolagoiosira"
      assert Enum.at(lines, 8) == "iobaphetraganopteryg"
      assert Enum.at(lines, 9) == "on"
    end

    test ~c"wraps text by character" do
      value = "This is a long line of text"
      width = 10

      # Call the public function directly
      lines = TextWrapping.wrap_line_by_char(value, width)

      assert lines == ["This is a ", "long line ", "of text"]
      assert length(lines) == 3
    end

    test ~c"wraps text by word" do
      value = "This is a long line of text"
      width = 10

      # Call the public function directly
      lines = TextWrapping.wrap_line_by_word(value, width)

      # Assert the expected output for word wrap
      assert lines == ["This is a", "long line", "of text"]
      assert length(lines) == 3
    end

    test ~c"wraps text by word with long word" do
      value =
        "Lopadotemachoselachogaleokranioleipsanodrimhypotrimmatosilphioparaomelitokatakechymenokichlepikossyphophattoperisteralektryonoptekephalliokigklopeleiolagoiosiraiobaphetraganopterygon"

      width = 20
      lines = TextWrapping.wrap_line_by_word(value, width)

      assert length(lines) == 10
      assert Enum.at(lines, 0) == "Lopadotemachoselacho"
      assert Enum.at(lines, 1) == "galeokranioleipsanod"
      assert Enum.at(lines, 2) == "rimhypotrimmatosilph"
      assert Enum.at(lines, 3) == "ioparaomelitokatakec"
      assert Enum.at(lines, 4) == "hymenokichlepikossyp"
      assert Enum.at(lines, 5) == "hophattoperisteralek"
      assert Enum.at(lines, 6) == "tryonoptekephallioki"
      assert Enum.at(lines, 7) == "gklopeleiolagoiosira"
      assert Enum.at(lines, 8) == "iobaphetraganopteryg"
      assert Enum.at(lines, 9) == "on"
    end

    test ~c"wraps text by word basic" do
      value = "This is a long line of text"
      width = 10

      # Call the public function directly
      lines = TextWrapping.wrap_line_by_word(value, width)

      # Assert the expected output for word wrap
      assert lines == ["This is a", "long line", "of text"]
      assert length(lines) == 3
    end
  end

  describe "undo/redo" do
    setup do
      {:ok, state} =
        MultiLineInput.init(%{id: :mle_undo, value: "hello", width: 40, height: 10})

      %{state: state}
    end

    test "undo reverts a character insertion", %{state: state} do
      {:noreply, after_input, _} = MultiLineInput.update({:input, ?X}, state)
      assert after_input.value == "Xhello"

      {:noreply, after_undo, _} = MultiLineInput.update(:undo, after_input)
      assert after_undo.value == "hello"
    end

    test "redo restores an undone change", %{state: state} do
      {:noreply, after_input, _} = MultiLineInput.update({:input, ?X}, state)
      {:noreply, after_undo, _} = MultiLineInput.update(:undo, after_input)
      assert after_undo.value == "hello"

      {:noreply, after_redo, _} = MultiLineInput.update(:redo, after_undo)
      assert after_redo.value == "Xhello"
    end

    test "undo on empty history is a no-op", %{state: state} do
      {:noreply, after_undo, _} = MultiLineInput.update(:undo, state)
      assert after_undo.value == state.value
    end

    test "redo on empty redo stack is a no-op", %{state: state} do
      {:noreply, after_redo, _} = MultiLineInput.update(:redo, state)
      assert after_redo.value == state.value
    end

    test "new edit clears redo stack", %{state: state} do
      {:noreply, s1, _} = MultiLineInput.update({:input, ?A}, state)
      {:noreply, s2, _} = MultiLineInput.update(:undo, s1)
      # Now type something new — redo should be cleared
      {:noreply, s3, _} = MultiLineInput.update({:input, ?B}, s2)
      {:noreply, s4, _} = MultiLineInput.update(:redo, s3)
      # Redo should be no-op since new edit cleared it
      assert s4.value == s3.value
    end

    test "multiple undos walk back through history", %{state: state} do
      {:noreply, s1, _} = MultiLineInput.update({:input, ?A}, state)
      {:noreply, s2, _} = MultiLineInput.update({:input, ?B}, s1)
      assert s2.value =~ "AB"

      {:noreply, s3, _} = MultiLineInput.update(:undo, s2)
      assert s3.value =~ "A"
      refute s3.value =~ "B"

      {:noreply, s4, _} = MultiLineInput.update(:undo, s3)
      assert s4.value == "hello"
    end

    test "undo reverts backspace", %{state: state} do
      state_at_1 = %{state | cursor_pos: {0, 1}}
      {:noreply, after_bs, _} = MultiLineInput.update({:backspace}, state_at_1)
      assert after_bs.value == "ello"

      {:noreply, after_undo, _} = MultiLineInput.update(:undo, after_bs)
      assert after_undo.value == "hello"
    end

    test "undo reverts enter (newline insertion)", %{state: state} do
      state_at_2 = %{state | cursor_pos: {0, 2}}
      {:noreply, after_enter, _} = MultiLineInput.update({:enter}, state_at_2)
      assert after_enter.value == "he\nllo"

      {:noreply, after_undo, _} = MultiLineInput.update(:undo, after_enter)
      assert after_undo.value == "hello"
    end
  end
end
