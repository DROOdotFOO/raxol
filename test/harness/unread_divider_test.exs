defmodule Raxol.Harness.UnreadDividerTest do
  @moduledoc """
  Policy suite for `Raxol.Harness.UnreadDivider` -- the pure unread-divider
  decision module (honesty family): when an operator looks away and sealed
  blocks keep arriving, a visible "new since you looked" rule marks the
  attention boundary in the LIVE region (the repaintable footer viewport),
  never in sealed history (the in-history divider is the deferred
  reflow-capable upgrade, explicitly out of scope for v1).

  ## The contract this suite pins

    * **Offsets, not clocks.** Every decision is a pure function of
      caller-injected offsets (the assembled surface feeds completed-block
      counts). There is no wall clock, no timestamp, no gap threshold
      anywhere in the policy -- stricter than the status strip's
      injected-`now` convention, because the divider needs no time at all.
    * **Attention machine.** `:attending` (default) -> `blur/2` records the
      boundary (everything before it was seen) -> `focus/2` (or the
      keystroke fallback `input_activity/2`) opens ONE span
      `%{from: boundary, count: offset - boundary}` when content arrived
      unattended, else silently returns to `:attending`.
    * **One divider per unattended span.** Repeated blurs while away keep
      the EARLIEST boundary; a re-blur while a span is still active merges
      (the boundary stays at the oldest block the operator never visited),
      because retiring an unvisited boundary would silently un-mark unread
      content.
    * **Count frozen at return.** Blocks arriving while the operator is
      demonstrably watching are not "new since you looked".
    * **Clears on scroll-past only.** `viewed/2` with a block index at or
      past the boundary retires the span. Keystrokes never clear it
      (typing is presence evidence, not reading evidence).
    * **Rendering is width-exact.** `line/2` produces a full-width `─`
      rule sized via `Raxol.UI.TextMeasure` (never `String.length`); a
      width smaller than the label degrades to the bare label for the
      caller's ViewText truncation to handle.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.UnreadDivider
  alias Raxol.UI.TextMeasure

  # -- attention machine: the ratified acceptance ------------------------

  describe "blur -> events -> focus (the ratified acceptance)" do
    test "blur at 2, three blocks arrive, focus at 5 opens a span of 3 before them" do
      span =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.focus(5)
        |> UnreadDivider.divider()

      assert span == %{from: 2, count: 3}
    end

    test "focus with nothing new since blur opens no span" do
      state =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.focus(2)

      assert UnreadDivider.divider(state) == nil
    end

    test "focus without any prior blur is a no-op" do
      state = UnreadDivider.new() |> UnreadDivider.focus(7)
      assert UnreadDivider.divider(state) == nil
    end

    test "a fresh policy starts attending with no divider" do
      assert UnreadDivider.divider(UnreadDivider.new()) == nil
    end
  end

  describe "one divider per unattended span" do
    test "repeated blurs while away keep the earliest boundary" do
      span =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.blur(4)
        |> UnreadDivider.focus(6)
        |> UnreadDivider.divider()

      assert span == %{from: 2, count: 4}
    end

    test "re-blur with a live span merges: the boundary stays at the oldest unvisited block" do
      span =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.focus(5)
        |> UnreadDivider.blur(7)
        |> UnreadDivider.focus(9)
        |> UnreadDivider.divider()

      assert span == %{from: 2, count: 7},
             "an unvisited boundary must never be silently abandoned by a later span"
    end

    test "after a scroll-past clear, the next span starts fresh from the new boundary" do
      span =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.focus(5)
        |> UnreadDivider.viewed(4)
        |> UnreadDivider.blur(6)
        |> UnreadDivider.focus(8)
        |> UnreadDivider.divider()

      assert span == %{from: 6, count: 2}
    end
  end

  describe "count frozen at return" do
    test "the span does not grow while the operator is attending again" do
      state =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.focus(5)

      # More content arrives while demonstrably watching: focus/input at a
      # later offset must not inflate the frozen count.
      state = UnreadDivider.input_activity(state, 9)
      assert UnreadDivider.divider(state) == %{from: 2, count: 3}
    end
  end

  describe "the keystroke fallback (input_activity/2)" do
    test "acts as focus when away: blur -> events -> keystroke opens the span" do
      span =
        UnreadDivider.new()
        |> UnreadDivider.blur(1)
        |> UnreadDivider.input_activity(4)
        |> UnreadDivider.divider()

      assert span == %{from: 1, count: 3}
    end

    test "never clears an active span: typing is presence, not reading" do
      state =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.focus(5)
        |> UnreadDivider.input_activity(5)
        |> UnreadDivider.input_activity(5)

      assert UnreadDivider.divider(state) == %{from: 2, count: 3}
    end

    test "is a no-op while attending with no span" do
      state = UnreadDivider.new() |> UnreadDivider.input_activity(9)
      assert UnreadDivider.divider(state) == nil
    end
  end

  describe "clears on scroll-past (viewed/2)" do
    setup do
      state =
        UnreadDivider.new()
        |> UnreadDivider.blur(2)
        |> UnreadDivider.focus(5)

      %{state: state}
    end

    test "navigating to the boundary block retires the span", %{state: state} do
      assert state |> UnreadDivider.viewed(2) |> UnreadDivider.divider() == nil
    end

    test "navigating past the boundary retires the span", %{state: state} do
      assert state |> UnreadDivider.viewed(4) |> UnreadDivider.divider() == nil
    end

    test "navigating strictly before the boundary keeps the span", %{
      state: state
    } do
      assert state |> UnreadDivider.viewed(1) |> UnreadDivider.divider() ==
               %{from: 2, count: 3}
    end

    test "viewed with no active span is a no-op" do
      state = UnreadDivider.new() |> UnreadDivider.viewed(3)
      assert UnreadDivider.divider(state) == nil
    end
  end

  describe "defensive boundaries" do
    test "focus at an offset below the recorded boundary clears the away state without a span" do
      # Offsets are monotone from the one caller (block counts only grow);
      # a regression handing a smaller offset must fail safe (no divider,
      # no crash, no negative count), never render "-1 new".
      state =
        UnreadDivider.new()
        |> UnreadDivider.blur(5)
        |> UnreadDivider.focus(3)

      assert UnreadDivider.divider(state) == nil
    end

    test "blur at offset zero, focus after content" do
      span =
        UnreadDivider.new()
        |> UnreadDivider.blur(0)
        |> UnreadDivider.focus(1)
        |> UnreadDivider.divider()

      assert span == %{from: 0, count: 1}
    end
  end

  # -- rendering: the width-exact rule ------------------------------------

  describe "line/2 (the full-width rule)" do
    test "is exactly the requested display width for a comfortable width" do
      line = UnreadDivider.line(%{from: 2, count: 3}, 60)
      assert TextMeasure.display_width(line) == 60
    end

    test "carries the count in the label" do
      line = UnreadDivider.line(%{from: 2, count: 3}, 60)
      assert line =~ "3 new since you looked"
    end

    test "is width-exact across a range of widths (CJK-safe sizing math)" do
      # The rule glyph is single-width and the label ASCII, but the sizing
      # MUST go through TextMeasure so the invariant holds byte-for-byte
      # at every width -- a String.length regression would break odd
      # widths silently.
      for width <- [24, 25, 31, 40, 79, 80, 120] do
        line = UnreadDivider.line(%{from: 0, count: 12}, width)

        assert TextMeasure.display_width(line) == width,
               "width #{width}: got #{TextMeasure.display_width(line)}"
      end
    end

    test "fills with the box-drawing rule on both sides of the label" do
      line = UnreadDivider.line(%{from: 2, count: 3}, 60)
      assert String.starts_with?(line, "─")
      assert String.ends_with?(line, "─")
    end

    test "degrades to the bare label when the width is smaller than the label" do
      line = UnreadDivider.line(%{from: 2, count: 3}, 5)
      assert line =~ "3 new since you looked"
    end

    test "contains no C0 control bytes or escapes (plain content for the ViewText seam)" do
      line = UnreadDivider.line(%{from: 2, count: 1_000_000}, 80)

      refute Enum.any?(:binary.bin_to_list(line), fn byte ->
               byte < 0x20 or byte == 0x7F
             end),
             "the divider line must be inert text; styling is ViewText's job"
    end
  end
end
