defmodule Raxol.Terminal.Capabilities.CapabilitySliceReplyScannerTest do
  @moduledoc """
  ReplyScanner positives + negatives (04 design §5/§6):
  CAP-P-02, CAP-P-04..07, CAP-P-10, CAP-P-11 and CAP-N-04, CAP-N-07..10.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Capabilities.ReplyScanner

  defp scan(bytes), do: ReplyScanner.scan(bytes, ReplyScanner.new())

  describe "CAP-P-02: sentinel discipline" do
    test "all replies before DA1 are parsed, sentinel flagged" do
      {acc, leak} =
        scan(
          "\e]11;rgb:1e1e/1e1e/1e1e\a" <>
            "\e[?2026;1$y" <> "\e[?2048;1$y" <> "\e[?62;4c"
        )

      assert leak == ""
      assert acc.osc11 == {:ok, {30, 30, 30}}
      assert acc.mode == %{2026 => 1, 2048 => 1}
      assert acc.da1 == [62, 4]
      assert acc.sentinel_seen?
    end
  end

  describe "CAP-P-04: both OSC/DCS terminators" do
    test "BEL-terminated and ST-terminated replies parse identically" do
      {bel, ""} = scan("\e]11;rgb:8080/8080/8080\a")
      {st, ""} = scan("\e]11;rgb:8080/8080/8080\e\\")

      assert bel.osc11 == st.osc11
      assert bel.osc11 == {:ok, {128, 128, 128}}
    end

    test "DCS accepts BEL too" do
      {acc, ""} = scan("\eP>|kitty(0.32.2)\a")
      assert acc.xtversion == {"kitty", "0.32.2"}
    end
  end

  describe "native-palette-riding amendment A1: OSC 10 (native foreground)" do
    test "BEL-terminated and ST-terminated OSC 10 replies parse identically" do
      {bel, ""} = scan("\e]10;rgb:e0e0/e0e0/e0e0\a")
      {st, ""} = scan("\e]10;rgb:e0e0/e0e0/e0e0\e\\")

      assert bel.osc10 == st.osc10
      assert bel.osc10 == {:ok, {224, 224, 224}}
    end

    test "OSC 10 and OSC 11 are captured independently in the same chunk" do
      {acc, leak} =
        scan("\e]11;rgb:1e1e/1e1e/1e1e\a\e]10;rgb:d0d0/d0d0/d0d0\a")

      assert leak == ""
      assert acc.osc11 == {:ok, {30, 30, 30}}
      assert acc.osc10 == {:ok, {208, 208, 208}}
    end

    test "a malformed OSC 10 payload is recorded invalid, never crashes" do
      {acc, leak} = scan("\e]10;not-a-color\a")
      assert acc.osc10 == {:invalid, "not-a-color"}
      assert leak == ""
    end

    test "an echoed bare OSC 10 query (no color) is invalid, never a cap" do
      {acc, ""} = scan("\e]10;?\a")
      assert acc.osc10 == {:invalid, "?"}
    end
  end

  describe "CAP-P-05: grammar dispatch, not position" do
    test "scrambled reply order attributes each cap by echoed params" do
      # XTVERSION first, DECRQM in the middle, OSC 11 late, kbd, DA1
      {acc, leak} =
        scan(
          "\eP>|kitty(0.32.2)\e\\" <>
            "\e[?2026;1$y" <>
            "\e]11;rgb:1111/2222/3333\a" <> "\e[?1u" <> "\e[?62;c"
        )

      assert leak == ""
      assert acc.xtversion == {"kitty", "0.32.2"}
      assert acc.mode[2026] == 1
      assert acc.osc11 == {:ok, {17, 34, 51}}
      assert acc.kitty_kbd == 1
      assert acc.sentinel_seen?
    end
  end

  describe "CAP-P-06: DECRQM value capture" do
    test "every Ps value is stored verbatim for the classifier" do
      for value <- 0..4 do
        {acc, ""} = scan("\e[?2026;#{value}$y")
        assert acc.mode[2026] == value
      end
    end
  end

  describe "CAP-P-07: XTVERSION identity parse" do
    test "name(version) form" do
      {acc, ""} = scan("\eP>|kitty(0.32.2)\e\\")
      assert acc.xtversion == {"kitty", "0.32.2"}
    end

    test "name version form" do
      {acc, ""} = scan("\eP>|iTerm2 3.5.0\e\\")
      assert acc.xtversion == {"iTerm2", "3.5.0"}
    end

    test "bare name form" do
      {acc, ""} = scan("\eP>|foot\e\\")
      assert acc.xtversion == {"foot", nil}
    end
  end

  describe "CAP-P-10: cell-px and sixel register replies" do
    test "CSI 6 ; h ; w t yields cell_px {w, h}" do
      {acc, ""} = scan("\e[6;20;10t")
      assert acc.cell_px == {10, 20}
    end

    test "XTSMGRAPHICS color registers" do
      {acc, ""} = scan("\e[?1;0;256S")
      assert acc.sixel_regs == 256
    end
  end

  describe "CPR consumption (the modified-F3 wire ambiguity)" do
    test "a cursor position report is consumed, never leaked" do
      {acc, leak} = scan("\e[12;40R")
      assert acc.cpr == {12, 40}
      assert leak == ""
    end

    test "row-1 CPR (byte-identical to xterm modified-F3) is consumed too" do
      # during a probe window this MUST be stripped: InputParser would
      # otherwise read it as a modified function key
      {acc, leak} = scan("\e[1;83R")
      assert acc.cpr == {1, 83}
      assert leak == ""
    end

    test "single-param CSI R is not a CPR and leaks" do
      {acc, leak} = scan("\e[5R")
      assert acc.cpr == nil
      assert leak == "\e[5R"
    end
  end

  describe "CAP-P-11: kitty keyboard flags" do
    test "flags reply parses" do
      {acc, ""} = scan("\e[?31u")
      assert acc.kitty_kbd == 31
    end

    test "absent reply stays nil" do
      {acc, _} = scan("\e[?62;c")
      assert acc.kitty_kbd == nil
    end

    test "a bare echoed 'CSI ? u' query (no digits) is not a flags reply" do
      {acc, leak} = scan("\e[?u")
      assert acc.kitty_kbd == nil
      assert leak == ""
    end
  end

  describe "CAP-N-04: interleaved user keystrokes" do
    test "replies parsed AND keystrokes preserved in order" do
      {acc, leak} = scan("l\e[?2026;1$y" <> "\e[?62;c" <> "s\r")

      assert acc.mode[2026] == 1
      assert acc.sentinel_seen?
      assert leak == "ls\r"
    end
  end

  describe "CAP-N-07: echo-leak (terminal echoes the query verbatim)" do
    test "echoed queries never become caps; residual is InputParser-safe" do
      query = Raxol.Terminal.Capabilities.Probe.query_sequence()
      {acc, leak} = scan(query)

      # nothing was mistaken for a reply
      assert acc.mode == %{}
      assert acc.kitty_kbd == nil
      refute acc.sentinel_seen?
      # the echoed OSC queries are captured as invalid colors, never caps
      assert acc.osc11 == {:invalid, "?"}
      assert acc.osc10 == {:invalid, "?"}
      # residual is only well-formed CSI the key parser consumes silently
      assert leak == "\e[>0q\e[c"
    end
  end

  describe "CAP-N-08/09: partial replies" do
    test "chunk ending mid-reply parks the fragment (nothing leaks)" do
      {acc, leak} = scan("\e[?2026;1")
      assert leak == ""
      assert acc.partial == "\e[?2026;1"
      assert acc.mode == %{}
    end

    test "continuation chunk resumes the parked fragment (CAP-N-09)" do
      {acc, ""} = scan("\e[?2026;1")
      {acc, ""} = ReplyScanner.scan("$y\e[?62;c", acc)

      assert acc.mode[2026] == 1
      assert acc.sentinel_seen?
      assert acc.partial == ""
    end

    test "trailing lone ESC is parked, then resolves as input" do
      {acc, ""} = scan("\e")
      assert acc.partial == "\e"

      {acc, leak} = ReplyScanner.scan("[A", acc)
      assert leak == "\e[A"
      assert acc.partial == ""
    end
  end

  describe "CAP-N-10: malformed replies never crash, never support" do
    test "empty DECRQM value" do
      {acc, ""} = scan("\e[?2026;$y")
      assert acc.mode[2026] == nil
      assert Map.has_key?(acc.mode, 2026)
    end

    test "out-of-range DECRQM value is stored for the classifier to reject" do
      {acc, ""} = scan("\e[?2026;9$y")
      assert acc.mode[2026] == 9
    end

    test "DECRQM with no mode param is dropped" do
      {acc, ""} = scan("\e[?;1$y")
      assert acc.mode == %{}
    end

    test "truncated DCS parks as partial" do
      {acc, ""} = scan("\eP>|kit")
      assert acc.partial == "\eP>|kit"
      assert acc.xtversion == nil
    end

    test "stray ESC inside a CSI aborts and re-scans, losing no input" do
      {_acc, leak} = scan("\e[?20\e[A")
      # aborted reply candidate: all bytes surface as leak, in order
      assert leak == "\e[?20\e[A"
    end
  end

  describe "leak discipline for non-reply sequences" do
    test "arrow keys, mouse, and focus events pass through untouched" do
      input = "\e[A\e[<0;10;5M\e[I\e[1;5C"
      {acc, leak} = scan(input)
      assert leak == input
      assert acc == %{ReplyScanner.new() | partial: acc.partial}
      assert acc.partial == ""
    end

    test "unrelated OSC frames are drained, not leaked as Alt+] keys" do
      {acc, leak} = scan("\e]0;window title\ax")
      assert leak == "x"
      assert acc.osc11 == nil
    end
  end
end
