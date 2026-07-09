defmodule Raxol.UI.Components.TerminalTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Terminal

  defp init_terminal(opts \\ []) do
    {:ok, state} = Terminal.init(opts)
    state
  end

  describe "init/1" do
    test "initializes with default dimensions" do
      state = init_terminal()
      assert state.width == 80
      assert state.height == 24
      assert state.id == nil
      assert state.style == %{}
      assert %Raxol.Terminal.EmulatorLite{} = state.emulator
    end

    test "initializes with custom dimensions" do
      state = init_terminal(width: 40, height: 10, id: :term1)
      assert state.width == 40
      assert state.height == 10
      assert state.id == :term1
    end

    test "accepts map props" do
      {:ok, state} = Terminal.init(%{width: 60, height: 20})
      assert state.width == 60
      assert state.height == 20
    end

    test "emulator has matching dimensions" do
      state = init_terminal(width: 40, height: 10)
      assert state.emulator.width == 40
      assert state.emulator.height == 10
    end
  end

  describe "render/2" do
    test "renders box with column of text rows" do
      state = init_terminal(width: 10, height: 3, id: :render_test)
      rendered = Terminal.render(state, %{})

      assert rendered.type == :box
      assert rendered.id == :render_test
      assert rendered.width == 10
      assert rendered.height == 3

      column = rendered.children
      assert column.type == :column
      assert length(column.children) == 3
    end

    test "empty buffer renders rows of spaces" do
      state = init_terminal(width: 5, height: 2)
      rendered = Terminal.render(state, %{})

      column = rendered.children
      for row_el <- column.children do
        content = extract_content(row_el)
        # Each row should be 5 spaces (empty cells)
        assert String.length(content) == 5
        assert String.trim(content) == ""
      end
    end

    test "renders written text" do
      state = init_terminal(width: 10, height: 3)
      {state, []} = Terminal.update({:write, "Hello"}, state)
      rendered = Terminal.render(state, %{})

      column = rendered.children
      first_row = hd(column.children)
      content = extract_content(first_row)
      assert content =~ "Hello"
    end

    test "renders multi-line text" do
      state = init_terminal(width: 10, height: 3)
      {state, []} = Terminal.update({:write, "AB\nCD"}, state)
      rendered = Terminal.render(state, %{})

      column = rendered.children
      rows = column.children
      assert extract_content(Enum.at(rows, 0)) =~ "AB"
      assert extract_content(Enum.at(rows, 1)) =~ "CD"
    end
  end

  describe "update/2" do
    test "write adds text to buffer" do
      state = init_terminal(width: 20, height: 5)
      {updated, []} = Terminal.update({:write, "test"}, state)
      assert updated.emulator != state.emulator
    end

    test "clear resets the buffer" do
      state = init_terminal(width: 20, height: 5)
      {state, []} = Terminal.update({:write, "something"}, state)
      {cleared, []} = Terminal.update({:clear}, state)

      rendered = Terminal.render(cleared, %{})
      column = rendered.children
      first_content = extract_content(hd(column.children))
      assert String.trim(first_content) == ""
    end

    test "resize updates dimensions" do
      state = init_terminal(width: 80, height: 24)
      {resized, []} = Terminal.update({:resize, 40, 10}, state)
      assert resized.width == 40
      assert resized.height == 10
      assert resized.emulator.width == 40
      assert resized.emulator.height == 10
    end

    test "unknown messages pass through" do
      state = init_terminal()
      {same, []} = Terminal.update(:unknown, state)
      assert same == state
    end
  end

  describe "handle_event/3" do
    test "key event writes character to buffer" do
      state = init_terminal(width: 20, height: 5)
      event = %Event{type: :key, data: %{key: "a"}}
      {updated, []} = Terminal.handle_event(event, state, %{})

      rendered = Terminal.render(updated, %{})
      column = rendered.children
      first_content = extract_content(hd(column.children))
      assert first_content =~ "a"
    end

    test "resize event updates dimensions" do
      state = init_terminal(width: 80, height: 24)
      event = %Event{type: :resize, data: %{width: 40, height: 10}}
      {updated, []} = Terminal.handle_event(event, state, %{})
      assert updated.width == 40
      assert updated.height == 10
    end

    test "unknown events pass through" do
      state = init_terminal()
      event = %Event{type: :mouse, data: %{x: 0, y: 0}}
      {same, []} = Terminal.handle_event(event, state, %{})
      assert same == state
    end
  end

  describe "mount/1 and unmount/1" do
    test "mount returns {state, []}" do
      state = init_terminal()
      assert {^state, []} = Terminal.mount(state)
    end

    test "unmount returns state" do
      state = init_terminal()
      assert Terminal.unmount(state) == state
    end
  end

  # Extract text content from a rendered row element (may be a single text or a row of spans)
  defp extract_content(%{type: :text, content: content}), do: content
  defp extract_content(%{type: :row, children: children}) do
    Enum.map_join(children, "", fn %{content: c} -> c end)
  end
  defp extract_content(%{content: content}), do: content
  defp extract_content(_), do: ""
end
