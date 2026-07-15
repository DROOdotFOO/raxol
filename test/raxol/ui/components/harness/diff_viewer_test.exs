defmodule Raxol.UI.Components.Harness.DiffViewerTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.DiffViewer

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = DiffViewer.init(id: :dv1)
      assert state.id == :dv1
      assert state.path == ""
      assert state.old == ""
      assert state.new == ""
      assert state.mode == :unified
      assert state.style == %{}
      assert state.theme == %{}
    end

    test "initializes with provided props" do
      assert {:ok, state} =
               DiffViewer.init(
                 id: :dv2,
                 path: "lib/foo.ex",
                 old: "a\nb",
                 new: "a\nc",
                 mode: :split,
                 style: %{bold: true},
                 theme: %{fg: :white}
               )

      assert state.path == "lib/foo.ex"
      assert state.old == "a\nb"
      assert state.new == "a\nc"
      assert state.mode == :split
      assert state.style == %{bold: true}
      assert state.theme == %{fg: :white}
    end

    test "normalizes an unrecognized mode to :unified" do
      assert {:ok, state} = DiffViewer.init(mode: :bogus)
      assert state.mode == :unified
    end
  end

  describe "render/2 (unified mode)" do
    setup do
      {:ok, state} =
        DiffViewer.init(
          path: "lib/orders/total.ex",
          old: "a\nb\nc",
          new: "a\nx\nc"
        )

      %{state: state}
    end

    test "renders a column with a header, a divider, and one row per diff line",
         %{state: state} do
      rendered = DiffViewer.render(state, default_context())

      assert rendered.type == :column

      # header + divider + 4 diff lines (equal, delete, insert, equal)
      assert length(rendered.children) == 6

      [header, divider | diff_lines] = rendered.children
      assert header.type == :column
      assert divider.type == :divider
      assert length(diff_lines) == 4
      assert Enum.all?(diff_lines, &(&1.type == :row))
    end

    test "header names the path and counts additions/removals", %{
      state: state
    } do
      rendered = DiffViewer.render(state, default_context())
      [header, _divider | _rest] = rendered.children
      [summary_row, _caption] = header.children

      texts = Enum.map(summary_row.children, & &1.content)
      assert "lib/orders/total.ex" in texts
      assert "+1" in texts
      assert "-1" in texts
    end

    test "colors the deleted line red and the inserted line green", %{
      state: state
    } do
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children
      [_equal_a, delete_row, insert_row, _equal_c] = diff_lines

      [_gutter, delete_text] = delete_row.children
      assert delete_text.content =~ "- b"
      assert delete_text.style.fg == :red

      [_gutter, insert_text] = insert_row.children
      assert insert_text.content =~ "+ x"
      assert insert_text.style.fg == :green
    end

    test "context lines are dim and unmarked", %{state: state} do
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children
      [equal_a, _delete_row, _insert_row, equal_c] = diff_lines

      [_gutter, text_a] = equal_a.children
      assert text_a.content =~ "  a"
      assert text_a.style.fg == :dim

      [_gutter, text_c] = equal_c.children
      assert text_c.content =~ "  c"
      assert text_c.style.fg == :dim
    end
  end

  describe "render/2 (split mode)" do
    test "renders old/new side by side inside a two-box row" do
      {:ok, state} =
        DiffViewer.init(old: "a\nb\nc", new: "a\nx\nc", mode: :split)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children

      assert split_row.type == :row
      assert length(split_row.children) == 2
      assert Enum.all?(split_row.children, &(&1.type == :box))
    end

    test "pads the shorter side with blank filler so rows stay aligned" do
      {:ok, state} =
        DiffViewer.init(old: "a\nb", new: "a\nb\nc\nd", mode: :split)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children
      [old_box, new_box] = split_row.children

      [old_column] = old_box.children
      [new_column] = new_box.children

      # "OLD"/"NEW" label + 1 equal row per shared line + 2 inserted rows
      assert length(old_column.children) == length(new_column.children)
    end
  end

  describe "handle_event/3" do
    test "passes through all events unchanged" do
      {:ok, state} = DiffViewer.init(path: "a.ex")
      {new_state, []} = DiffViewer.handle_event(:whatever, state, %{})
      assert new_state == state
    end
  end
end
