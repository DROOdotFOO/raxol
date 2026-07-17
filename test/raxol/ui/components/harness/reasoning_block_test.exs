defmodule Raxol.UI.Components.Harness.ReasoningBlockTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ReasoningBlock

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp key_event(key), do: %Event{type: :key, data: %{key: key}}

  describe "init/1" do
    test "initializes collapsed by default" do
      assert {:ok, state} = ReasoningBlock.init(id: :r1)
      assert state.id == :r1
      assert state.content == ""
      assert state.expanded == false
      assert state.width == Raxol.Core.Defaults.terminal_width()
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               ReasoningBlock.init(
                 id: :r2,
                 content: "line one\nline two",
                 expanded: true,
                 width: 30
               )

      assert state.content == "line one\nline two"
      assert state.expanded == true
      assert state.width == 30
    end
  end

  describe "render/2 collapsed" do
    test "shows a one-line summary with a line-count affordance" do
      {:ok, state} =
        ReasoningBlock.init(
          id: :r_collapsed,
          content: "Considering the tradeoffs.\nSecond line.\nThird line."
        )

      rendered = ReasoningBlock.render(state, default_context())

      assert rendered.type == :column
      assert length(rendered.children) == 1

      [summary] = rendered.children
      assert summary.style == %{dim: true}
      assert String.starts_with?(summary.content, "▸ 3 lines — ")
      assert summary.content =~ "Considering the tradeoffs."
    end

    test "singular line label for a single line" do
      {:ok, state} = ReasoningBlock.init(id: :r_one, content: "Just one line.")
      rendered = ReasoningBlock.render(state, default_context())
      [summary] = rendered.children
      assert String.starts_with?(summary.content, "▸ 1 line — ")
    end

    test "handles empty content without crashing" do
      {:ok, state} = ReasoningBlock.init(id: :r_empty, content: "")
      rendered = ReasoningBlock.render(state, default_context())
      [summary] = rendered.children
      assert summary.content == "▸ 0 lines — (empty)"
    end

    test "truncates a long summary to fit width, with an ellipsis" do
      long_line = String.duplicate("a", 200)

      {:ok, state} =
        ReasoningBlock.init(id: :r_long, content: long_line, width: 20)

      rendered = ReasoningBlock.render(state, default_context())
      [summary] = rendered.children

      assert Raxol.UI.TextMeasure.display_width(summary.content) <= 20
      assert String.ends_with?(summary.content, "…")
    end
  end

  describe "render/2 expanded" do
    test "shows every line, dim, under a line-count header" do
      {:ok, state} =
        ReasoningBlock.init(
          id: :r_expanded,
          content: "alpha\nbeta\ngamma",
          expanded: true
        )

      rendered = ReasoningBlock.render(state, default_context())
      assert length(rendered.children) == 4

      [header, l1, l2, l3] = rendered.children
      assert header.content == "▾ 3 lines"
      assert header.style == %{dim: true}
      assert l1.content == "alpha"
      assert l2.content == "beta"
      assert l3.content == "gamma"
      assert l1.style == %{dim: true}
      assert l2.style == %{dim: true}
      assert l3.style == %{dim: true}
    end
  end

  describe "handle_event/3" do
    test "Enter toggles expanded state" do
      {:ok, state} = ReasoningBlock.init(id: :r_toggle, content: "x")
      assert state.expanded == false

      {expanded_state, []} =
        ReasoningBlock.handle_event(key_event(:enter), state, %{})

      assert expanded_state.expanded == true

      {collapsed_state, []} =
        ReasoningBlock.handle_event(key_event(:enter), expanded_state, %{})

      assert collapsed_state.expanded == false
    end

    test "Space toggles expanded state" do
      {:ok, state} = ReasoningBlock.init(id: :r_space, content: "x")

      {new_state, []} =
        ReasoningBlock.handle_event(key_event(:space), state, %{})

      assert new_state.expanded == true
    end

    test "other keys pass through unchanged" do
      {:ok, state} = ReasoningBlock.init(id: :r_other, content: "x")

      {new_state, []} =
        ReasoningBlock.handle_event(key_event(:down), state, %{})

      assert new_state == state
    end
  end

  # -- U1-a re-host: fold vocabulary + TreeWalker stamping -----------------

  describe "controlled fold vocabulary (z + on_toggle emission)" do
    defp char_event(char),
      do: %Event{type: :key, data: %{key: :char, char: char}}

    test "z toggles expanded state (today's transcript fold key)" do
      {:ok, state} = ReasoningBlock.init(id: :r_z, content: "x")

      {expanded_state, []} =
        ReasoningBlock.handle_event(char_event("z"), state, %{})

      assert expanded_state.expanded == true

      {collapsed_state, []} =
        ReasoningBlock.handle_event(char_event("z"), expanded_state, %{})

      assert collapsed_state.expanded == false
    end

    test "toggle keys emit the wired on_toggle message alongside the local flip" do
      {:ok, state} =
        ReasoningBlock.init(id: :r_emit, content: "x", on_toggle: :peek!)

      for event <- [char_event("z"), key_event(:enter), key_event(:space)] do
        {new_state, commands} = ReasoningBlock.handle_event(event, state, %{})

        assert new_state.expanded == true
        assert commands == [:peek!]
      end
    end

    test "modified z (ctrl/alt) passes through without toggling" do
      {:ok, state} =
        ReasoningBlock.init(id: :r_mod, content: "x", on_toggle: :nope)

      for modifier <- [:ctrl, :alt] do
        event = %Event{
          type: :key,
          data: Map.put(%{key: :char, char: "z"}, modifier, true)
        }

        assert {^state, []} = ReasoningBlock.handle_event(event, state, %{})
      end
    end
  end

  describe "TreeWalker stamping (F0-mcp requirements)" do
    test "root node carries id, attrs, and the wired on_click" do
      {:ok, state} =
        ReasoningBlock.init(
          id: "reasoning-1",
          content: "one\ntwo",
          on_toggle: :toggle_reasoning
        )

      rendered = ReasoningBlock.render(state, default_context())

      assert rendered.id == "reasoning-1"
      assert rendered.on_click == :toggle_reasoning
      assert rendered.attrs.kind == :reasoning
      assert rendered.attrs.expanded == false
      assert rendered.attrs.lines == 2
      assert rendered.attrs.component_module == ReasoningBlock
    end

    test "attrs.expanded tracks the prop" do
      {:ok, state} =
        ReasoningBlock.init(id: "reasoning-2", content: "x", expanded: true)

      rendered = ReasoningBlock.render(state, default_context())

      assert rendered.attrs.expanded == true
      assert rendered.on_click == nil
    end
  end

  describe "ToolProvider derivation" do
    test "mcp_tools/1 derives a toggle action only when on_toggle is wired" do
      {:ok, wired} =
        ReasoningBlock.init(id: "r-w", content: "x", on_toggle: :flip)

      {:ok, unwired} = ReasoningBlock.init(id: "r-u", content: "x")

      assert [%{name: "toggle"}] =
               ReasoningBlock.mcp_tools(
                 ReasoningBlock.render(wired, default_context())
               )

      assert ReasoningBlock.mcp_tools(
               ReasoningBlock.render(unwired, default_context())
             ) == []
    end

    test "handle_tool_call/3 toggle dispatches a widget-targeted click" do
      context = %{widget_id: "r-t", widget_state: %{}, dispatcher_pid: nil}

      assert {:ok, _result, [event]} =
               ReasoningBlock.handle_tool_call("toggle", %{}, context)

      assert %Event{type: :click, data: %{widget_id: "r-t"}} = event
    end

    test "unknown actions error" do
      context = %{widget_id: "r-x", widget_state: %{}, dispatcher_pid: nil}

      assert {:error, _reason} =
               ReasoningBlock.handle_tool_call("explode", %{}, context)
    end
  end
end
