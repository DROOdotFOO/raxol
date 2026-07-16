defmodule Raxol.Harness.TbScrollbackSpikeTest do
  @moduledoc """
  TE's permanent regression net, living in TB's suite (merge order: TE —
  feat/harness-ui-TE, the emulator scrollback-feed fix — lands before TB,
  so these assertions describe the behavior present in this branch's base
  once both are merged; standalone against origin/master they are
  expected-red).

  History: this file began as the characterization test for
  `harness-ui-testing/02-renderer.md` open question 1 — "does the emulator
  migrate region-scrolled rows into `scrollback_buffer`?" — and originally
  pinned the answer NO (both live scroll paths blanked evicted rows). TE
  closed that hole; these tests now assert the NEW behavior and guard it:

    * a TOP-ANCHORED scroll region (pre-scroll top == 0, screen row 1,
      including the no-region/full-screen case) feeds its evictions into
      `scrollback_buffer`, OLDEST-FIRST (`get_scrollback(E) ++ on-screen
      rows` reads as one continuous history — exactly the shape
      `SealOracle.history/3` consumes), trimming the oldest entries at
      `scrollback_limit`;
    * an INTERIOR region (top > 0) discards evictions, matching xterm
      (split-pane/status-line scrolls were never meant to become history);
    * the ALTERNATE screen buffer never feeds scrollback, regardless of
      region.

  This closes the eviction hole previously documented on
  `SealOracle.history/3`: with TE in the base, evicted sealed rows stay
  comparable, so the seal-once immutable-prefix oracle is valid past
  region capacity (T2b's R-P1 1k-block stream) and O2 no longer
  false-passes rewrites of evicted rows.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.{Emulator, ScreenBuffer}

  defp write_row(buffer, y, text) do
    text
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(buffer, fn {ch, x}, buf ->
      ScreenBuffer.write_char(buf, x, y, ch)
    end)
  end

  defp row_text(row_cells) do
    row_cells |> Enum.map_join("", &(&1.char || " ")) |> String.trim_trailing()
  end

  defp row_contains?(row_cells, substr) do
    String.contains?(row_text(row_cells), substr)
  end

  test "Commands.Screen.scroll_up: top-anchored region scroll feeds scrollback, oldest-first" do
    emulator = Emulator.new(10, 5)
    buffer = Emulator.get_screen_buffer(emulator)
    # Top-anchored region = rows 0..2 (0-based); rows 3..4 stand in for the
    # footer.
    buffer = ScreenBuffer.set_scroll_region(buffer, {0, 2})
    buffer = write_row(buffer, 0, "TOPROW")
    buffer = write_row(buffer, 1, "SECOND")
    emulator = Emulator.update_active_buffer(emulator, buffer)

    assert Emulator.get_scrollback(emulator) == []

    emulator = Raxol.Terminal.Commands.Screen.scroll_up(emulator, 2)

    # Both evicted rows land in scrollback, OLDEST-FIRST.
    assert emulator |> Emulator.get_scrollback() |> Enum.map(&row_text/1) ==
             ["TOPROW", "SECOND"]

    # The rows MOVED into scrollback (scrolled off), they were not copied.
    refute emulator
           |> Emulator.get_screen_buffer()
           |> Map.fetch!(:cells)
           |> Enum.any?(&row_contains?(&1, "TOPROW"))
  end

  test "Operations.ScrollOperations.scroll_up: top-anchored eviction is preserved, not discarded" do
    emulator = Emulator.new(10, 5)
    buffer = Emulator.get_screen_buffer(emulator)
    buffer = ScreenBuffer.set_scroll_region(buffer, {0, 2})
    buffer = write_row(buffer, 0, "EVICTME")
    emulator = Emulator.update_active_buffer(emulator, buffer)

    assert Emulator.get_scrollback(emulator) == []

    emulator = Raxol.Terminal.Operations.ScrollOperations.scroll_up(emulator, 1)

    assert [evicted] = Emulator.get_scrollback(emulator)
    assert row_contains?(evicted, "EVICTME")

    refute emulator
           |> Emulator.get_screen_buffer()
           |> Map.fetch!(:cells)
           |> Enum.any?(&row_contains?(&1, "EVICTME"))
  end

  test "interior region (top > 0) discards evictions — split-pane scrolls never become history" do
    emulator = Emulator.new(10, 5)
    buffer = Emulator.get_screen_buffer(emulator)
    # Interior region: rows 1..3 (0-based top = 1).
    buffer = ScreenBuffer.set_scroll_region(buffer, {1, 3})
    buffer = write_row(buffer, 1, "INTERIOR")
    emulator = Emulator.update_active_buffer(emulator, buffer)

    emulator = Raxol.Terminal.Commands.Screen.scroll_up(emulator, 1)

    assert Emulator.get_scrollback(emulator) == []
  end

  test "alternate screen never feeds scrollback, even with a top-anchored region" do
    emulator = Emulator.new(10, 5)

    emulator =
      Raxol.Terminal.Emulator.BufferOperations.switch_to_alternate_buffer(
        emulator
      )

    buffer = Emulator.get_screen_buffer(emulator)
    buffer = ScreenBuffer.set_scroll_region(buffer, {0, 2})
    buffer = write_row(buffer, 0, "ALTROW")
    emulator = Emulator.update_active_buffer(emulator, buffer)

    emulator = Raxol.Terminal.Commands.Screen.scroll_up(emulator, 1)

    assert Emulator.get_scrollback(emulator) == []
  end

  # Formerly tagged :pending_te/:skip — activated live now that TE precedes
  # TB in the merge order. The oracle-level closure of the eviction hole:
  # sealed rows scrolled past region capacity stay comparable through
  # SealOracle.history/3's high-water window.
  test "oracle-level: eviction keeps sealed rows comparable via history/3's high-water window" do
    emulator = Emulator.new(20, 5)
    buffer = Emulator.get_screen_buffer(emulator)
    # Top-anchored region rows 0..2 (region_top = 3 history rows), sealed
    # to capacity.
    buffer = ScreenBuffer.set_scroll_region(buffer, {0, 2})
    buffer = write_row(buffer, 0, "line one")
    buffer = write_row(buffer, 1, "line two")
    buffer = write_row(buffer, 2, "line three")
    emulator = Emulator.update_active_buffer(emulator, buffer)

    # Seal a fourth line: scroll makes room (evicting "line one"), then the
    # new line lands on the freed bottom region row.
    emulator = Raxol.Terminal.Commands.Screen.scroll_up(emulator, 1)
    buffer = Emulator.get_screen_buffer(emulator)
    buffer = write_row(buffer, 2, "line four")
    emulator = Emulator.update_active_buffer(emulator, buffer)

    # TE's acceptance at the oracle level: the emit-derived high-water
    # window (4 sealed lines) is fully backed by comparable rows —
    # scrollback + on-screen region rows — in one continuous, in-order
    # history.
    history = SealOracle.history(emulator, 3, high_water: 4)

    assert Enum.map(history, &row_text/1) ==
             ["line one", "line two", "line three", "line four"]
  end
end
