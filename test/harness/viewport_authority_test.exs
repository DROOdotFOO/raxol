defmodule Raxol.Harness.ViewportAuthorityTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Rendering.PaintAuthority.ViewportAuthority

  defp capture(fun) do
    {:ok, device} = StringIO.open("")
    result = fun.(device)
    {_in, out} = StringIO.contents(device)
    StringIO.close(device)
    {result, out}
  end

  describe "enter / leave byte constants" do
    test "enter claims the alternate screen, clears, hides cursor, autowrap off" do
      assert ViewportAuthority.enter() == "\e[?1049h\e[2J\e[?25l\e[?7l"
    end

    test "leave restores autowrap + cursor, then leaves the alternate screen" do
      # Autowrap/cursor restored BEFORE the ?1049l exit (ordering is
      # load-bearing: leave must undo enter's autowrap-off before the
      # primary screen is restored).
      assert ViewportAuthority.leave() == "\e[?7h\e[?25h\e[?1049l"
    end
  end

  describe "new/3" do
    test "enters the alternate screen at construction" do
      {t, out} = capture(fn dev -> ViewportAuthority.new(dev, 80, 24) end)

      assert out == ViewportAuthority.enter()
      assert t.width == 80
      assert t.height == 24
      assert t.last_rows == nil
    end
  end

  describe "repaint/3" do
    test "positions each row with an absolute CUP and erases before painting" do
      {authority, dev} = fresh(10, 3)

      {_authority, out} =
        capture_on(dev, fn ->
          ViewportAuthority.repaint(authority, ["row-a", "row-b", "row-c"])
        end)

      # Sync bracket wraps the burst.
      assert String.starts_with?(out, "\e[?2026h")
      assert String.ends_with?(out, "\e[?2026l")

      # Each row: absolute CUP to (n,1), reset + erase-line, then content.
      assert out =~ "\e[1;1H\e[0m\e[2Krow-a"
      assert out =~ "\e[2;1H\e[0m\e[2Krow-b"
      assert out =~ "\e[3;1H\e[0m\e[2Krow-c"
    end

    test "pads short frames to full height so no stale row survives" do
      {authority, dev} = fresh(4, 5)

      {_authority, out} =
        capture_on(dev, fn -> ViewportAuthority.repaint(authority, ["only"]) end)

      # Rows 2..5 are blanked even though only one row of content was given.
      assert out =~ "\e[1;1H\e[0m\e[2Konly"
      assert out =~ "\e[2;1H\e[0m\e[2K"
      assert out =~ "\e[5;1H\e[0m\e[2K"
    end

    test "clamps an over-tall frame to the viewport height" do
      {authority, dev} = fresh(3, 2)

      {_authority, out} =
        capture_on(dev, fn ->
          ViewportAuthority.repaint(authority, ["a", "b", "c", "d"])
        end)

      assert out =~ "\e[1;1H\e[0m\e[2Ka"
      assert out =~ "\e[2;1H\e[0m\e[2Kb"
      # The third+ rows never make it onto a 2-row screen.
      refute out =~ "\e[3;1H"
      refute out =~ "c"
    end

    test "parks a visible cursor when :cursor is given" do
      {authority, dev} = fresh(3, 3)

      {_authority, out} =
        capture_on(dev, fn ->
          ViewportAuthority.repaint(authority, ["x"], cursor: {3, 5})
        end)

      assert out =~ "\e[3;5H\e[?25h"
    end

    test "leaves the cursor hidden when :cursor is nil" do
      {authority, dev} = fresh(3, 3)

      {_authority, out} =
        capture_on(dev, fn -> ViewportAuthority.repaint(authority, ["x"]) end)

      # Ends with the hide (no show, no park).
      refute out =~ "\e[?25h"
      assert out =~ "\e[?25l"
    end

    test "retains last_rows for a future row-diff" do
      {authority, dev} = fresh(3, 2)

      {authority, _out} =
        capture_on(dev, fn ->
          ViewportAuthority.repaint(authority, ["a", "b"])
        end)

      assert authority.last_rows == ["a", "b"]
    end
  end

  describe "teardown/1" do
    test "writes the leave sequence to the device" do
      {authority, dev} = fresh(3, 2)

      {_authority, out} =
        capture_on(dev, fn -> ViewportAuthority.teardown(authority) end)

      assert out == ViewportAuthority.leave()
    end
  end

  describe "resize/3" do
    test "adopts new geometry and drops last_rows" do
      {authority, _dev} = fresh(3, 2)
      authority = %{authority | last_rows: ["a", "b"]}

      resized = ViewportAuthority.resize(authority, 40, 10)
      assert resized.width == 40
      assert resized.height == 10
      assert resized.last_rows == nil
    end
  end

  # A device that keeps accumulating across writes so we can read one
  # repaint's bytes in isolation from the enter bytes.
  defp fresh(width, height) do
    {:ok, dev} = StringIO.open("")
    authority = ViewportAuthority.new(dev, width, height)
    # Drain the enter bytes so subsequent captures see only the repaint.
    _ = StringIO.flush(dev)
    {authority, dev}
  end

  defp capture_on(dev, fun) do
    _ = StringIO.flush(dev)
    result = fun.()
    {_in, out} = StringIO.contents(dev)
    {result, out}
  end
end
