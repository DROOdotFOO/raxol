defmodule Raxol.UI.Components.Harness.WorktracksPanelTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.WorktracksPanel

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp sample_lanes do
    [
      %{
        name: "todo",
        items: [%{title: "Write spec", status: "todo"}]
      },
      %{
        name: "doing",
        items: []
      },
      %{
        name: "done",
        items: [
          %{title: "Draft protocol table", status: "done"},
          %{title: "Review", status: "done"}
        ]
      }
    ]
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = WorktracksPanel.init(id: :wp1)
      assert state.id == :wp1
      assert state.title == "Worktracks"
      assert state.lanes == []
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      lanes = sample_lanes()

      assert {:ok, state} =
               WorktracksPanel.init(
                 id: :wp2,
                 title: "Custom Board",
                 lanes: lanes,
                 style: %{fg: :cyan},
                 theme: %{bg: :blue}
               )

      assert state.id == :wp2
      assert state.title == "Custom Board"
      assert state.lanes == lanes
      assert state.style == %{fg: :cyan}
      assert state.theme == %{bg: :blue}
    end

    test "defaults id to a unique generated string" do
      assert {:ok, state} = WorktracksPanel.init([])
      assert state.id =~ ~r/^worktracks-panel-\d+$/
    end
  end

  describe "render/2" do
    test "renders an empty board when lanes is empty" do
      {:ok, state} = WorktracksPanel.init(id: :wp_empty)
      rendered = WorktracksPanel.render(state, default_context())

      assert rendered.type == :box
      assert rendered.id == :wp_empty
      assert rendered.style == %{border: :single, padding: 1}

      assert [column] = rendered.children
      assert column.type == :column

      assert [title_el, empty_el] = column.children
      assert title_el.content == "Worktracks"
      assert title_el.style == %{bold: true}
      assert empty_el.content == "No worktracks yet."
      assert empty_el.style == %{dim: true}
    end

    test "renders one lane column per lane, each an aligned table" do
      {:ok, state} = WorktracksPanel.init(id: :wp_full, lanes: sample_lanes())
      rendered = WorktracksPanel.render(state, default_context())

      [column] = rendered.children
      [_title_el, board] = column.children

      assert board.type == :row
      assert length(board.children) == 3

      [todo_lane, doing_lane, done_lane] = board.children

      assert todo_lane.type == :box
      assert todo_lane.id == "wp_full-lane-0"
      [todo_column] = todo_lane.children
      [todo_name, todo_table] = todo_column.children
      assert todo_name.content == "todo (1)"
      assert todo_name.style == %{bold: true}
      assert todo_table.type == :table
      assert todo_table.headers == ["Title", "Status"]
      assert todo_table.rows == [["Write spec", "todo"]]

      [doing_column] = doing_lane.children
      [doing_name, doing_table] = doing_column.children
      assert doing_name.content == "doing (0)"
      assert doing_table.rows == []
      assert doing_table.headers == ["Title", "Status"]

      [done_column] = done_lane.children
      [done_name, done_table] = done_column.children
      assert done_name.content == "done (2)"

      assert done_table.rows == [
               ["Draft protocol table", "done"],
               ["Review", "done"]
             ]
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = WorktracksPanel.init(id: :wp_evt, lanes: sample_lanes())

      event = %Event{type: :key, data: %{key: :enter}}
      {new_state, []} = WorktracksPanel.handle_event(event, state, %{})
      assert new_state == state
    end
  end
end
