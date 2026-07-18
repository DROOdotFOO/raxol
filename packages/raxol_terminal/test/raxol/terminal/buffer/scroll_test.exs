defmodule Raxol.Terminal.Buffer.ScrollTest do
  use ExUnit.Case, async: true
  alias Raxol.Terminal.Buffer.Scroll
  alias Raxol.Terminal.Cell

  describe "new/2" do
    test ~c"creates a new scroll buffer with default values" do
      scroll = Scroll.new(1000)
      assert scroll.buffer == []
      assert scroll.position == 0
      assert scroll.height == 0
      assert scroll.max_height == 1000
      assert scroll.compression_ratio == 1.0
      assert scroll.memory_limit == 5_000_000
      assert scroll.memory_usage == 0
    end

    test ~c"creates a new scroll buffer with custom memory limit" do
      scroll = Scroll.new(1000, 1_000_000)
      assert scroll.memory_limit == 1_000_000
    end
  end

  describe "add_line/2" do
    test ~c"adds a line to the scroll buffer" do
      scroll = Scroll.new(1000)
      line = [Cell.new("A"), Cell.new("B")]
      scroll = Scroll.add_line(scroll, line)

      assert scroll.height == 1
      assert length(scroll.buffer) == 1
      assert hd(scroll.buffer) == line
    end

    test ~c"trims buffer when it exceeds max height" do
      # Small max height for testing
      scroll = Scroll.new(2)

      # Add three lines
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.add_line(scroll, [Cell.new("C")])

      assert scroll.height == 2
      assert length(scroll.buffer) == 2
      assert hd(scroll.buffer) == [Cell.new("C")]
      assert hd(tl(scroll.buffer)) == [Cell.new("B")]
    end

    # Skipped test removed: compression logic not implemented and not planned.
  end

  describe "get_view/2" do
    test ~c"gets a view of the scroll buffer at the current position" do
      scroll = Scroll.new(1000)

      # Add three lines
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.add_line(scroll, [Cell.new("C")])

      # Get a view of height 2
      view = Scroll.get_view(scroll, 2)

      assert length(view) == 2
      assert hd(view) == [Cell.new("C")]
      assert hd(tl(view)) == [Cell.new("B")]
    end

    test ~c"returns empty list when position is beyond buffer height" do
      scroll = Scroll.new(1000)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      # Scroll beyond buffer height
      scroll = Scroll.scroll(scroll, 10)

      view = Scroll.get_view(scroll, 2)
      assert view == []
    end

    test ~c"returns partial view when near the end of the buffer" do
      scroll = Scroll.new(1000)

      # Add three lines
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.add_line(scroll, [Cell.new("C")])

      # Get a view of height 5 (larger than buffer)
      view = Scroll.get_view(scroll, 5)

      assert length(view) == 3
      assert hd(view) == [Cell.new("C")]
      assert hd(tl(view)) == [Cell.new("B")]
      assert hd(tl(tl(view))) == [Cell.new("A")]
    end
  end

  describe "scroll/2" do
    test ~c"scrolls the buffer by the given amount" do
      scroll = Scroll.new(1000)
      # Add 5 lines so the buffer height is at least 5
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.add_line(scroll, [Cell.new("C")])
      scroll = Scroll.add_line(scroll, [Cell.new("D")])
      scroll = Scroll.add_line(scroll, [Cell.new("E")])
      scroll = Scroll.scroll(scroll, 5)
      assert scroll.position == 5
    end

    test ~c"does not scroll beyond buffer bounds" do
      scroll = Scroll.new(1000)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.scroll(scroll, 10)
      # Can scroll up to height (which is 1 here), but not beyond.
      assert scroll.position == 1
    end

    test ~c"handles negative scroll amounts" do
      scroll = Scroll.new(1000)
      # Add lines first so height > 0
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.add_line(scroll, [Cell.new("C")])
      scroll = Scroll.add_line(scroll, [Cell.new("D")])
      # Height is 5
      scroll = Scroll.add_line(scroll, [Cell.new("E")])
      # Scroll to bottom (pos 5)
      scroll = Scroll.scroll(scroll, 5)
      # Scroll up 3
      scroll = Scroll.scroll(scroll, -3)
      assert scroll.position == 2
    end
  end

  describe "get_position/1" do
    test ~c"gets the current scroll position" do
      scroll = Scroll.new(1000)
      # Add 5 lines so the buffer height is at least 5
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.add_line(scroll, [Cell.new("C")])
      scroll = Scroll.add_line(scroll, [Cell.new("D")])
      scroll = Scroll.add_line(scroll, [Cell.new("E")])
      scroll = Scroll.scroll(scroll, 5)
      assert Scroll.get_position(scroll) == 5
    end
  end

  describe "get_height/1" do
    test ~c"gets the total height of the scroll buffer" do
      scroll = Scroll.new(1000)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      assert Scroll.get_height(scroll) == 2
    end
  end

  describe "clear/1" do
    test ~c"clears the scroll buffer" do
      scroll = Scroll.new(1000)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.scroll(scroll, 1)

      scroll = Scroll.clear(scroll)

      assert scroll.buffer == []
      assert scroll.position == 0
      assert scroll.height == 0
      assert scroll.memory_usage == 0
    end
  end

  describe "get_view/2 idempotence" do
    test ~c"returns consistent view results across repeated calls" do
      scroll = Scroll.new(1000)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])

      assert Scroll.get_view(scroll, 1) == Scroll.get_view(scroll, 1)
    end
  end

  describe "scroll/3" do
    test ~c"scrolls up" do
      scroll = Scroll.new(1000)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.scroll(scroll, 1)

      scroll = Scroll.scroll(scroll, :up, 1)
      assert scroll.position == 0
    end

    test ~c"scrolls down" do
      scroll = Scroll.new(1000)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])

      scroll = Scroll.scroll(scroll, :down, 1)
      assert scroll.position == 1
    end
  end

  describe "set_scroll_region/3" do
    test "sets valid scroll region" do
      scroll = Scroll.new(1000)
      scroll = Scroll.set_scroll_region(scroll, 1, 5)
      assert scroll.scroll_region == {1, 5}
    end

    test "ignores invalid scroll region" do
      scroll = Scroll.new(1000)
      scroll = Scroll.set_scroll_region(scroll, 5, 1)
      assert scroll.scroll_region == nil
    end
  end

  describe "clear_scroll_region/1" do
    test "clears scroll region" do
      scroll = Scroll.new(1000)
      scroll = Scroll.set_scroll_region(scroll, 1, 5)
      scroll = Scroll.clear_scroll_region(scroll)
      assert scroll.scroll_region == nil
    end
  end

  describe "set_max_height/2" do
    test ~c"updates max height and trims buffer if needed" do
      scroll = Scroll.new(3)
      scroll = Scroll.add_line(scroll, [Cell.new("A")])
      scroll = Scroll.add_line(scroll, [Cell.new("B")])
      scroll = Scroll.add_line(scroll, [Cell.new("C")])

      scroll = Scroll.set_max_height(scroll, 2)
      assert scroll.max_height == 2
      assert scroll.height == 2
      assert scroll.buffer == [[Cell.new("C")], [Cell.new("B")]]
    end
  end

  describe "resize/2" do
    test ~c"updates height" do
      scroll = Scroll.new(1000)
      scroll = Scroll.resize(scroll, 50)
      assert scroll.height == 50
    end
  end
end
