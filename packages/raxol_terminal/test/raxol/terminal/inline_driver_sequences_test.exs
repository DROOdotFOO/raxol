defmodule Raxol.Terminal.InlineDriverSequencesTest do
  @moduledoc """
  Pure byte-sequence tests for unit T2d (`Raxol.Terminal.InlineDriver.Sequences`).

  No process, no device, no OS tty -- Tier A of
  `harness-ui-testing/03-lifecycle.md`. These are the fail-first anchors:
  LC-P-NOALT (init/teardown alt-screen symmetry) and LC-P-CSIR (`CSI r`
  present in teardown -- this is the one that fails against today's
  `Termbox.Lifecycle.cleanup_terminal/1`, which never emits it).
  """

  use ExUnit.Case, async: true

  alias Raxol.Terminal.InlineDriver.Sequences

  describe "init_bytes/0 -- LC-P-NOALT (init direction)" do
    test "contains no alt-screen enable sequence" do
      refute Sequences.init_bytes() =~ "\e[?1049h"
    end

    test "resets stray mouse modes, then enables focus + bracketed paste" do
      bytes = Sequences.init_bytes()

      assert bytes =~ "\e[?1003l"
      assert bytes =~ "\e[?1006l"
      assert bytes =~ "\e[?1000l"
      assert bytes =~ "\e[?1004h"
      assert bytes =~ "\e[?2004h"
    end
  end

  describe "teardown_bytes/1 -- LC-P-NOALT (teardown direction) + LC-P-CSIR" do
    test "contains no alt-screen disable sequence (symmetry, INV-4)" do
      refute Sequences.teardown_bytes(24) =~ "\e[?1049l"
    end

    test "LC-P-CSIR: contains CSI r (the anchor today's cleanup path misses)" do
      assert Sequences.teardown_bytes(24) =~ "\e[r"
    end

    test "disables bracketed paste, focus reporting, and all mouse modes" do
      bytes = Sequences.teardown_bytes(24)

      assert bytes =~ "\e[?2004l"
      assert bytes =~ "\e[?1004l"
      assert bytes =~ "\e[?1003l"
      assert bytes =~ "\e[?1006l"
      assert bytes =~ "\e[?1000l"
    end

    test "re-enables autowrap and shows the cursor" do
      bytes = Sequences.teardown_bytes(24)

      assert bytes =~ "\e[?7h"
      assert bytes =~ "\e[?25h"
    end

    test "moves to the given row, column 1, then CRLF" do
      assert Sequences.teardown_bytes(40) =~ "\e[40;1H\r\n"
    end
  end

  describe "canonical order (INV-1, INV-2, INV-3 positional half)" do
    test "modes-off precedes release-region precedes autowrap/cursor precedes move" do
      bytes = Sequences.teardown_bytes(24)

      modes_off_at = :binary.match(bytes, Sequences.modes_off()) |> elem(0)
      region_at = :binary.match(bytes, Sequences.release_region()) |> elem(0)
      autowrap_at = :binary.match(bytes, Sequences.autowrap_cursor()) |> elem(0)
      move_at = :binary.match(bytes, Sequences.move_bottom(24)) |> elem(0)

      assert modes_off_at < region_at
      assert region_at < autowrap_at
      assert autowrap_at < move_at
    end

    test "INV-1: release-region precedes the absolute cursor move (unclamped)" do
      bytes = Sequences.teardown_bytes(24)
      region_at = :binary.match(bytes, "\e[r") |> elem(0)
      move_at = :binary.match(bytes, "\e[24;1H") |> elem(0)

      assert region_at < move_at
    end

    test "INV-2: cursor-show + autowrap precede the final CRLF handoff" do
      bytes = Sequences.teardown_bytes(24)
      cursor_at = :binary.match(bytes, "\e[?25h") |> elem(0)
      crlf_at = :binary.match(bytes, "\r\n") |> elem(0)

      assert cursor_at < crlf_at
    end
  end

  describe "move_bottom/1" do
    test "requires a positive row" do
      assert_raise FunctionClauseError, fn -> Sequences.move_bottom(0) end
      assert_raise FunctionClauseError, fn -> Sequences.move_bottom(-1) end
    end
  end
end
