defmodule Raxol.UI.Components.Input.MultiLineInput.EventHandlerTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Input.MultiLineInput
  alias Raxol.UI.Components.Input.MultiLineInput.EventHandler

  # Utility to normalize dimensions
  defp normalize_dimensions(%{width: _, height: _} = dims), do: dims

  defp normalize_dimensions({w, h}) when is_integer(w) and is_integer(h),
    do: %{width: w, height: h}

  defp normalize_dimensions(_), do: %{width: 10, height: 5}

  # Helper to create initial state
  defp create_state(lines, cursor_pos),
    do: create_state(lines, cursor_pos, nil)

  defp create_state(lines, cursor_pos, selection) do
    # Use the main MultiLineInput module struct
    sel_start = if selection, do: elem(selection, 0), else: nil
    sel_end = if selection, do: elem(selection, 1), else: nil
    dims = normalize_dimensions(cursor_pos)

    %MultiLineInput{
      lines: lines,
      cursor_pos: cursor_pos,
      width: dims.width,
      height: dims.height,
      # Use correct fields
      selection_start: sel_start,
      selection_end: sel_end,
      id: "test_input",
      scroll_offset: {0, 0}
      # Removed meta field as it's not in the MultiLineInput struct
    }
  end

  describe "handle_event/2" do
    # --- Character Input ---
    test ~c"handles character input event" do
      state = create_state(["abc"], {0, 3})
      event = Event.key("a")
      # Update assertion to match actual handler behavior
      assert {:update, {:input, "a"}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles newline event" do
      state = create_state(["hello", "world"], {0, 5})
      event = Event.key(:enter)
      # Update assertion
      assert {:update, {:enter}, state} ==
               EventHandler.handle_event(event, state)
    end

    # --- Deletion ---
    test ~c"handles backspace event" do
      state = create_state(["hello"], {0, 3})
      event = Event.key(:backspace)
      # Update assertion
      assert {:update, {:backspace}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles delete event" do
      state = create_state(["hello"], {0, 2})
      event = Event.key(:delete)
      # Update assertion
      assert {:update, {:delete}, state} ==
               EventHandler.handle_event(event, state)
    end

    # --- Basic Navigation ---
    test ~c"handles arrow left event" do
      state = create_state(["hello"], {0, 3})
      event = Event.key(:left)
      # Update assertion
      assert {:update, {:move_cursor, :left}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles arrow right event" do
      state = create_state(["hello"], {0, 3})
      event = Event.key(:right)
      # Update assertion
      assert {:update, {:move_cursor, :right}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles arrow up event" do
      state = create_state(["line1", "line2"], {1, 3})
      event = Event.key(:up)
      # Update assertion
      assert {:update, {:move_cursor, :up}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles arrow down event" do
      state = create_state(["line1", "line2"], {0, 3})
      event = Event.key(:down)
      # Update assertion
      assert {:update, {:move_cursor, :down}, state} ==
               EventHandler.handle_event(event, state)
    end

    # --- Advanced Navigation ---
    test ~c"handles home event" do
      state = create_state(["hello"], {0, 4})
      event = Event.key(:home)
      # Update assertion
      assert {:update, {:move_cursor_line_start}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles end event" do
      state = create_state(["hello"], {0, 1})
      event = Event.key_event(:end, :pressed)
      # Update assertion
      assert {:update, {:move_cursor_line_end}, state} ==
               EventHandler.handle_event(event, state)
    end

    # Page navigation now properly implemented
    test ~c"handles pageup event" do
      state = create_state(Enum.map(0..10, &"line #{&1}"), {10, 3})
      event = Event.key_event(:pageup, :pressed)

      # EventHandler returns the update message with {:move_cursor_page, :up}
      assert {:update, {:move_cursor_page, :up}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles pagedown event" do
      state = create_state(Enum.map(0..10, &"line #{&1}"), {1, 3})
      event = Event.key_event(:pagedown, :pressed)

      # EventHandler returns the update message with {:move_cursor_page, :down}
      assert {:update, {:move_cursor_page, :down}, state} ==
               EventHandler.handle_event(event, state)
    end

    # --- Selection Handling ---
    # Remove test that checks state change, as EventHandler doesn't change state
    # test 'clears selection when moving cursor normally' do ... end

    # Selection with shift key
    test ~c"handles shift + arrow left event" do
      state = create_state(["hello"], {0, 3})
      event = Event.key_event(:left, :pressed, [:shift])

      assert {:update, {:selection_move, :left}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles shift + arrow right event" do
      state = create_state(["hello"], {0, 3})
      event = Event.key_event(:right, :pressed, [:shift])

      assert {:update, {:selection_move, :right}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles shift + arrow up event" do
      state = create_state(["line1", "line2"], {1, 3})
      event = Event.key_event(:up, :pressed, [:shift])

      assert {:update, {:selection_move, :up}, state} ==
               EventHandler.handle_event(event, state)
    end

    test ~c"handles shift + arrow down event" do
      state = create_state(["line1", "line2"], {0, 3})
      event = Event.key_event(:down, :pressed, [:shift])

      assert {:update, {:selection_move, :down}, state} ==
               EventHandler.handle_event(event, state)
    end

    # --- Other Events ---
    test ~c"ignores unknown keydown events" do
      state = create_state(["hello"], {0, 1})
      event = Event.key(:f1)
      # No handler for f1, so should return noreply
      assert {:noreply, state, nil} == EventHandler.handle_event(event, state)
    end

    test ~c"handles mouse click event" do
      state = create_state(["hello"], {0, 1})
      # Use a mouse event that matches what the handler expects
      event = Event.mouse_event(:left, {5, 2}, :pressed)
      # Assert it returns the update message matching the handler
      assert {:update, {:move_cursor_to, {2, 5}}, state} ==
               EventHandler.handle_event(event, state)
    end

    # Test for unhandled non-key/mouse events (e.g., focus gain/loss, resize)
    test ~c"ignores other event types" do
      state = create_state(["hello"], {0, 1})
      event = %Event{type: :focus_gained, data: %{}}
      assert {:noreply, state, nil} == EventHandler.handle_event(event, state)
    end
  end
end
