defmodule Raxol.UI.Components.Harness.ToolCallBlockTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.ToolCallBlock

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = ToolCallBlock.init(id: :tc1)
      assert state.id == :tc1
      assert state.name == ""
      assert state.args == %{}
      assert state.status == :pending
      assert state.frame == 0
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               ToolCallBlock.init(
                 id: :tc2,
                 name: "Bash",
                 args: %{command: "ls -la"},
                 status: :running,
                 frame: 3,
                 style: %{fg: :white},
                 theme: %{bg: :black}
               )

      assert state.id == :tc2
      assert state.name == "Bash"
      assert state.args == %{command: "ls -la"}
      assert state.status == :running
      assert state.frame == 3
      assert state.style == %{fg: :white}
      assert state.theme == %{bg: :black}
    end
  end

  describe "status_glyph/2" do
    test "running returns a spinner frame and cyan" do
      {glyph, color} = ToolCallBlock.status_glyph(:running, 0)
      assert is_binary(glyph)
      assert glyph != ""
      assert color == :cyan
    end

    test "running frame advances through the spinner table" do
      {glyph0, _} = ToolCallBlock.status_glyph(:running, 0)
      {glyph1, _} = ToolCallBlock.status_glyph(:running, 1)
      assert glyph0 != glyph1
    end

    test "done is a green check" do
      assert ToolCallBlock.status_glyph(:done, 0) == {"✓", :green}
    end

    test "failed is a red cross" do
      assert ToolCallBlock.status_glyph(:failed, 0) == {"✗", :red}
    end

    test "pending falls back to a neutral marker" do
      assert ToolCallBlock.status_glyph(:pending, 0) == {"○", :white}
    end
  end

  describe "compact_args/1" do
    test "empty map renders as empty string" do
      assert ToolCallBlock.compact_args(%{}) == ""
    end

    test "map renders as sorted key: value pairs wrapped in parens" do
      assert ToolCallBlock.compact_args(%{b: 2, a: 1}) == "(a: 1, b: 2)"
    end

    test "string args pass through" do
      assert ToolCallBlock.compact_args("raw args") == "raw args"
    end

    test "long args are truncated with an ellipsis" do
      huge = String.duplicate("x", 200)
      result = ToolCallBlock.compact_args(huge)
      assert String.ends_with?(result, "…")
      assert Raxol.UI.TextMeasure.display_width(result) <= 60
    end

    test "other shapes fall back to empty string" do
      assert ToolCallBlock.compact_args(nil) == ""
    end
  end

  describe "render/2" do
    test "renders glyph + name for a pending call with no args" do
      {:ok, state} = ToolCallBlock.init(id: :tc_render, name: "Read")
      rendered = ToolCallBlock.render(state, default_context())

      assert rendered.type == :row
      assert rendered.style.gap == 1
      assert length(rendered.children) == 2

      glyph_el = Enum.at(rendered.children, 0)
      assert glyph_el.content == "○"

      name_el = Enum.at(rendered.children, 1)
      assert name_el.content == "Read"
      assert name_el.style == %{bold: true}
    end

    test "renders a third child for compact args when args present" do
      {:ok, state} =
        ToolCallBlock.init(id: :tc_args, name: "Bash", args: %{command: "ls"})

      rendered = ToolCallBlock.render(state, default_context())

      assert length(rendered.children) == 3
      args_el = Enum.at(rendered.children, 2)
      assert args_el.content == "(command: \"ls\")"
      assert args_el.style == %{dim: true}
    end

    test "running status renders the spinner colour" do
      {:ok, state} =
        ToolCallBlock.init(id: :tc_run, name: "Grep", status: :running)

      rendered = ToolCallBlock.render(state, default_context())

      glyph_el = Enum.at(rendered.children, 0)
      assert glyph_el.style.fg == :cyan
    end

    test "failed status renders a red cross" do
      {:ok, state} =
        ToolCallBlock.init(id: :tc_fail, name: "Write", status: :failed)

      rendered = ToolCallBlock.render(state, default_context())

      glyph_el = Enum.at(rendered.children, 0)
      assert glyph_el.content == "✗"
      assert glyph_el.style.fg == :red
    end

    test "an explicit style gap is not clobbered" do
      {:ok, state} =
        ToolCallBlock.init(id: :tc_gap, name: "X", style: %{gap: 3})

      rendered = ToolCallBlock.render(state, default_context())
      assert rendered.style.gap == 3
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged (stateless component)" do
      {:ok, state} = ToolCallBlock.init(id: :tc_evt, name: "Bash")
      event = %Raxol.Core.Events.Event{type: :key, data: %{key: :enter}}
      {new_state, []} = ToolCallBlock.handle_event(event, state, %{})
      assert new_state == state
    end
  end
end
