defmodule Raxol.UI.ScrollWindowTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.ScrollWindow

  describe "window/4" do
    test "fits entirely: no scroll, not overflown, no thumb" do
      items = Enum.to_list(1..5)
      w = ScrollWindow.window(items, 2, 10, 0)

      assert w.visible == items
      assert w.scroll_top == 0
      assert w.cursor_row == 2
      refute w.overflown?
      assert w.thumb == nil
    end

    test "cursor at top of an overflowing list: no scroll needed" do
      items = Enum.to_list(1..20)
      w = ScrollWindow.window(items, 0, 10, 0)

      assert w.visible == Enum.to_list(1..10)
      assert w.scroll_top == 0
      assert w.cursor_row == 0
      assert w.overflown?
      assert w.thumb != nil
    end

    test "cursor within the current window: scroll position unchanged" do
      items = Enum.to_list(1..20)
      w = ScrollWindow.window(items, 8, 10, 5)

      assert w.scroll_top == 5
      assert w.cursor_row == 3
      assert w.visible == Enum.to_list(6..15)
    end

    test "cursor steps onto the last visible row: scroll advances by exactly 1, cursor stays on the same screen row" do
      items = Enum.to_list(1..20)
      # cursor 9 is the last visible row when scroll_top is 0 (rows 0..9)
      before = ScrollWindow.window(items, 9, 10, 0)
      assert before.scroll_top == 0
      assert before.cursor_row == 9

      after_ = ScrollWindow.window(items, 10, 10, before.scroll_top)
      assert after_.scroll_top == 1
      assert after_.cursor_row == 9
      assert after_.visible == Enum.to_list(2..11)
    end

    test "cursor steps onto the first visible row scrolling up: mirrors the down case" do
      items = Enum.to_list(1..20)
      before = ScrollWindow.window(items, 10, 10, 1)
      assert before.scroll_top == 1
      assert before.cursor_row == 9

      after_ = ScrollWindow.window(items, 9, 10, before.scroll_top)
      assert after_.scroll_top == 1
      assert after_.cursor_row == 8

      up_again = ScrollWindow.window(items, 0, 10, 1)
      assert up_again.scroll_top == 0
      assert up_again.cursor_row == 0
    end

    test "cursor jump far outside the window (e.g. Home/End) resets scroll rather than crawling" do
      items = Enum.to_list(1..100)
      w = ScrollWindow.window(items, 0, 10, 80)
      assert w.scroll_top == 0
      assert w.cursor_row == 0

      w2 = ScrollWindow.window(items, 99, 10, 0)
      assert w2.scroll_top == 90
      assert w2.cursor_row == 9
    end

    test "cursor is clamped to item bounds" do
      items = Enum.to_list(1..5)
      w = ScrollWindow.window(items, 999, 10, 0)
      assert w.cursor_row == 4

      w2 = ScrollWindow.window(items, -5, 10, 0)
      assert w2.cursor_row == 0
    end

    test "stale/out-of-range prev_scroll_top self-heals" do
      items = Enum.to_list(1..20)
      w = ScrollWindow.window(items, 0, 10, -50)
      assert w.scroll_top == 0

      w2 = ScrollWindow.window(items, 0, 10, 999)
      assert w2.scroll_top == 0
    end

    test "empty items list never crashes" do
      w = ScrollWindow.window([], 0, 10, 0)
      assert w.visible == []
      assert w.cursor_row == 0
      refute w.overflown?
      assert w.thumb == nil
    end

    test "visible_height of 0 or negative is treated as 1" do
      items = Enum.to_list(1..5)
      w = ScrollWindow.window(items, 0, 0, 0)
      assert length(w.visible) == 1
    end
  end

  describe "thumb/3" do
    test "nil when content fits" do
      assert ScrollWindow.thumb(0, 10, 10) == nil
      assert ScrollWindow.thumb(0, 10, 5) == nil
    end

    test "thumb spans the track proportionally to scroll position" do
      # 20 rows of content in a 5-row track: thumb_size = max(1, div(25,20)) = 1
      assert ScrollWindow.thumb(0, 5, 20) == {0, 1}
      # at max scroll (15), thumb sits at the last row of the track
      assert ScrollWindow.thumb(15, 5, 20) == {4, 1}
    end

    test "thumb size grows with the visible fraction of content" do
      # 10 rows of content in an 8-row track: thumb_size = max(1, div(64,10)) = 6
      {_start, size} = ScrollWindow.thumb(0, 8, 10)
      assert size == 6
    end
  end

  describe "property: cursor-follow invariants" do
    property "cursor_row always lands within the visible window" do
      check all(
              total <- integer(0..60),
              visible_height <- integer(1..20),
              cursor <- integer(-10..70),
              prev_scroll_top <- integer(-10..70),
              max_runs: 300
            ) do
        items = Enum.to_list(1..total//1)
        w = ScrollWindow.window(items, cursor, visible_height, prev_scroll_top)

        assert w.cursor_row >= 0
        assert w.cursor_row < visible_height
        assert length(w.visible) <= visible_height
        assert w.scroll_top >= 0
        assert w.scroll_top <= max(total - visible_height, 0)
      end
    end

    property "thumb is nil exactly when the list fits, and set exactly when overflown" do
      check all(
              total <- integer(0..60),
              visible_height <- integer(1..20),
              cursor <- integer(0..60),
              prev_scroll_top <- integer(0..60),
              max_runs: 300
            ) do
        items = Enum.to_list(1..total//1)
        w = ScrollWindow.window(items, cursor, visible_height, prev_scroll_top)

        assert w.overflown? == total > visible_height
        assert w.thumb == nil == not w.overflown?
      end
    end

    property "scroll_top moves by at most 1 when the cursor advances one step at a time from 0" do
      check all(
              total <- integer(1..40),
              visible_height <- integer(1..15),
              max_runs: 200
            ) do
        items = Enum.to_list(1..total//1)
        max_index = total - 1

        Enum.reduce(0..max_index, 0, fn cursor, prev_scroll_top ->
          w =
            ScrollWindow.window(items, cursor, visible_height, prev_scroll_top)

          assert abs(w.scroll_top - prev_scroll_top) <= 1
          w.scroll_top
        end)
      end
    end
  end
end
