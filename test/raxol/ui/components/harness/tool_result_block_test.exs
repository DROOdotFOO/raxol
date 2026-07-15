defmodule Raxol.UI.Components.Harness.ToolResultBlockTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.ToolResultBlock

  defp default_context do
    %{theme: Raxol.UI.Theming.Theme.default_theme()}
  end

  defp key_event(key), do: %Event{type: :key, data: %{key: key}}

  defp lines(n), do: Enum.map_join(1..n, "\n", &"line#{&1}")

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = ToolResultBlock.init(id: :tr1)
      assert state.id == :tr1
      assert state.output == ""
      assert state.status == :done
      assert state.taint == false
      assert state.collapsed == true
      assert state.collapse_lines == 6
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               ToolResultBlock.init(
                 id: :tr2,
                 output: "hello",
                 status: :failed,
                 taint: true,
                 collapsed: false,
                 collapse_lines: 3
               )

      assert state.output == "hello"
      assert state.status == :failed
      assert state.taint == true
      assert state.collapsed == false
      assert state.collapse_lines == 3
    end
  end

  describe "render/2 - short (non-collapsible) output" do
    test "renders header with glyph, label, empty badge -- no collapse hint" do
      {:ok, state} = ToolResultBlock.init(id: :tr_short, output: lines(3))
      rendered = ToolResultBlock.render(state, default_context())

      assert rendered.type == :column
      [header, body] = rendered.children

      assert header.type == :row
      assert length(header.children) == 3

      glyph_el = Enum.at(header.children, 0)
      assert glyph_el.content == "✓"

      label_el = Enum.at(header.children, 1)
      assert label_el.content == "Tool Result"

      badge_el = Enum.at(header.children, 2)
      assert badge_el.content == ""

      assert body.type == :box
      assert body.style == %{border: :single, padding: 1}
      [body_text] = body.children
      assert body_text.content == lines(3)
    end
  end

  describe "render/2 - long output, collapsed (default)" do
    test "shows a truncated body and an expand hint" do
      {:ok, state} = ToolResultBlock.init(id: :tr_long, output: lines(8))
      rendered = ToolResultBlock.render(state, default_context())

      [header, body] = rendered.children
      assert length(header.children) == 4

      hint_el = Enum.at(header.children, 3)
      assert hint_el.content == "[+2 more lines, enter to expand]"

      [body_text] = body.children
      assert body_text.content == lines(6)
    end
  end

  describe "render/2 - long output, expanded" do
    test "shows the full body and a collapse hint" do
      {:ok, state} =
        ToolResultBlock.init(
          id: :tr_expanded,
          output: lines(8),
          collapsed: false
        )

      rendered = ToolResultBlock.render(state, default_context())

      [header, body] = rendered.children
      hint_el = Enum.at(header.children, 3)
      assert hint_el.content == "[enter to collapse]"

      [body_text] = body.children
      assert body_text.content == lines(8)
    end
  end

  describe "render/2 - taint" do
    test "composes the taint badge when tainted" do
      {:ok, state} =
        ToolResultBlock.init(id: :tr_tainted, output: "x", taint: true)

      rendered = ToolResultBlock.render(state, default_context())

      [header, _body] = rendered.children
      badge_el = Enum.at(header.children, 2)
      assert badge_el.content == "⚠ untrusted"
      assert badge_el.style.fg == :yellow
    end

    test "badge renders empty when trusted" do
      {:ok, state} =
        ToolResultBlock.init(id: :tr_trusted, output: "x", taint: false)

      rendered = ToolResultBlock.render(state, default_context())

      [header, _body] = rendered.children
      badge_el = Enum.at(header.children, 2)
      assert badge_el.content == ""
    end
  end

  describe "render/2 - status glyph" do
    test "failed status renders a red cross" do
      {:ok, state} =
        ToolResultBlock.init(id: :tr_failed, output: "boom", status: :failed)

      rendered = ToolResultBlock.render(state, default_context())

      [header, _body] = rendered.children
      glyph_el = Enum.at(header.children, 0)
      assert glyph_el.content == "✗"
      assert glyph_el.style.fg == :red
    end
  end

  describe "handle_event/3 - collapse toggle" do
    test "enter toggles collapsed off then on" do
      {:ok, state} = ToolResultBlock.init(id: :tr_toggle, output: lines(8))
      assert state.collapsed == true

      {s1, []} = ToolResultBlock.handle_event(key_event(:enter), state, %{})
      assert s1.collapsed == false

      {s2, []} = ToolResultBlock.handle_event(key_event(:enter), s1, %{})
      assert s2.collapsed == true
    end

    test "space toggles like enter" do
      {:ok, state} =
        ToolResultBlock.init(id: :tr_toggle_space, output: lines(8))

      {new_state, []} =
        ToolResultBlock.handle_event(key_event(:space), state, %{})

      assert new_state.collapsed == false
    end

    test "unrelated events pass through unchanged" do
      {:ok, state} = ToolResultBlock.init(id: :tr_passthrough, output: lines(8))

      {new_state, []} =
        ToolResultBlock.handle_event(key_event(:down), state, %{})

      assert new_state == state
    end
  end
end
