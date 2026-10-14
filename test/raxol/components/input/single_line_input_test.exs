defmodule Raxol.UI.Components.Input.SingleLineInputTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Input.SingleLineInput

  describe "init/1" do
    test ~c"initializes with default values when no props provided" do
      {:ok, state} = SingleLineInput.init(%{})
      assert state.value == ""
      assert state.placeholder == ""
      assert Map.has_key?(state, :style)
      assert state.style == %{}
      assert state.focused == false
      assert state.cursor_pos == 0
      assert state.on_change == nil
      assert state.on_submit == nil
    end

    test ~c"initializes with provided values" do
      props = %{
        id: :my_input,
        initial_value: "test",
        placeholder: "Enter text",
        style: %{color: :blue},
        on_change: fn _ -> :changed end,
        on_submit: fn _ -> :submitted end
      }

      {:ok, state} = SingleLineInput.init(props)
      assert state.id == :my_input
      assert state.value == "test"
      assert state.placeholder == "Enter text"
      assert state.style == %{color: :blue}
      assert state.focused == false
      assert state.cursor_pos == 4
      assert is_function(state.on_change, 1)
      assert is_function(state.on_submit, 1)
    end
  end

  describe "update/2" do
    setup do
      {:ok, state} = SingleLineInput.init(%{initial_value: "hello", focused: true})
      {:ok, state: state}
    end

    test "sets value and updates cursor position", %{state: state} do
      {new_state, _} =
        SingleLineInput.update({:insert_char, "!"}, %{state | cursor_pos: 5})

      assert new_state.value == "hello!"
      assert new_state.cursor_pos == 6
    end

    test "moves cursor within bounds", %{state: state} do
      {state_right, _} =
        SingleLineInput.update(:move_cursor_right, %{state | cursor_pos: 1})

      assert state_right.cursor_pos == 2

      {state_left, _} =
        SingleLineInput.update(:move_cursor_left, %{state | cursor_pos: 1})

      assert state_left.cursor_pos == 0

      {state_past_end, _} =
        SingleLineInput.update(:move_cursor_right, %{state | cursor_pos: 5})

      assert state_past_end.cursor_pos == 5

      {state_past_start, _} =
        SingleLineInput.update(:move_cursor_left, %{state | cursor_pos: 0})

      assert state_past_start.cursor_pos == 0
    end

    test "handles focus and blur", %{state: state} do
      {focused_state, _} = SingleLineInput.update(:focus, state)
      assert focused_state.focused == true

      {blurred_state, _} = SingleLineInput.update(:blur, focused_state)
      assert blurred_state.focused == false
    end
  end

  describe "handle_event/3" do
    setup do
      {:ok, state} =
        SingleLineInput.init(%{
          id: :test_input,
          initial_value: "test",
          focused: true,
          cursor_pos: 4
        })

      {:ok, state: state}
    end

    test "handles character input", %{state: state} do
      event = %Event{
        type: :key,
        data: %{state: :pressed, key: "!", modifiers: []}
      }

      {new_state, _} = SingleLineInput.handle_event(event, state, %{})
      assert new_state.value == "test!"
      assert new_state.cursor_pos == 5
    end

    test "handles backspace", %{state: state} do
      event = %Event{
        type: :key,
        data: %{state: :pressed, key: "Backspace", modifiers: []}
      }

      {new_state, _} = SingleLineInput.handle_event(event, state, %{})
      assert new_state.value == "tes"
      assert new_state.cursor_pos == 3
    end

    test "handles delete", %{state: state} do
      state = %{state | cursor_pos: 1}

      event = %Event{
        type: :key,
        data: %{state: :pressed, key: "Delete", modifiers: []}
      }

      {new_state, _} = SingleLineInput.handle_event(event, state, %{})
      assert new_state.value == "tst"
      assert new_state.cursor_pos == 1
    end

    test "handles cursor movement", %{state: state} do
      event_left = %Event{
        type: :key,
        data: %{state: :pressed, key: "Left", modifiers: []}
      }

      {state_left, _} = SingleLineInput.handle_event(event_left, state, %{})
      assert state_left.cursor_pos == 3

      event_right = %Event{
        type: :key,
        data: %{state: :pressed, key: "Right", modifiers: []}
      }

      {state_right, _} =
        SingleLineInput.handle_event(event_right, state_left, %{})

      assert state_right.cursor_pos == 4

      event_home = %Event{
        type: :key,
        data: %{state: :pressed, key: "Home", modifiers: []}
      }

      {state_home, _} =
        SingleLineInput.handle_event(event_home, state_right, %{})

      assert state_home.cursor_pos == 0

      event_end = %Event{
        type: :key,
        data: %{state: :pressed, key: "End", modifiers: []}
      }

      {state_end, _} = SingleLineInput.handle_event(event_end, state_home, %{})
      assert state_end.cursor_pos == 4
    end

    test "calls on_submit when Enter is pressed", %{state: _state} do
      on_submit_func = fn value -> send(self(), {:submit_value, value}) end

      {:ok, state} =
        SingleLineInput.init(%{
          on_submit: on_submit_func,
          initial_value: "submit me"
        })

      event = %Event{
        type: :key,
        data: %{state: :pressed, key: "Enter", modifiers: []}
      }

      {_new_state, commands} = SingleLineInput.handle_event(event, state, %{})

      assert [{^on_submit_func, "submit me"}] = commands

      # Execute the command to trigger the callback
      Enum.each(commands, fn {func, arg} -> func.(arg) end)

      assert_receive {:submit_value, "submit me"}
    end

    test "calls on_change when text changes", %{state: _state} do
      on_change_func = fn value -> send(self(), {:change_value, value}) end
      {:ok, state} = SingleLineInput.init(%{on_change: on_change_func})

      event = %Event{
        type: :key,
        data: %{state: :pressed, key: "a", modifiers: []}
      }

      {_new_state, commands} = SingleLineInput.handle_event(event, state, %{})

      assert [{^on_change_func, "a"}] = commands

      # Execute the command to trigger the callback
      Enum.each(commands, fn {func, arg} -> func.(arg) end)

      assert_receive {:change_value, "a"}
    end
  end
end
