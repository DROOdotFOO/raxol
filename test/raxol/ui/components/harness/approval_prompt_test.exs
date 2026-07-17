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
          &(&1[:content] == "⚠ IRREVERSIBLE — this action cannot be undone")
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

  # -- The block answer vocabulary (U1-c re-hosting) ------------------------
  #
  # The transcript approval BLOCK speaks the harness answer vocabulary
  # (`Raxol.UI.Harness.Keymap`'s Track-D binds): `y`/`n` alias the first
  # allow/deny option, `1`-`9` pick the Nth option by position, and every
  # key emits the raw ANSWER HINT as a message out -- the component is
  # CONTROLLED (its returned state is discarded by the Bubbler doctrine),
  # so the decision must ride the command channel and be applied by the
  # owner's update/2, which resolves the hint against the block's real
  # options (refusing honestly when it cannot). The standalone modal keeps
  # its select-then-confirm vocabulary untouched (`answer_mode: :select`,
  # the default -- every test above this line).

  @acp_options [
    %{option_id: "allow-once", name: "Allow once", kind: :allow_once},
    %{option_id: "allow-always", name: "Allow always", kind: :allow_always},
    %{option_id: "reject", name: "Reject", kind: :reject_once}
  ]

  defp direct_state(opts \\ []) do
    {:ok, state} =
      ApprovalPrompt.init(
        Keyword.merge(
          [
            id: "approval-req-1",
            answer_mode: :direct,
            options: @acp_options
          ],
          opts
        )
      )

    state
  end

  defp key_event(char), do: %{type: :key, data: %{key: :char, char: char}}

  describe "handle_event/3 — the block answer vocabulary (answer_mode: :direct)" do
    test "y emits the :allow hint as a message out, state untouched" do
      state = direct_state()

      assert {^state, [{:approval_answer, %{answer: :allow}}]} =
               ApprovalPrompt.handle_event(key_event("y"), state, %{})
    end

    test "n emits the :deny hint" do
      state = direct_state()

      assert {^state, [{:approval_answer, %{answer: :deny}}]} =
               ApprovalPrompt.handle_event(key_event("n"), state, %{})
    end

    test "a digit emits the 0-based {:option, i} hint (Keymap parity)" do
      state = direct_state()

      assert {^state, [{:approval_answer, %{answer: {:option, 2}}}]} =
               ApprovalPrompt.handle_event(key_event("3"), state, %{})
    end

    test "a digit past the option list still emits — refusal is the model's job" do
      # Keymap parity: the binds emit the raw hint unconditionally; the
      # owner (Surface / demo update) resolves it and refuses honestly.
      state = direct_state()

      assert {^state, [{:approval_answer, %{answer: {:option, 8}}}]} =
               ApprovalPrompt.handle_event(key_event("9"), state, %{})
    end

    test "Enter and arrows are no-ops — the block form has no selection cursor" do
      state = direct_state()

      for key <- [%{key: :enter}, %{key: :up}, %{key: :down}] do
        assert {^state, []} =
                 ApprovalPrompt.handle_event(
                   %{type: :key, data: key},
                   state,
                   %{}
                 )
      end
    end

    test "accepts a wrapped %Event{} struct the same as a plain map" do
      state = direct_state()

      event = %Event{type: :key, data: %{key: :char, char: "y"}}

      assert {^state, [{:approval_answer, %{answer: :allow}}]} =
               ApprovalPrompt.handle_event(event, state, %{})
    end

    test "the default :select mode still jumps on digits and emits nothing" do
      {:ok, state} = ApprovalPrompt.init(id: :modal)

      assert {%{selected_index: 2}, []} =
               ApprovalPrompt.handle_event(key_event("3"), state, %{})
    end
  end

  # -- MCP derivation: answer actions from the LIVE block node --------------
  #
  # The headless-approval story: an MCP client answers a live approval
  # programmatically. Tools derive from the node `Block.render/2` stamps
  # (`type: :approval_prompt`, attrs carrying seal/options), offer ONLY
  # what the request's real options offer (affordance honesty), and each
  # invocation dispatches the same answer key a human would press.

  defp live_node(options \\ @acp_options) do
    %{
      type: :approval_prompt,
      id: "approval-req-1",
      attrs: %{
        seal: :live,
        answer_mode: :direct,
        options: options,
        request_id: "req-1"
      },
      gap: 0,
      children: []
    }
  end

  defp sealed_node do
    put_in(live_node().attrs.seal, :sealed)
  end

  describe "mcp_tools/1 — answer actions derive from the live approval node" do
    test "a live node derives answer_allow, answer_deny, and answer_option" do
      names = live_node() |> ApprovalPrompt.mcp_tools() |> Enum.map(& &1.name)

      assert "answer_allow" in names
      assert "answer_deny" in names
      assert "answer_option" in names
    end

    test "answer_option's schema covers exactly the options present" do
      tool =
        live_node()
        |> ApprovalPrompt.mcp_tools()
        |> Enum.find(&(&1.name == "answer_option"))

      option_schema = tool.inputSchema.properties.option
      assert option_schema.minimum == 1
      assert option_schema.maximum == 3
      # referent-honest: the description names the real options
      assert tool.description =~ "Allow once"
      assert tool.description =~ "Reject"
    end

    test "no reject-class option -> no answer_deny (affordance honesty)" do
      allow_only = [
        %{option_id: "allow-once", name: "Allow once", kind: :allow_once}
      ]

      names =
        live_node(allow_only)
        |> ApprovalPrompt.mcp_tools()
        |> Enum.map(& &1.name)

      assert "answer_allow" in names
      refute "answer_deny" in names
    end

    test "string-keyed wire options derive the same tools" do
      wire = [
        %{"option_id" => "ok", "name" => "Allow", "kind" => "allow_once"},
        %{"option_id" => "no", "name" => "Deny", "kind" => "reject_once"}
      ]

      names =
        live_node(wire) |> ApprovalPrompt.mcp_tools() |> Enum.map(& &1.name)

      assert "answer_allow" in names
      assert "answer_deny" in names
    end

    test "a SEALED node derives no answer tools — the question is answered" do
      assert ApprovalPrompt.mcp_tools(sealed_node()) == []
    end

    test "a select-mode (modal) node derives no answer tools" do
      node = put_in(live_node().attrs.answer_mode, :select)
      assert ApprovalPrompt.mcp_tools(node) == []
    end

    test "a live node with no options derives no answer tools" do
      assert ApprovalPrompt.mcp_tools(live_node([])) == []
    end
  end

  describe "handle_tool_call/3 — an answer is a programmatic answer key" do
    defp tool_context(node) do
      %{widget_id: node.id, widget_state: node, dispatcher_pid: nil}
    end

    test "answer_allow presses y" do
      assert {:ok, text, [event]} =
               ApprovalPrompt.handle_tool_call(
                 "answer_allow",
                 %{},
                 tool_context(live_node())
               )

      assert text =~ "Allow once"
      assert %Event{type: :key, data: %{key: :char, char: "y"}} = event
    end

    test "answer_deny presses n" do
      assert {:ok, _text, [event]} =
               ApprovalPrompt.handle_tool_call(
                 "answer_deny",
                 %{},
                 tool_context(live_node())
               )

      assert %Event{type: :key, data: %{key: :char, char: "n"}} = event
    end

    test "answer_option presses the 1-based digit" do
      assert {:ok, text, [event]} =
               ApprovalPrompt.handle_tool_call(
                 "answer_option",
                 %{"option" => 2},
                 tool_context(live_node())
               )

      assert text =~ "Allow always"
      assert %Event{type: :key, data: %{key: :char, char: "2"}} = event
    end

    test "answer_option past the list refuses with the real range, no events" do
      assert {:error, message} =
               ApprovalPrompt.handle_tool_call(
                 "answer_option",
                 %{"option" => 7},
                 tool_context(live_node())
               )

      assert message =~ "1-3"
    end

    test "answer_deny with no reject-class option refuses honestly" do
      allow_only = [
        %{option_id: "allow-once", name: "Allow once", kind: :allow_once}
      ]

      assert {:error, _message} =
               ApprovalPrompt.handle_tool_call(
                 "answer_deny",
                 %{},
                 tool_context(live_node(allow_only))
               )
    end

    test "answering a SEALED approval refuses — never a phantom answer" do
      assert {:error, message} =
               ApprovalPrompt.handle_tool_call(
                 "answer_allow",
                 %{},
                 tool_context(sealed_node())
               )

      assert message =~ "answered"
    end
  end
end
