defmodule Raxol.UI.Components.Harness.DiffViewerTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.Event
  alias Raxol.UI.Components.Harness.DiffViewer

  defp default_context, do: %{theme: Raxol.UI.Theming.Theme.default_theme()}

  # All text content in a rendered subtree, joined -- for presence asserts
  # that don't care about layout structure.
  defp tree_text(%{content: content} = node) when is_binary(content),
    do: content <> tree_text(Map.delete(node, :content))

  defp tree_text(%{children: children}) when is_list(children),
    do: Enum.map_join(children, &tree_text/1)

  defp tree_text(%{children: child}) when is_map(child), do: tree_text(child)
  defp tree_text(_node), do: ""

  # A fold row is [left-dashes, label, right-dashes]; its second child is
  # a plain text node whose content mentions "unchanged lines". Every
  # other row's second child is a `content_spans` row.
  defp fold_pill?(row) do
    case Enum.at(row.children, 1) do
      %{type: :text, content: content} -> content =~ "unchanged lines"
      _other -> false
    end
  end

  # A gutter is a two-span row: [bar, numbers] (bar keeps identity color,
  # numbers are prominence-faded chrome).
  defp gutter_row(row), do: hd(row.children)
  defp gutter_bar(row), do: hd(gutter_row(row).children)
  defp gutter_numbers(row), do: Enum.at(gutter_row(row).children, 1)

  defp gutter_text(row),
    do: Enum.map_join(gutter_row(row).children, & &1.content)

  describe "init/1" do
    test "initializes with default values" do
      assert {:ok, state} = DiffViewer.init(id: :dv1)
      assert state.id == :dv1
      assert state.path == ""
      assert state.old == ""
      assert state.new == ""
      assert state.mode == :auto
      assert state.width == nil
      assert state.language == nil
      assert state.syntax_theme == :one_dark
      assert state.context == 3
      assert state.folded == false
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
                 theme: %{fg: :white},
                 language: "elixir",
                 syntax_theme: :dracula,
                 context: 5
               )

      assert state.path == "lib/foo.ex"
      assert state.old == "a\nb"
      assert state.new == "a\nc"
      assert state.mode == :split
      assert state.style == %{bold: true}
      assert state.theme == %{fg: :white}
      assert state.language == "elixir"
      assert state.syntax_theme == :dracula
      assert state.context == 5
    end

    test "normalizes an unrecognized mode to :auto" do
      assert {:ok, state} = DiffViewer.init(mode: :bogus)
      assert state.mode == :auto
    end

    test "context accepts :all, non-negative integers, and normalizes anything else to 3" do
      assert {:ok, %{context: :all}} = DiffViewer.init(context: :all)
      assert {:ok, %{context: 0}} = DiffViewer.init(context: 0)
      assert {:ok, %{context: 7}} = DiffViewer.init(context: 7)
      assert {:ok, %{context: 3}} = DiffViewer.init(context: -1)
      assert {:ok, %{context: 3}} = DiffViewer.init(context: :bogus)
    end
  end

  describe "auto mode / effective_mode/2" do
    setup do
      # widest line is 9 columns ("context 1"); gutter is 1 column.
      # pane = 1 (gutter) + 1 (bar) + 1 (chrome) + 9 (line) = 12; split
      # needs 12 + 2 + 12 = 26 columns.
      props = [
        old: "context 1\nold line\ncontext 2",
        new: "context 1\nnew line\ncontext 2"
      ]

      %{props: props}
    end

    test "picks split when both panes fit the :width prop", %{props: props} do
      {:ok, state} = DiffViewer.init(props ++ [width: 120])
      assert DiffViewer.effective_mode(state, %{}) == :split
    end

    test "falls back to unified when the width is too narrow", %{props: props} do
      {:ok, state} = DiffViewer.init(props ++ [width: 20])
      assert DiffViewer.effective_mode(state, %{}) == :unified
    end

    test "falls back to unified when no width is known", %{props: props} do
      {:ok, state} = DiffViewer.init(props)
      assert DiffViewer.effective_mode(state, %{}) == :unified
    end

    test "reads available width from the render context", %{props: props} do
      {:ok, state} = DiffViewer.init(props)
      assert DiffViewer.effective_mode(state, %{available_width: 120}) == :split
      assert DiffViewer.effective_mode(state, %{width: 120}) == :split

      assert DiffViewer.effective_mode(state, %{dimensions: %{width: 120}}) ==
               :split

      assert DiffViewer.effective_mode(state, %{available_width: 20}) ==
               :unified
    end

    test "the :width prop wins over the context", %{props: props} do
      {:ok, state} = DiffViewer.init(props ++ [width: 20])

      assert DiffViewer.effective_mode(state, %{available_width: 200}) ==
               :unified
    end

    test "a single outlier-long line does not veto split (percentile fit)" do
      # 20 short lines + one 200-char outlier; max-based fit would demand
      # 200+ columns, percentile fit sees the typical 8-col line.
      shorts = Enum.map_join(1..20, "\n", fn i -> "line #{i}" end)
      outlier = String.duplicate("x", 200)
      old = shorts <> "\n" <> outlier <> "\nlast old"
      new = shorts <> "\n" <> outlier <> "\nlast new"

      {:ok, state} = DiffViewer.init(old: old, new: new, width: 80)
      assert DiffViewer.effective_mode(state, %{}) == :split
    end

    test "explicit modes pass through regardless of width", %{props: props} do
      {:ok, unified} = DiffViewer.init(props ++ [mode: :unified, width: 200])
      {:ok, split} = DiffViewer.init(props ++ [mode: :split, width: 10])
      assert DiffViewer.effective_mode(unified, %{}) == :unified
      assert DiffViewer.effective_mode(split, %{}) == :split
    end

    test "render/2 in auto follows the fit decision", %{props: props} do
      {:ok, wide} = DiffViewer.init(props ++ [width: 120])
      {:ok, narrow} = DiffViewer.init(props ++ [width: 20])

      wide_rendered = DiffViewer.render(wide, default_context())
      narrow_rendered = DiffViewer.render(narrow, default_context())

      # split renders one row of two borderless pane columns; unified
      # renders plain rows
      [_header, _divider | wide_body] = wide_rendered.children
      [_header2, _divider2 | narrow_body] = narrow_rendered.children

      assert [%{type: :row, children: [%{type: :column}, %{type: :column}]}] =
               wide_body

      assert Enum.all?(narrow_body, &(&1.type == :row))
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

    test "the deleted line gets a red gutter bar and the inserted line a green one",
         %{state: state} do
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children
      [_equal_a, delete_row, insert_row, _equal_c] = diff_lines

      [_delete_gutter, delete_content] = delete_row.children
      assert gutter_bar(delete_row).content == "▌"
      assert gutter_bar(delete_row).style.fg == "#FF6762"
      # numbers on a washed (changed) row hold 80% chrome prominence
      assert gutter_numbers(delete_row).style.fg == "#919191"

      # "b" -> "x" is a full single-token change (no shared substring), so
      # the whole span is word-diff-changed -- the emphasis tier, not the
      # plain row tier (see the word-diff describe block below for a case
      # with a partially-unchanged line). First content child is the
      # leader space covering the gutter-content gap cell.
      [_leader, delete_span] = delete_content.children
      assert delete_span.content == "b"
      assert delete_span.style.fg == "#FF6762"
      assert delete_span.style.bg == "#552527"

      [_insert_gutter, insert_content] = insert_row.children
      assert gutter_bar(insert_row).content == "▌"
      assert gutter_bar(insert_row).style.fg == "#5ECC71"

      [_leader, insert_span] = insert_content.children
      assert insert_span.content == "x"
      assert insert_span.style.fg == "#5ECC71"
      assert insert_span.style.bg == "#1D4428"
    end

    test "context lines are dim, unbarred, and untinted", %{state: state} do
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children
      [equal_a, _delete_row, _insert_row, equal_c] = diff_lines

      [_gutter_a, content_a] = equal_a.children
      refute gutter_text(equal_a) =~ "▌"
      # context-row numbers are faded chrome (hex), one tier under content
      assert is_binary(gutter_numbers(equal_a).style.fg)
      [_leader, span_a] = content_a.children
      assert span_a.content == "a"
      assert span_a.style.fg == :dim
      refute Map.has_key?(span_a.style, :bg)

      [_gutter_c, content_c] = equal_c.children
      refute gutter_text(equal_c) =~ "▌"
      [_leader, span_c] = content_c.children
      assert span_c.content == "c"
    end
  end

  describe "render/2 (word-diff emphasis)" do
    test "the changed word gets the emphasis bg tier; unchanged words keep the row tier" do
      {:ok, state} =
        DiffViewer.init(old: "hello world", new: "hello there", mode: :unified)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children
      [delete_row, insert_row] = diff_lines

      [_gutter, delete_content] = delete_row.children
      del_spans = delete_content.children

      assert Enum.any?(
               del_spans,
               &(&1.content == "world" and Map.get(&1.style, :bg) == "#552527")
             )

      # The UNCHANGED part of a changed line sits on the chroma-reduced
      # wash (H-K dechroma of #291418 at 0.35 chroma), not the full tint.
      assert Enum.any?(
               del_spans,
               &(&1.content == "hello " and
                   Map.get(&1.style, :bg) == "#211a1b")
             )

      [_gutter, insert_content] = insert_row.children
      ins_spans = insert_content.children

      assert Enum.any?(
               ins_spans,
               &(&1.content == "there" and Map.get(&1.style, :bg) == "#1D4428")
             )

      assert Enum.any?(
               ins_spans,
               &(&1.content == "hello " and
                   Map.get(&1.style, :bg) == "#1d231f")
             )
    end
  end

  describe "render/2 (syntax highlighting)" do
    test "language: elixir flows real syntax fg colors through the diff tint" do
      {:ok, state} =
        DiffViewer.init(
          old: "def foo, do: :ok",
          new: "def bar, do: :ok",
          mode: :unified,
          language: "elixir"
        )

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children
      [delete_row, insert_row] = diff_lines

      [_gutter, delete_content] = delete_row.children
      [_gutter, insert_content] = insert_row.children

      # At least one span keeps its own syntax fg (not the plain red/green
      # fallback) -- e.g. the unchanged "def" keyword token.
      assert Enum.any?(delete_content.children, fn span ->
               fg = Map.get(span.style, :fg)
               is_binary(fg) and fg != "#FF6762"
             end)

      assert Enum.any?(insert_content.children, fn span ->
               fg = Map.get(span.style, :fg)
               is_binary(fg) and fg != "#5ECC71"
             end)
    end

    test "language: nil (default) never calls the highlighter -- plain fallback fg" do
      {:ok, state} = DiffViewer.init(old: "a\nb", new: "a\nc", mode: :unified)
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children
      [_equal_a, delete_row, _insert_row] = diff_lines
      [_gutter, content] = delete_row.children
      [_leader, span] = content.children
      assert span.style.fg == "#FF6762"
    end
  end

  describe "render/2 (hunk folding)" do
    setup do
      old_lines = for n <- 1..10, do: "line #{n}"
      new_lines = for n <- 1..10, do: "line #{n}"

      old =
        Enum.join(
          old_lines ++ ["old tail", "after 1", "after 2", "after 3"],
          "\n"
        )

      new =
        Enum.join(
          new_lines ++ ["new tail", "after 1", "after 2", "after 3"],
          "\n"
        )

      %{old: old, new: new}
    end

    test "a run longer than 2*context+1 collapses to one pill row", %{
      old: old,
      new: new
    } do
      {:ok, state} = DiffViewer.init(old: old, new: new, mode: :unified)
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children

      fold_rows = Enum.filter(diff_lines, &fold_pill?/1)

      assert length(fold_rows) == 1
      [fold_row] = fold_rows
      [left_dashes, label, right_dashes] = fold_row.children
      # 10 leading equal lines, context 3 => 10 - 6 = 4 hidden.
      assert label.content =~ "4 unchanged lines"
      # dashes at 20% prominence, label at 40%
      assert left_dashes.style.fg == "#313131"
      assert right_dashes.style.fg == "#313131"
      assert label.style.fg == "#4f4f4f"

      # The 10-line leading run folds to 3 head + 1 pill + 3 tail (7 rows);
      # + delete + insert (2, unaffected); + a 3-line trailing run that's
      # too short to fold (3, stays as-is) = 7 + 2 + 3 = 12.
      assert length(diff_lines) == 12
    end

    test "context: :all disables folding entirely", %{old: old, new: new} do
      {:ok, state} =
        DiffViewer.init(old: old, new: new, mode: :unified, context: :all)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children

      # 10 leading equal + delete + insert + 3 trailing equal, nothing folded.
      assert length(diff_lines) == 15
      refute Enum.any?(diff_lines, &fold_pill?/1)
    end

    test "line numbers on rows after the fold are still correct", %{
      old: old,
      new: new
    } do
      {:ok, state} = DiffViewer.init(old: old, new: new, mode: :unified)
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | diff_lines] = rendered.children

      # head(3) + fold(1) + tail(3) + delete + insert + 3 trailing = index 7
      # is the last kept head row (old line 3); index 8 is the fold; index 9
      # is the first kept tail row before the change (old line 8).
      last_head_row = Enum.at(diff_lines, 2)
      assert gutter_text(last_head_row) =~ "3"

      first_tail_row = Enum.at(diff_lines, 4)
      assert gutter_text(first_tail_row) =~ "8"
    end
  end

  describe "render/2 (split mode filler)" do
    test "the unpaired side of a change block renders blank filler" do
      {:ok, state} =
        DiffViewer.init(old: "a\nb", new: "a\nb\nc\nd", mode: :split)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children
      [old_column, _new_column] = split_row.children

      # Last two rows on the OLD side are filler for the two extra NEW lines.
      filler_rows = Enum.take(old_column.children, -2)

      assert Enum.all?(filler_rows, fn row ->
               [_gutter, content] = row.children
               [span] = content.children
               span.content == ""
             end)
    end
  end

  describe "render/2 (split mode)" do
    test "renders old/new as two borderless half-width pane columns" do
      {:ok, state} =
        DiffViewer.init(old: "a\nb\nc", new: "a\nx\nc", mode: :split)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children

      assert split_row.type == :row
      assert length(split_row.children) == 2
      assert Enum.all?(split_row.children, &(&1.type == :column))

      # flex: 1 shares the row's space equally — {:pct, n} would only
      # resolve against a definite container dimension, which the row
      # doesn't have.
      assert Enum.all?(split_row.children, fn pane ->
               get_in(pane, [:style, :flex]) == 1
             end)
    end

    test "pads the shorter side with blank filler so rows stay aligned" do
      {:ok, state} =
        DiffViewer.init(old: "a\nb", new: "a\nb\nc\nd", mode: :split)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children
      [old_column, new_column] = split_row.children

      # 1 equal row per shared line + 2 inserted rows, no header labels
      assert length(old_column.children) == length(new_column.children)
    end
  end

  describe "render/2 (split mode truncation)" do
    test "an outlier line is ellipsis-truncated to the pane budget" do
      outlier = String.duplicate("y", 120)
      old = "short a\n" <> outlier <> "\nshort b"
      new = "short a\n" <> outlier <> "\nshort c"

      {:ok, state} =
        DiffViewer.init(old: old, new: new, mode: :split, width: 60)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children
      [old_column, _new_column] = split_row.children

      # find the outlier content row and measure its total span width
      outlier_row =
        Enum.find(old_column.children, fn row ->
          [_gutter, content] = row.children

          Enum.any?(content.children, fn span ->
            is_binary(span[:content]) and span[:content] =~ "yyy"
          end)
        end)

      assert outlier_row, "expected the outlier row"
      [_gutter, content] = outlier_row.children

      # First child is the leader space (covers the gutter-content gap
      # cell, outside the budget); the budgeted content follows it.
      [_leader | budgeted] = content.children

      total_width =
        Enum.reduce(budgeted, 0, fn span, acc ->
          acc + Raxol.UI.TextMeasure.display_width(span.content)
        end)

      # pane budget for width 60: half = 29, minus gutter(1)+bar(1)+chrome(1) = 26
      assert total_width <= 26
      assert List.last(budgeted).content == "…"
    end

    test "short lines pass through untruncated" do
      {:ok, state} =
        DiffViewer.init(old: "aa\nbb", new: "aa\ncc", mode: :split, width: 60)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children
      [old_column, _new_column] = split_row.children

      refute Enum.any?(old_column.children, fn row ->
               [_gutter, content] = row.children

               Enum.any?(content.children, fn span ->
                 span[:content] == "…"
               end)
             end)
    end
  end

  describe "render/2 (full-width wash + perceptual fade)" do
    test "a changed row's wash pads to the full pane budget" do
      {:ok, state} =
        DiffViewer.init(old: "aa\nbb", new: "aa\ncc", mode: :split, width: 60)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, split_row] = rendered.children
      [old_column, _new_column] = split_row.children

      changed_row =
        Enum.find(old_column.children, fn row ->
          gutter_text(row) =~ "▌"
        end)

      [_gutter, content] = changed_row.children
      [_leader | budgeted] = content.children

      total_width =
        Enum.reduce(budgeted, 0, fn span, acc ->
          acc + Raxol.UI.TextMeasure.display_width(span.content)
        end)

      # pane budget for width 60 (see truncation test): exactly filled
      assert total_width == 26

      # trailing pad carries the wash bg
      trailer = List.last(budgeted)
      assert String.trim(trailer.content) == ""
      assert is_binary(Map.get(trailer.style, :bg))
    end

    test "the leader space carries the row wash on changed lines" do
      {:ok, state} = DiffViewer.init(old: "a", new: "b", mode: :unified)
      rendered = DiffViewer.render(state, default_context())
      [_header, _divider, delete_row, _insert_row] = rendered.children
      [_gutter, content] = delete_row.children
      [leader | _rest] = content.children

      assert leader.content == " "
      assert is_binary(Map.get(leader.style, :bg))
    end

    test "context lines fade with distance from the nearest change" do
      # 6 identical context lines, then a change: the same token on rows
      # at distance 1 vs 4 must resolve to different faded fg hexes, and
      # the farther one must not equal the nearer one.
      context = Enum.map_join(1..6, "\n", fn _ -> "x = 1" end)
      old = context <> "\nremoved_line"
      new = context <> "\nadded_line"

      {:ok, state} =
        DiffViewer.init(
          old: old,
          new: new,
          mode: :unified,
          language: "elixir",
          context: :all
        )

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | rows] = rendered.children

      fg_of_context_row = fn row ->
        [_gutter, content] = row.children

        content.children
        |> Enum.map(&Map.get(&1.style, :fg))
        |> Enum.find(&is_binary/1)
      end

      # rows: 6 equal lines then delete+insert; distance to change is
      # 6,5,4,3,2,1 for the equal rows.
      equal_rows = Enum.take(rows, 6)
      far_fg = fg_of_context_row.(Enum.at(equal_rows, 0))
      near_fg = fg_of_context_row.(Enum.at(equal_rows, 5))

      assert is_binary(far_fg) and is_binary(near_fg)
      assert far_fg != near_fg
    end
  end

  describe "render/2 (long changed lines, unified)" do
    # width 60 -> unified budget = 60 - (2*1+1) - 1 - 1 = 55 columns
    defp long_ctx_render(old, new) do
      {:ok, state} =
        DiffViewer.init(old: old, new: new, mode: :unified, width: 60)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | rows] = rendered.children
      rows
    end

    defp row_text(row) do
      [_gutter, content] = row.children
      Enum.map_join(content.children, & &1.content)
    end

    test "an over-budget UNPAIRED delete mid-ellipses to one row" do
      long = "removed " <> String.duplicate("x", 80) <> "TAIL5"
      rows = long_ctx_render("keep\n" <> long, "keep")

      delete_row =
        Enum.find(rows, fn row -> gutter_text(row) =~ "▌" end)

      text = row_text(delete_row)
      assert text =~ "…"
      assert String.trim_trailing(text) =~ ~r/TAIL5$/
      # exactly one rendered row for the delete: no continuation gutters
      assert Enum.count(rows, fn row -> gutter_text(row) =~ "▌" end) == 1
    end

    test "an over-budget insert soft-wraps in full" do
      long = "added " <> String.duplicate("y", 120) <> "END"
      rows = long_ctx_render("keep", "keep\n" <> long)

      insert_rows =
        Enum.filter(rows, fn row -> gutter_text(row) =~ "▌" end)

      assert length(insert_rows) > 1

      # continuation rows keep the bar but a blank line number
      [first | continuations] = insert_rows
      assert gutter_text(first) =~ ~r/▌\s*\d/
      assert Enum.all?(continuations, &(gutter_text(&1) =~ ~r/▌\s+$/))

      # nothing lost: concatenated rows reconstruct the full line
      full = Enum.map_join(insert_rows, "", &row_text/1)
      assert String.replace(full, " ", "") =~ String.duplicate("y", 120)
      assert full =~ "END"
      refute full =~ "…"
    end

    test "a PAIRED over-budget delete borrows the insert's row allocation" do
      old_long = "shared head " <> String.duplicate("a", 200) <> " old tail"
      new_long = "shared head " <> String.duplicate("b", 90) <> " new tail"
      rows = long_ctx_render(old_long, new_long)

      change_rows =
        Enum.filter(rows, fn row -> gutter_text(row) =~ "▌" end)

      # delete rows come first, then insert rows (unified emits the run's
      # deletes then inserts). The insert wrapped into K rows; the longer
      # delete must occupy exactly K rows too, ellipsis-truncated.
      insert_count =
        Enum.count(change_rows, fn row ->
          gutter_bar(row).style.fg == "#5ECC71"
        end)

      delete_count =
        Enum.count(change_rows, fn row ->
          gutter_bar(row).style.fg == "#FF6762"
        end)

      assert insert_count > 1
      assert delete_count == insert_count

      delete_texts =
        change_rows
        |> Enum.filter(fn row -> gutter_bar(row).style.fg == "#FF6762" end)
        |> Enum.map(&row_text/1)

      assert List.last(delete_texts) =~ "…"
    end
  end

  describe "render/2 (changed-cluster squeeze)" do
    test "a paired long delete squeezes the removed cluster, not the frame" do
      flags =
        Enum.map_join(1..8, ", ", fn i -> ":a_very_long_flag_name_#{i}" end)

      old = "legacy_flags: [" <> flags <> ", :final]"
      new = "legacy_flags: []"

      {:ok, state} =
        DiffViewer.init(old: old, new: new, mode: :unified, width: 60)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | rows] = rendered.children

      delete_rows =
        Enum.filter(rows, fn row -> gutter_bar(row).style[:fg] == "#FF6762" end)

      insert_rows =
        Enum.filter(rows, fn row -> gutter_bar(row).style[:fg] == "#5ECC71" end)

      # the delete borrowed the insert's single-row allocation
      assert length(insert_rows) == 1
      assert length(delete_rows) == 1

      [delete_row] = delete_rows
      [_gutter, content] = delete_row.children
      text = Enum.map_join(content.children, & &1.content)

      # unchanged frame fully visible on BOTH sides of the squeeze
      assert text =~ "legacy_flags: ["
      assert text =~ "…"
      assert String.trim_trailing(text) =~ ~r/\]$/

      # the ellipsis is part of the removed cluster: emphasis tier bg
      squeeze_span =
        Enum.find(content.children, fn span -> span.content == "…" end)

      assert Map.get(squeeze_span.style, :bg) == "#552527"
    end

    test "small changed clusters that already fit are left intact" do
      old = "retries: 0, budget: 5000"
      new = "retries: 3, budget: 9000"

      {:ok, state} =
        DiffViewer.init(old: old, new: new, mode: :unified, width: 60)

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | rows] = rendered.children

      delete_row =
        Enum.find(rows, fn row -> gutter_bar(row).style[:fg] == "#FF6762" end)

      [_gutter, content] = delete_row.children
      text = Enum.map_join(content.children, & &1.content)
      refute text =~ "…"
      assert text =~ "retries: 0"
    end
  end

  describe "render/2 (fold row styling)" do
    test "the unchanged-lines fold row carries no background" do
      lines = Enum.map_join(1..12, "\n", &"line #{&1}")

      {:ok, state} =
        DiffViewer.init(
          old: lines <> "\nOLD TAIL",
          new: lines <> "\nNEW TAIL",
          mode: :unified,
          context: 2
        )

      rendered = DiffViewer.render(state, default_context())
      [_header, _divider | rows] = rendered.children

      fold_row =
        Enum.find(rows, fn row ->
          Enum.any?(row.children, fn child ->
            is_binary(child[:content]) and child[:content] =~ "unchanged"
          end)
        end)

      assert fold_row, "expected a fold row"

      fold_text =
        Enum.find(fold_row.children, fn child ->
          is_binary(child[:content]) and child[:content] =~ "unchanged"
        end)

      refute Map.has_key?(fold_text.style, :bg)
    end
  end

  describe "handle_event/3 (fold vocabulary)" do
    setup do
      {:ok, state} =
        DiffViewer.init(path: "lib/foo.ex", old: "a\nb\nc", new: "a\nx\nc")

      %{state: state}
    end

    test "Enter toggles the compact fold on and back off", %{state: state} do
      refute state.folded

      {folded, []} =
        DiffViewer.handle_event(
          %Event{type: :key, data: %{key: :enter}},
          state,
          %{}
        )

      assert folded.folded

      {unfolded, []} =
        DiffViewer.handle_event(
          %Event{type: :key, data: %{key: :enter}},
          folded,
          %{}
        )

      refute unfolded.folded
      assert unfolded == state
    end

    test "Space toggles the fold too", %{state: state} do
      {folded, []} =
        DiffViewer.handle_event(
          %Event{type: :key, data: %{key: :space}},
          state,
          %{}
        )

      assert folded.folded
    end

    test "toggling changes nothing but the fold flag", %{state: state} do
      {folded, []} =
        DiffViewer.handle_event(
          %Event{type: :key, data: %{key: :enter}},
          state,
          %{}
        )

      assert Map.delete(folded, :folded) == Map.delete(state, :folded)
    end

    test "other keys and non-events pass through unchanged", %{state: state} do
      {same, []} =
        DiffViewer.handle_event(
          %Event{type: :key, data: %{key: :char, char: "x"}},
          state,
          %{}
        )

      assert same == state

      {still_same, []} = DiffViewer.handle_event(:whatever, state, %{})
      assert still_same == state
    end
  end

  describe "render/2 (folded compact form)" do
    setup do
      {:ok, state} =
        DiffViewer.init(
          id: "dv_folded",
          path: "lib/foo.ex",
          old: "a\nb\nc",
          new: "a\nx\nc",
          folded: true
        )

      %{state: state}
    end

    test "renders the one-line compact form: ± path · +N -M", %{state: state} do
      rendered = DiffViewer.render(state, default_context())

      assert rendered.type == :column
      assert [row] = rendered.children

      contents = Enum.map(row.children, & &1.content)
      assert contents == ["±", "lib/foo.ex", "·", "+1", "-1"]
    end

    test "the path leads the compact line (path-first, before counts)", %{
      state: state
    } do
      rendered = DiffViewer.render(state, default_context())
      [row] = rendered.children
      contents = Enum.map(row.children, & &1.content)

      path_index = Enum.find_index(contents, &(&1 == "lib/foo.ex"))
      plus_index = Enum.find_index(contents, &(&1 == "+1"))
      assert path_index < plus_index
    end

    test "no Pierre body renders while folded", %{state: state} do
      rendered = DiffViewer.render(state, default_context())

      refute tree_text(rendered) =~ "▌"
      refute tree_text(rendered) =~ "Proposed change"
      refute Enum.any?(rendered.children, &(&1[:type] == :divider))
    end

    test "an empty path renders the (no path) placeholder" do
      {:ok, state} = DiffViewer.init(old: "a", new: "b", folded: true)
      rendered = DiffViewer.render(state, default_context())
      [row] = rendered.children
      assert "(no path)" in Enum.map(row.children, & &1.content)
    end
  end

  describe "render/2 (id/attrs stamping)" do
    test "the root node carries id and semantic attrs in both fold states" do
      {:ok, state} =
        DiffViewer.init(
          id: "dv_stamp",
          path: "lib/foo.ex",
          old: "a\nb\nc",
          new: "a\nx\nc"
        )

      expanded = DiffViewer.render(state, default_context())
      assert expanded.id == "dv_stamp"

      assert expanded.attrs == %{
               path: "lib/foo.ex",
               added: 1,
               removed: 1,
               folded: false
             }

      folded = DiffViewer.render(%{state | folded: true}, default_context())
      assert folded.id == "dv_stamp"

      assert folded.attrs == %{
               path: "lib/foo.ex",
               added: 1,
               removed: 1,
               folded: true
             }
    end
  end
end
