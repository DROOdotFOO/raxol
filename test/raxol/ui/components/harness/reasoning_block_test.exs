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
      assert String.starts_with?(summary.content, "▸ 3 lines: ")
      assert summary.content =~ "Considering the tradeoffs."
    end

    test "singular line label for a single line" do
      {:ok, state} = ReasoningBlock.init(id: :r_one, content: "Just one line.")
      rendered = ReasoningBlock.render(state, default_context())
      [summary] = rendered.children
      assert String.starts_with?(summary.content, "▸ 1 line: ")
    end

    test "handles empty content without crashing" do
      {:ok, state} = ReasoningBlock.init(id: :r_empty, content: "")
      rendered = ReasoningBlock.render(state, default_context())
      [summary] = rendered.children
      assert summary.content == "▸ 0 lines: (empty)"
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
end
