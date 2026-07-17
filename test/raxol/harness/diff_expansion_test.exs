defmodule Raxol.Harness.DiffExpansionTest do
  @moduledoc """
  Pure-state suite for `Raxol.Harness.DiffExpansion`: the full-screen
  diff expansion's scrollable window over a pre-rendered, sanitized,
  width-truncated line list.

  Contract pinned here (each test names the moduledoc guarantee it maps
  to):

    * `new/2` renders EXACTLY ONE styled line per visual diff row,
      directly from `LineDiff.diff/2` -- never through the view-tree
      flatten (`ViewText` splits a multi-node row into one line per leaf
      and drops backgrounds entirely, which would break both the row
      math and the diff's visual language).
    * The FULL diff is present (no unchanged-run folding -- a review
      surface never hides context).
    * Added/removed rows carry the merged diff palette's row washes
      (`DiffViewer.diff_palette/0`) as 24-bit SGR backgrounds spanning
      the full row width, plus the `▌` gutter bar -- the diff's own
      visual language at line granularity.
    * `scroll/2` is clamped line math: offset stays within
      `0..max(0, total - view_rows)`.
    * `render_lines/1` is a position header plus the visible slice.
    * Hostile content (agent-produced diff text) never survives to the
      rendered lines as control bytes: after stripping the styling
      layer's own SGR, no ESC/C0 remains (content is sanitized BEFORE
      styling, through the same seam `ViewText` owns).
    * CJK truncation is display-width-honest (TextMeasure, never
      String.length).
    * Degenerate view geometry refuses (`{:error, ...}`), never renders
      a broken window.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.DiffExpansion
  alias Raxol.UI.Components.Harness.{DiffViewer, LineDiff}
  alias Raxol.UI.TextMeasure

  @width 40
  @view_rows 5

  defp content(old, new, extra \\ %{}) do
    Map.merge(
      %{path: "lib/sample.ex", old: old, new: new, language: nil},
      extra
    )
  end

  defp new!(old, new, opts \\ []) do
    opts = Keyword.merge([width: @width, view_rows: @view_rows], opts)
    {:ok, exp} = DiffExpansion.new(content(old, new), opts)
    exp
  end

  # Styling is applied AFTER sanitize/truncation by ViewText's :styled
  # mode -- legitimate SGR (`\e[...m`) is the ONLY escape vocabulary a
  # rendered line may carry. Stripping it must leave zero ESC/C0 bytes
  # (tab excepted: ViewText's own documented C0 exception).
  defp strip_sgr(line), do: String.replace(line, ~r/\e\[[0-9;]*m/, "")

  defp control_free?(line) do
    line
    |> strip_sgr()
    |> String.to_charlist()
    |> Enum.all?(fn ch -> ch == ?\t or (ch >= 0x20 and ch != 0x7F) end)
  end

  # "#RRGGBB" -> the 24-bit SGR background fragment ("48;2;r;g;b") --
  # how the merged palette's hex washes must reach the wire.
  defp bg_sgr("#" <> hex) do
    {r, g, b} =
      {String.slice(hex, 0, 2), String.slice(hex, 2, 2),
       String.slice(hex, 4, 2)}

    "48;2;#{String.to_integer(r, 16)};#{String.to_integer(g, 16)};#{String.to_integer(b, 16)}"
  end

  describe "new/2 renders the full diff, one line per visual row" do
    test "exactly one rendered line per LineDiff op -- the row math the scroll window relies on" do
      old = Enum.map_join(1..12, "\n", &"line #{&1}")
      new = String.replace(old, "line 7", "line seven")

      exp = new!(old, new)

      assert exp.total == length(LineDiff.diff(old, new)),
             "a visual diff row must never split into multiple rendered lines"
    end

    test "long unchanged runs are NOT folded away -- every content line is present" do
      # 30 identical lines with one change at the end: 29 equal ops +
      # 1 delete + 1 insert = 31 rows, all present. A folding renderer
      # would collapse the run into one "N unchanged lines" row.
      old = Enum.map_join(1..30, "\n", &"line #{&1}")
      new = String.replace(old, "line 30", "line thirty")

      exp = new!(old, new)

      assert exp.total == 31

      refute Enum.any?(exp.lines, &(strip_sgr(&1) =~ "unchanged lines")),
             "full-screen expansion must never fold unchanged runs"
    end

    test "refuses a content map missing required diff keys" do
      assert {:error, _reason} =
               DiffExpansion.new(
                 %{path: "x.ex", old: "a"},
                 width: @width,
                 view_rows: @view_rows
               )
    end

    test "refuses degenerate view geometry" do
      assert {:error, _reason} =
               DiffExpansion.new(content("a", "b"),
                 width: @width,
                 view_rows: 0
               )

      assert {:error, _reason} =
               DiffExpansion.new(content("a", "b"),
                 width: 0,
                 view_rows: @view_rows
               )
    end

    test "starts at offset 0 with the requested window" do
      exp = new!("a\nb\nc", "a\nB\nc")
      assert exp.offset == 0
      assert exp.view_rows == @view_rows
      assert exp.width == @width
    end
  end

  describe "gutter width floor (honest refusal, never overflow bytes)" do
    # Every body row prepends a fixed 2-column gutter (`▌` + gap, or two
    # spaces for an `:equal` row), so a row is at least 2 display columns
    # regardless of `width`. `InlineAuthority.repaint/2` does NOT truncate
    # an over-wide line -- it wraps onto the next row (or past the screen
    # bottom on the last footer row), overwriting content. The only honest
    # behavior below the gutter floor is to REFUSE, not to render bytes
    # wider than the column count. Red-first: before the floor,
    # `new(width: 1)` returned `{:ok, _}` whose body rows rendered 2
    # display columns into a 1-column budget.
    test "refuses width 1 -- the exact case where a 2-col gutter overflows a 1-col budget" do
      assert {:error, :degenerate_view} =
               DiffExpansion.new(content("a", "b"), width: 1, view_rows: 4)
    end

    test "refuses width 2 -- fits the gutter but leaves zero content columns" do
      assert {:error, :degenerate_view} =
               DiffExpansion.new(content("a", "b"), width: 2, view_rows: 4)
    end

    test "admits width 3 (the floor: gutter + one content column) and no line overflows it" do
      # A changed diff exercises the widest row shape (gutter bar + padded
      # wash). At the floor width EVERY rendered line -- header included --
      # must fit the column budget exactly, never wrap.
      {:ok, exp} =
        DiffExpansion.new(content("a", "b"), width: 3, view_rows: 4)

      for line <- DiffExpansion.render_lines(exp) do
        assert TextMeasure.display_width(strip_sgr(line)) <= 3,
               "a rendered line overflowed the floor width: #{inspect(line)}"
      end
    end
  end

  describe "scroll/2 clamped line math" do
    setup do
      old = Enum.map_join(1..30, "\n", &"line #{&1}")
      new = String.replace(old, "line 15", "line fifteen")
      {:ok, exp: new!(old, new)}
    end

    test "scrolling down advances the offset by the delta", %{exp: exp} do
      assert DiffExpansion.scroll(exp, 3).offset == 3
    end

    test "scrolling up from the top clamps at 0", %{exp: exp} do
      assert DiffExpansion.scroll(exp, -5).offset == 0

      exp = DiffExpansion.scroll(exp, 2)
      assert DiffExpansion.scroll(exp, -10).offset == 0
    end

    test "scrolling past the end clamps at total - view_rows", %{exp: exp} do
      max_offset = exp.total - exp.view_rows
      assert max_offset > 0

      assert DiffExpansion.scroll(exp, 10_000).offset == max_offset
    end

    test "a diff shorter than the window never scrolls" do
      # "a" -> "b" is exactly two rows (one delete + one insert) under
      # the one-line-per-op contract -- comfortably inside a 5-row window.
      exp = new!("a", "b")
      assert exp.total == 2
      assert DiffExpansion.scroll(exp, 5).offset == 0
    end
  end

  describe "the diff's own visual language (the merged palette)" do
    test "an added row carries the add wash + gutter bar; a removed row the del wash; equal rows neither" do
      exp = new!("one\ntwo", "one\ntwo\nthree")
      # ops: equal, equal, insert
      [equal_line, _equal2, insert_line] = exp.lines

      add_bg = bg_sgr(DiffViewer.diff_palette().add_row_bg)
      del_bg = bg_sgr(DiffViewer.diff_palette().del_row_bg)

      assert insert_line =~ add_bg,
             "an added row must carry the merged palette's add wash"

      assert strip_sgr(insert_line) =~ "▌",
             "an added row must carry the gutter bar"

      refute equal_line =~ add_bg
      refute equal_line =~ del_bg

      exp_del = new!("one\ntwo", "one")
      # ops: equal, delete
      [_equal, delete_line] = exp_del.lines

      assert delete_line =~ del_bg,
             "a removed row must carry the merged palette's del wash"

      assert strip_sgr(delete_line) =~ "▌"
    end

    test "a changed row's wash spans the full width (padded, not just under the text)" do
      exp = new!("base", "other")
      # ops: delete "base", insert "other"
      [delete_line, insert_line] = exp.lines

      for line <- [delete_line, insert_line] do
        assert TextMeasure.display_width(strip_sgr(line)) == @width,
               "the row wash must paint the whole row, not stop at the text"
      end
    end
  end

  describe "render_lines/1 windowing" do
    setup do
      old = Enum.map_join(1..30, "\n", &"line #{&1}")
      {:ok, exp: new!(old, old <> "\nline 31")}
    end

    test "returns one header line plus exactly the visible slice", %{exp: exp} do
      rendered = DiffExpansion.render_lines(exp)
      assert length(rendered) == exp.view_rows + 1

      [_header | body] = rendered
      assert body == Enum.slice(exp.lines, 0, exp.view_rows)
    end

    test "the window follows the scroll offset", %{exp: exp} do
      scrolled = DiffExpansion.scroll(exp, 4)
      [_header | body] = DiffExpansion.render_lines(scrolled)
      assert body == Enum.slice(exp.lines, 4, exp.view_rows)
    end

    test "the header carries the scroll position and the dismiss hint", %{
      exp: exp
    } do
      [header | _body] = DiffExpansion.render_lines(exp)
      plain = strip_sgr(header)
      assert plain =~ "/#{exp.total}"
      assert plain =~ "esc"
    end

    test "the header carries the file path -- full-screen review hides the transcript context that named it",
         %{exp: exp} do
      [header | _body] = DiffExpansion.render_lines(exp)
      assert strip_sgr(header) =~ "lib/sample.ex"
    end

    test "every rendered line fits the width budget (display width, not bytes)",
         %{exp: exp} do
      for line <- DiffExpansion.render_lines(exp) do
        assert TextMeasure.display_width(strip_sgr(line)) <= exp.width
      end
    end
  end

  describe "CJK-safe truncation" do
    test "double-width characters never overflow the width budget" do
      wide_line = String.duplicate("日本語テキスト", 10)
      exp = new!("", wide_line, width: 21)

      for line <- DiffExpansion.render_lines(exp) do
        assert TextMeasure.display_width(strip_sgr(line)) <= 21,
               "CJK line overflowed the width budget: #{inspect(line)}"
      end
    end
  end

  describe "hostile diff content (agent-produced text)" do
    test "control bytes and escape sequences never survive to rendered lines" do
      hostile =
        Enum.join(
          [
            "\e[2Jwipe attempt",
            "\e[?1049halt-screen attempt",
            "\e]0;title injection\abody",
            "bell\a and null\x00 and cr\r mixed",
            "del\x7fbyte"
          ],
          "\n"
        )

      exp = new!("", hostile)

      for line <- exp.lines ++ DiffExpansion.render_lines(exp) do
        assert control_free?(line),
               "control bytes leaked into a rendered line: #{inspect(line)}"
      end

      joined = Enum.join(exp.lines, "")
      refute joined =~ "\e[2J"
      refute joined =~ "\e[?1049"
      refute joined =~ "\e]"
    end
  end

  describe "resize_view/3" do
    test "re-renders at the new geometry and clamps the offset" do
      old = Enum.map_join(1..30, "\n", &"line #{&1}")
      exp = new!(old, old <> "\nline 31")
      exp = DiffExpansion.scroll(exp, 10_000)
      max_before = exp.offset

      {:ok, resized} = DiffExpansion.resize_view(exp, 30, exp.total + 10)
      assert resized.width == 30
      assert resized.offset == 0, "a window taller than the diff clamps to 0"

      {:ok, narrower} = DiffExpansion.resize_view(exp, 30, @view_rows)
      assert narrower.offset <= max_before

      for line <- DiffExpansion.render_lines(narrower) do
        assert TextMeasure.display_width(strip_sgr(line)) <= 30
      end
    end

    test "refuses degenerate geometry" do
      exp = new!("a", "b")
      assert {:error, _} = DiffExpansion.resize_view(exp, @width, 0)
      assert {:error, _} = DiffExpansion.resize_view(exp, 0, @view_rows)
    end

    test "refuses a resize below the gutter width floor, leaving t untouched" do
      # A resize down to a sub-floor width must refuse exactly like `new/2`
      # rather than re-render body rows wider than the new column count.
      exp = new!("a", "b")

      assert {:error, :degenerate_view} =
               DiffExpansion.resize_view(exp, 1, @view_rows)

      assert {:error, :degenerate_view} =
               DiffExpansion.resize_view(exp, 2, @view_rows)
    end
  end
end
