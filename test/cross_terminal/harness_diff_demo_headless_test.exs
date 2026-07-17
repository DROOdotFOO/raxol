defmodule Raxol.CrossTerminal.HarnessDiffDemoHeadlessTest do
  @moduledoc """
  End-to-end coverage for `Raxol.Playground.Demos.HarnessDiffDemo` (U1-b,
  harness TEA migration section 7): boots the real demo headless and pins
  the diff block Component's contract at the rendered-buffer level.

  * compact and expanded forms via screenshot -- Enter/Space toggles the
    fold between the full Pierre body and the path-first
    `± path · +N -M` line (the same compact vocabulary as the sealed
    `:diff` block, `Raxol.UI.Components.Harness.Block.diff_line/1`)
  * Pierre styling present in the BUFFER, not just the view tree: `▌`
    gutter bars carry the add/del identity colors and the word-diff
    emphasis background tier reaches cells
  * hunk folding toggled interactively ([f] flips `context` between 3 and
    `:all`)
  * the fixture corpus: multi-hunk, new-file all-adds, no-newline-at-EOF,
    unicode content
  """
  use ExUnit.Case, async: false

  alias Raxol.Headless
  alias Raxol.Playground.Demos.HarnessDiffDemo
  alias Raxol.UI.Components.Harness.DiffViewer

  @settle_ms 80
  @width 160
  @height 55

  setup do
    pid =
      case Process.whereis(Headless) do
        nil -> start_supervised!({Headless, [name: Headless]})
        existing -> existing
      end

    on_exit(fn ->
      if Process.alive?(pid) do
        for id <- GenServer.call(pid, :list_sessions) do
          try do
            GenServer.call(pid, {:stop_session, id}, 2_000)
          catch
            :exit, _ -> :ok
          end
        end
      end
    end)

    :ok
  end

  defp start_demo(id) do
    {:ok, ^id} =
      Headless.start(HarnessDiffDemo, id: id, width: @width, height: @height)

    Process.sleep(@settle_ms)
    id
  end

  defp shot(id) do
    {:ok, text} = Headless.screenshot(id)
    text
  end

  defp press(id, key) do
    :ok = Headless.send_key(id, key)
    Process.sleep(@settle_ms)
  end

  # -- Buffer style helpers ---------------------------------------------------

  defp cells_with_char(buffer, char) do
    buffer.cells
    |> List.flatten()
    |> Enum.filter(&(&1 != nil and &1.char == char))
  end

  defp fg(cell), do: cell.style && Map.get(cell.style, :foreground)
  defp bg(cell), do: cell.style && Map.get(cell.style, :background)

  # The referent is the RGB identity, not its encoding: accept any lossless
  # carrier of the same color ("#RRGGBB" in either case, {r, g, b}, or
  # {:rgb, r, g, b}) so the assert survives representation changes in the
  # cell pipeline without weakening to "any color at all".
  defp color?(value, "#" <> hex) do
    {r, g, b} =
      {String.to_integer(String.slice(hex, 0, 2), 16),
       String.to_integer(String.slice(hex, 2, 2), 16),
       String.to_integer(String.slice(hex, 4, 2), 16)}

    value in [
      "#" <> hex,
      "#" <> String.downcase(hex),
      "#" <> String.upcase(hex),
      {r, g, b},
      {:rgb, r, g, b}
    ]
  end

  defp any_cell_bg?(buffer, hex) do
    buffer.cells
    |> List.flatten()
    |> Enum.any?(&(&1 != nil and color?(bg(&1), hex)))
  end

  # -- Fold toggle: compact <-> expanded --------------------------------------

  test "boots expanded, Enter folds to the compact ± line, Enter expands back" do
    id = start_demo(:hdd_fold)

    expanded = shot(id)
    assert expanded =~ "Proposed change"
    assert expanded =~ "lib/orders/total.ex"
    assert expanded =~ "Not yet applied"
    assert expanded =~ "▌"

    press(id, :enter)
    folded = shot(id)
    assert folded =~ "± lib/orders/total.ex"
    refute folded =~ "Proposed change"
    refute folded =~ "Not yet applied"
    refute folded =~ "▌"

    press(id, :enter)
    reexpanded = shot(id)
    assert reexpanded =~ "Proposed change"
    assert reexpanded =~ "▌"
    refute reexpanded =~ "± lib/orders/total.ex"
  end

  test "Space folds too" do
    id = start_demo(:hdd_space)

    press(id, :space)
    folded = shot(id)
    assert folded =~ "± lib/orders/total.ex"
    refute folded =~ "Proposed change"
  end

  # -- Pierre styling at the buffer level -------------------------------------

  test "gutter bars carry add/del identity colors and the emphasis tier reaches cells" do
    id = start_demo(:hdd_style)
    {:ok, buffer} = Headless.get_buffer(id)

    palette = DiffViewer.diff_palette()
    bars = cells_with_char(buffer, "▌")
    assert bars != [], "expected ▌ gutter bar cells in the buffer"

    assert Enum.any?(bars, &color?(fg(&1), palette.del_base)),
           "expected a deletion gutter bar with the del identity color"

    assert Enum.any?(bars, &color?(fg(&1), palette.add_base)),
           "expected an insertion gutter bar with the add identity color"

    # Word-diff emphasis needs a PAIRED change run (deletes and inserts in
    # one contiguous hunk). Sample 0's deletes and inserts sit in separate
    # runs (an equal line between them), so it honestly renders no
    # emphasis; sample 1 (within-line replace) is the paired fixture.
    press(id, "s")
    {:ok, paired_buffer} = Headless.get_buffer(id)

    assert any_cell_bg?(paired_buffer, palette.del_emphasis_bg),
           "expected the del emphasis bg tier in the buffer"

    assert any_cell_bg?(paired_buffer, palette.add_emphasis_bg),
           "expected the add emphasis bg tier in the buffer"
  end

  # -- Hunk folding -----------------------------------------------------------

  test "[f] unfolds the long unchanged run and folds it back" do
    id = start_demo(:hdd_hunks)

    assert shot(id) =~ "unchanged line"

    press(id, "f")
    refute shot(id) =~ "unchanged line"

    press(id, "f")
    assert shot(id) =~ "unchanged line"
  end

  # -- Fixture corpus ---------------------------------------------------------

  test "sample cycling reaches multi-hunk, all-adds, no-newline-at-EOF, and unicode fixtures" do
    id = start_demo(:hdd_fixtures)

    # 8x [s]: from sample 0 to the multi-hunk fixture.
    for _ <- 1..8, do: press(id, "s")
    multi_hunk = shot(id)
    assert multi_hunk =~ "multi-hunk"
    assert multi_hunk =~ "stage_one"
    assert multi_hunk =~ "stage_two"
    assert multi_hunk =~ "unchanged line"

    press(id, "s")
    all_adds = shot(id)
    assert all_adds =~ "BrandNew"
    # 4 inserts: 3 content lines plus the trailing-newline empty line
    # (LineDiff treats "" as zero lines, so nothing pairs or deletes).
    assert all_adds =~ "+4"
    assert all_adds =~ "-0"

    {:ok, buffer} = Headless.get_buffer(id)
    palette = DiffViewer.diff_palette()
    bars = cells_with_char(buffer, "▌")
    assert bars != []

    assert Enum.all?(bars, &color?(fg(&1), palette.add_base)),
           "a new-file diff must carry only insertion gutter bars"

    press(id, "s")
    no_newline = shot(id)
    assert no_newline =~ "omega!"
    assert no_newline =~ "+2"
    assert no_newline =~ "-1"

    press(id, "s")
    unicode = shot(id)

    # `get_text` renders each wide char's shadow cell as a space (cell-grid
    # extraction semantics), so the joined string is NOT contiguous; assert
    # per-char presence here and pin the true contract -- every kana/han
    # grapheme advancing exactly 2 columns -- at the cell level below.
    # (Kana were measured 1 column before the CharacterHandling fix this
    # fixture caught; see character_handling_test.exs.)
    for char <- ~w(こ ん に ち は 世 界 双 幅 文 字 テ ス ト) do
      assert unicode =~ char
    end

    {:ok, unicode_buffer} = Headless.get_buffer(id)

    for wide_run <- ["こんにちは世界", "双幅文字テスト"] do
      graphemes = String.graphemes(wide_run)
      positions = grapheme_run_positions(unicode_buffer, graphemes)

      assert length(positions) == length(graphemes),
             "expected #{wide_run} on one row, got: #{inspect(positions)}"

      positions
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.each(fn [{_ch1, x1}, {_ch2, x2}] ->
        assert x2 - x1 == 2,
               "wide chars must advance 2 columns, got #{x1} -> #{x2} in #{wide_run}"
      end)
    end
  end

  # The [{char, x}] positions of `graphemes` on the single row that
  # contains the run's first grapheme, in x order.
  defp grapheme_run_positions(buffer, [first | _] = graphemes) do
    row =
      Enum.find(buffer.cells, fn row ->
        Enum.any?(row, &(&1 != nil and &1.char == first))
      end)

    for {cell, x} <- Enum.with_index(row || []),
        cell != nil and cell.char in graphemes,
        do: {cell.char, x}
  end
end
