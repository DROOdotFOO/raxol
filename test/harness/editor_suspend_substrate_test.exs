defmodule Raxol.Harness.EditorSuspendSubstrateTest do
  @moduledoc """
  Byte-level substrate suite for the editor-handoff primitives: the
  suspend byte vocabulary (`Sequences.suspend_bytes/1`), the
  unconditional region re-pin (`ScrollRegionManager.reassert/1`), and
  the authority-level resume composition
  (`InlineAuthority.resize |> reassert` + the `needs_keyframe`
  self-promotion). StringIO capture only -- no pty, no termbox, no OS
  tty.
  """

  use ExUnit.Case, async: true

  alias Raxol.Terminal.InlineDriver.Sequences
  alias Raxol.Terminal.ScrollRegionManager
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  defp open_device, do: StringIO.open("") |> elem(1)

  defp flush(device), do: StringIO.flush(device)

  describe "Sequences.suspend_bytes/1" do
    test "exact byte composition: teardown steps 1-3 plus a BARE park (no CRLF)" do
      assert Sequences.suspend_bytes(24) ==
               Sequences.modes_off() <>
                 Sequences.release_region() <>
                 Sequences.autowrap_cursor() <> "\e[24;1H"
    end

    test "teardown is suspend plus exactly the fresh-line CRLF (the shell-handoff difference)" do
      for rows <- [2, 24, 60] do
        assert Sequences.teardown_bytes(rows) ==
                 Sequences.suspend_bytes(rows) <> "\r\n"
      end
    end

    test "ordering: modes off, then region release, then autowrap, then park" do
      bytes = Sequences.suspend_bytes(24)

      {modes_idx, _} = :binary.match(bytes, Sequences.modes_off())
      {release_idx, _} = :binary.match(bytes, "\e[r")
      {autowrap_idx, _} = :binary.match(bytes, Sequences.autowrap_cursor())
      {park_idx, _} = :binary.match(bytes, "\e[24;1H")

      assert modes_idx < release_idx
      assert release_idx < autowrap_idx
      assert autowrap_idx < park_idx
    end

    test "never a screen clear (the substrate law)" do
      bytes = Sequences.suspend_bytes(24)
      refute bytes =~ "\e[2J"
      refute bytes =~ "\e[3J"
    end
  end

  describe "ScrollRegionManager.reassert/1" do
    test "re-emits the pin UNCONDITIONALLY on unchanged geometry (contrast resize/2's gate)" do
      device = open_device()
      region = ScrollRegionManager.start(device, 24, 6)
      _ = flush(device)

      # resize to the SAME geometry: zero bytes (the documented gate)
      region = ScrollRegionManager.resize(region, 24)
      assert flush(device) == ""

      # reassert: exactly one full DECSTBM re-set, nothing else
      reasserted = ScrollRegionManager.reassert(region)
      assert flush(device) == "\e[1;18r"

      # state unchanged -- reassert is bytes-only
      assert reasserted == region
    end

    test "degenerate geometry re-emits the honest full-screen release" do
      device = open_device()
      region = ScrollRegionManager.start(device, 3, 6)
      assert flush(device) == "\e[r"

      _ = ScrollRegionManager.reassert(region)
      assert flush(device) == "\e[r"
    end
  end

  describe "InlineAuthority resume composition" do
    test "reassert/1 re-emits the pin and latches needs_keyframe" do
      device = open_device()
      authority = InlineAuthority.new(device, 80, 24, 6, capabilities: nil)
      _ = flush(device)

      refute authority.needs_keyframe

      authority = InlineAuthority.reassert(authority)

      assert authority.needs_keyframe
      assert flush(device) == "\e[1;18r"
    end

    test "the next repaint with UNCHANGED lines self-promotes to a full keyframe" do
      device = open_device()
      authority = InlineAuthority.new(device, 80, 24, 6, capabilities: nil)
      lines = ["status", "composer"]

      authority = InlineAuthority.repaint(authority, lines)
      _ = flush(device)

      # steady state: an unchanged repaint is a byte-free no-op diff
      authority = InlineAuthority.repaint(authority, lines)
      assert flush(device) == ""

      # after reassert, the SAME unchanged repaint must fully re-render:
      # the editor scribbled the screen, so the logical diff is a lie
      authority = InlineAuthority.reassert(authority)
      _ = flush(device)

      authority = InlineAuthority.repaint(authority, lines)
      bytes = flush(device)

      # every footer row (19..24 for 24 rows / 6 footer) is re-addressed
      for row <- 19..24 do
        assert bytes =~ "\e[#{row};1H",
               "keyframe after reassert must re-address footer row #{row}"
      end

      # and the latch is consumed
      refute authority.needs_keyframe
    end

    test "resize-to-same-geometry |> reassert still emits the pin (the resume composition)" do
      device = open_device()
      authority = InlineAuthority.new(device, 80, 24, 6, capabilities: nil)
      _ = flush(device)

      authority =
        authority
        |> InlineAuthority.resize(80, 24)
        |> InlineAuthority.reassert()

      # resize wrote nothing (geometry-gated); reassert wrote the pin
      assert flush(device) == "\e[1;18r"
      assert authority.needs_keyframe
    end

    test "resize-to-NEW-geometry |> reassert re-pins at the new split" do
      device = open_device()
      authority = InlineAuthority.new(device, 80, 24, 6, capabilities: nil)
      _ = flush(device)

      _authority =
        authority
        |> InlineAuthority.resize(100, 30)
        |> InlineAuthority.reassert()

      bytes = flush(device)

      # resize emits the new split once, reassert re-emits it (harmless,
      # idempotent duplicate -- the documented cost of the belt-and-braces
      # composition); no other bytes, and never the OLD split
      assert bytes == "\e[1;24r\e[1;24r"
      refute bytes =~ "\e[1;18r"
    end
  end
end
