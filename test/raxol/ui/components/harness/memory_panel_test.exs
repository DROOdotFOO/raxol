defmodule Raxol.UI.Components.Harness.MemoryPanelTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.MemoryPanel

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp sample_items do
    [
      %{key: "session_id", value: "sess_8f21c"},
      %{key: "turns_completed", value: 12}
    ]
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = MemoryPanel.init(id: :mp1)
      assert state.id == :mp1
      assert state.title == "Memory"
      assert state.items == []
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      items = sample_items()

      assert {:ok, state} =
               MemoryPanel.init(
                 id: :mp2,
                 title: "Session Memory",
                 items: items,
                 style: %{fg: :cyan},
                 theme: %{bg: :blue}
               )

      assert state.id == :mp2
      assert state.title == "Session Memory"
      assert state.items == items
      assert state.style == %{fg: :cyan}
      assert state.theme == %{bg: :blue}
    end

    test "defaults id to a unique generated string" do
      assert {:ok, state} = MemoryPanel.init([])
      assert state.id =~ ~r/^memory-panel-\d+$/
    end
  end

  describe "render/2" do
    test "renders an empty-state message when items is empty" do
      {:ok, state} = MemoryPanel.init(id: :mp_empty)
      rendered = MemoryPanel.render(state, default_context())

      assert rendered.type == :box
      assert rendered.id == :mp_empty
      assert rendered.style == %{border: :single, padding: 1}

      [column] = rendered.children
      assert [title_el, empty_el] = column.children
      assert title_el.content == "Memory"
      assert empty_el.content == "No memory yet."
      assert empty_el.style == %{dim: true}
    end

    test "renders items as an aligned key/value table" do
      {:ok, state} = MemoryPanel.init(id: :mp_full, items: sample_items())
      rendered = MemoryPanel.render(state, default_context())

      [column] = rendered.children
      [title_el, table] = column.children

      assert title_el.content == "Memory"
      assert table.type == :table
      assert table.headers == ["Key", "Value"]

      assert table.rows == [
               ["session_id", "sess_8f21c"],
               ["turns_completed", "12"]
             ]
    end

    test "stringifies non-binary values" do
      {:ok, state} =
        MemoryPanel.init(id: :mp_types, items: [%{key: "count", value: 42}])

      rendered = MemoryPanel.render(state, default_context())
      [column] = rendered.children
      [_title_el, table] = column.children

      assert table.rows == [["count", "42"]]
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = MemoryPanel.init(id: :mp_evt, items: sample_items())

      event = %Event{type: :key, data: %{key: :enter}}
      {new_state, []} = MemoryPanel.handle_event(event, state, %{})
      assert new_state == state
    end
  end
end
