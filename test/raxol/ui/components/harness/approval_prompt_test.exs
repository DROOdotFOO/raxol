defmodule Raxol.UI.Components.Harness.ApprovalPromptTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ApprovalPrompt

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp find_by_id(children, id), do: Enum.find(children, &(&1[:id] == id))

  describe "init/1" do
    test "defaults to the four standard options, none selected but the first" do
      assert {:ok, state} = ApprovalPrompt.init(id: :ap1)

      assert state.action == nil
      assert state.blast_radius == %{}
      assert state.selected_index == 0
      assert state.width == 60

      assert [
               %{key: :allow_once, decision: :allow, scope: :once},
               %{key: :allow_session, decision: :allow, scope: :session},
               %{key: :allow_root, decision: :allow, scope: :root},
               %{key: :deny, decision: :deny, scope: :once}
             ] = state.options
    end

    test "honors a custom :options list instead of the defaults" do
      custom = [%{key: :yes, label: "Yes", decision: :allow, scope: :once}]
      assert {:ok, state} = ApprovalPrompt.init(id: :ap2, options: custom)
      assert state.options == custom
    end

    test "honors :action and :blast_radius props" do
      assert {:ok, state} =
               ApprovalPrompt.init(
                 id: :ap3,
                 action: %{description: "Delete stale cache", tool: "shell"},
                 blast_radius: %{deletes: ["/tmp/a"]}
               )

      assert state.action == %{description: "Delete stale cache", tool: "shell"}
      assert state.blast_radius == %{deletes: ["/tmp/a"]}
    end
  end

  describe "render/2" do
    setup do
      {:ok, state} =
        ApprovalPrompt.init(
          id: "ap-render",
          action: "Delete the stale cache",
          blast_radius: %{deletes: ["/tmp/a"], reversible: false}
        )

      %{state: state}
    end

    test "renders a dialog_surface box built on Modal.Rendering", %{
      state: state
    } do
      rendered = ApprovalPrompt.render(state, default_context())

      assert rendered.type == :box
      assert rendered.border == :double
      assert rendered.width == state.width
      assert rendered.height == ApprovalPrompt.estimate_height(state)
      assert rendered.padding == 1
      assert rendered.style.align == :center
    end

    test "shows the action description and embeds the blast radius preview", %{
      state: state
    } do
      rendered = ApprovalPrompt.render(state, default_context())
      [content_column] = rendered.children
      assert content_column.type == :column

      action_line = find_by_id(content_column.children, "ap-render-action")
      assert action_line.content == "Delete the stale cache"
      assert action_line.style == %{bold: true}

      blast_radius_view =
        Enum.find(content_column.children, &(&1.type == :column))

      assert blast_radius_view != nil

      marker =
        Enum.find(
          blast_radius_view.children,
          &(&1[:content] == "⚠ IRREVERSIBLE: this action cannot be undone")
        )

      assert marker != nil
      assert marker.fg == :red
    end

    test "renders the option rows with the first one marked as selected", %{
      state: state
    } do
      rendered = ApprovalPrompt.render(state, default_context())
      [content_column] = rendered.children

      option0 = find_by_id(content_column.children, "ap-render-option-0")
      assert option0.content == "▸ 1. Allow once"
      assert option0.style == %{reverse: true}

      option1 = find_by_id(content_column.children, "ap-render-option-1")
      assert option1.content == "  2. Allow for session"
      assert option1.style == %{reverse: false}

      option3 = find_by_id(content_column.children, "ap-render-option-3")
      assert option3.content == "  4. Deny"
    end
  end

  describe "estimate_height/1" do
    test "sums frame, action, spacers, blast radius rows, and options" do
      {:ok, state} = ApprovalPrompt.init(id: :ap_height)

      # frame(4) + action(1) + spacers(2) + blast_radius("no effects" line = 1) +
      # options_header(1) + options(4) = 13
      assert ApprovalPrompt.estimate_height(state) == 13
    end
  end

  describe "handle_event/3 — navigation" do
    setup do
      {:ok, state} = ApprovalPrompt.init(id: :ap_nav)
      %{state: state}
    end

    test "Down (string form) moves the selection forward", %{state: state} do
      event = %{type: :key, data: %{key: "Down"}}
      assert {new_state, []} = ApprovalPrompt.handle_event(event, state, %{})
      assert new_state.selected_index == 1
    end

    test "down (atom form) moves the selection forward", %{state: state} do
      event = %{type: :key, data: %{key: :down}}
      assert {new_state, []} = ApprovalPrompt.handle_event(event, state, %{})
      assert new_state.selected_index == 1
    end

    test "Up clamps at 0 instead of going negative", %{state: state} do
      event = %{type: :key, data: %{key: "Up"}}
      assert {new_state, []} = ApprovalPrompt.handle_event(event, state, %{})
      assert new_state.selected_index == 0
    end

    test "Down clamps at the last option", %{state: state} do
      down = %{type: :key, data: %{key: :down}}

      final_state =
        Enum.reduce(1..10, state, fn _, acc ->
          {next, []} = ApprovalPrompt.handle_event(down, acc, %{})
          next
        end)

      assert final_state.selected_index == 3
    end

    test "a digit key (:char form) jumps straight to that option", %{
      state: state
    } do
      event = %{type: :key, data: %{key: :char, char: "3"}}
      assert {new_state, []} = ApprovalPrompt.handle_event(event, state, %{})
      assert new_state.selected_index == 2
    end

    test "a digit key (bare single-char form) jumps straight to that option", %{
      state: state
    } do
      event = %{type: :key, data: %{key: "3"}}
      assert {new_state, []} = ApprovalPrompt.handle_event(event, state, %{})
      assert new_state.selected_index == 2
    end

    test "an out-of-range digit key is a no-op", %{state: state} do
      event = %{type: :key, data: %{key: "9"}}
      assert {new_state, []} = ApprovalPrompt.handle_event(event, state, %{})
      assert new_state.selected_index == 0
    end

    test "accepts a wrapped %Event{} struct the same as a plain map", %{
      state: state
    } do
      event = %Event{type: :key, data: %{key: :down}}
      assert {new_state, []} = ApprovalPrompt.handle_event(event, state, %{})
      assert new_state.selected_index == 1
    end

    test "an unrelated event is a no-op", %{state: state} do
      event = %Event{type: :resize, data: %{width: 80, height: 24}}
      assert {^state, []} = ApprovalPrompt.handle_event(event, state, %{})
    end
  end

  describe "handle_event/3 — confirming a decision" do
    setup do
      {:ok, state} = ApprovalPrompt.init(id: :ap_confirm)
      %{state: state}
    end

    test "Enter on the default selection emits allow/once", %{state: state} do
      event = %{type: :key, data: %{key: "Enter"}}

      assert {^state, [{:approval_decision, %{decision: :allow, scope: :once}}]} =
               ApprovalPrompt.handle_event(event, state, %{})
    end

    test "Enter after navigating to Deny emits deny/once", %{state: state} do
      down = %{type: :key, data: %{key: :down}}
      {state, []} = ApprovalPrompt.handle_event(down, state, %{})
      {state, []} = ApprovalPrompt.handle_event(down, state, %{})
      {state, []} = ApprovalPrompt.handle_event(down, state, %{})
      assert state.selected_index == 3

      enter = %{type: :key, data: %{key: :enter}}

      assert {^state, [{:approval_decision, %{decision: :deny, scope: :once}}]} =
               ApprovalPrompt.handle_event(enter, state, %{})
    end

    test "Enter after jumping to 'Allow for agent subtree' emits allow/root", %{
      state: state
    } do
      jump = %{type: :key, data: %{key: "3"}}
      {state, []} = ApprovalPrompt.handle_event(jump, state, %{})
      assert state.selected_index == 2

      enter = %{type: :key, data: %{key: :enter}}

      assert {_state, [{:approval_decision, %{decision: :allow, scope: :root}}]} =
               ApprovalPrompt.handle_event(enter, state, %{})
    end
  end

  describe "layout regression: explicit gaps" do
    # The layout engine defaults an unset column gap to 1, which doubles
    # every row and overflows the fixed-height dialog surface (content
    # spilled past the bottom border). Every column this component renders
    # must carry an explicit gap.
    test "every column in the rendered tree has an explicit gap" do
      {:ok, state} =
        ApprovalPrompt.init(
          action: %{description: "Clear cache", tool: "shell.exec"},
          blast_radius: %{
            deletes: ["/a", "/b"],
            commands: ["rm -rf /tmp/x"],
            writes: ["/log"],
            reversible: false
          }
        )

      rendered = ApprovalPrompt.render(state, %{})

      for column <- collect_columns(rendered) do
        assert is_integer(Map.get(column, :gap)) or
                 is_integer(get_in(column, [:style, :gap])),
               "column without explicit gap: #{inspect(Map.drop(column, [:children]))}"
      end
    end

    defp collect_columns(%{type: :column} = node) do
      [node | Enum.flat_map(children_of(node), &collect_columns/1)]
    end

    defp collect_columns(%{} = node),
      do: Enum.flat_map(children_of(node), &collect_columns/1)

    defp collect_columns(_other), do: []

    defp children_of(node) do
      case Map.get(node, :children) do
        list when is_list(list) -> List.flatten(list)
        %{} = one -> [one]
        _ -> []
      end
    end
  end
end
