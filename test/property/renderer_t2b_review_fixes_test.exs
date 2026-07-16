defmodule Raxol.Property.RendererT2bReviewFixesTest do
  @moduledoc """
  Fixes on the printed-history append path:
  `Raxol.UI.Rendering.PaintAuthority.ContentGuard` (HIGH --
  `seal/2`/`append_sealed/2` wrote agent/LLM-originated iodata verbatim,
  so a control sequence embedded IN CONTENT could defeat every invariant
  the append path exists to hold, from the inside), newline-termination
  enforcement (MED -- the docstring's "MUST be `\\r\\n`-terminated" is now
  an `ArgumentError`, not prose), and the `with_cursor/3` nesting guard
  (MED -- the sole-DECSC-owner invariant is now enforced in code).

  Each `describe` block below is a RED/GREEN pair: RED demonstrates,
  via the byte-capture oracle (`Raxol.Harness.Test.SealOracle`) or a
  direct `Emulator` inspection, that the raw/pre-guard bytes are a REAL,
  oracle-visible threat -- not a strawman -- before GREEN shows the same
  payload, routed through the real `InlineAuthority.seal/2`, emerges
  neutralized.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Test.SealOracle
  alias Raxol.Terminal.Emulator
  alias Raxol.UI.Rendering.PaintAuthority.ContentGuard
  alias Raxol.UI.Rendering.PaintAuthority.Dialect
  alias Raxol.UI.Rendering.PaintAuthority.InlineAuthority

  @width 40
  @height 10
  @footer_rows 2
  @region_top 8

  defp new_authority(opts \\ []) do
    {:ok, device} = StringIO.open("")
    {device, InlineAuthority.new(device, @width, @height, @footer_rows, opts)}
  end

  defp raw(device) do
    {_in, out} = StringIO.contents(device)
    out
  end

  defp row_text(emulator, row_index) do
    emulator
    |> Emulator.get_screen_buffer()
    |> Map.get(:cells)
    |> Enum.at(row_index)
    |> Enum.map_join("", fn cell -> Map.get(cell, :char) || " " end)
    |> String.trim_trailing()
  end

  # ---------------------------------------------------------------------
  # ContentGuard neutralizes control bytes embedded IN sealed content
  # ---------------------------------------------------------------------

  describe "\\e[2J embedded in content" do
    test "RED: raw bytes trigger the full-clear oracle" do
      {device, authority} = new_authority()
      _ = InlineAuthority.seal(authority, "sealed before\r\n")
      IO.write(device, "agent said: \e[2J surprise\r\n")

      assert SealOracle.emits_full_clear?(raw(device))
    end

    test "GREEN: the same bytes, through seal/2, never trigger it" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "sealed before\r\n")
      _ = InlineAuthority.seal(authority, "agent said: \e[2J surprise\r\n")

      refute SealOracle.emits_full_clear?(raw(device))

      emulator = SealOracle.replay(raw(device), width: @width, height: @height)
      assert row_text(emulator, 1) == "agent said: [2J surprise"
    end
  end

  describe "\\e[3J embedded in content" do
    test "RED: raw bytes trigger the full-clear oracle" do
      {device, authority} = new_authority()
      _ = InlineAuthority.seal(authority, "sealed before\r\n")
      IO.write(device, "agent said: \e[3J surprise\r\n")

      assert SealOracle.emits_full_clear?(raw(device))
    end

    test "GREEN: the same bytes, through seal/2, never trigger it" do
      {device, authority} = new_authority()
      authority = InlineAuthority.seal(authority, "sealed before\r\n")
      _ = InlineAuthority.seal(authority, "agent said: \e[3J surprise\r\n")

      refute SealOracle.emits_full_clear?(raw(device))

      emulator = SealOracle.replay(raw(device), width: @width, height: @height)
      assert row_text(emulator, 1) == "agent said: [3J surprise"
    end
  end

  describe "\\e[1;1H embedded in content (CUP repaint attempt)" do
    test "RED: raw bytes repainting row 1 are caught by the immutable-prefix oracle" do
      {device, authority} = new_authority()

      authority =
        Enum.reduce(1..3, authority, fn n, auth ->
          InlineAuthority.seal(auth, "correct block #{n}\r\n")
        end)

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      _ = authority
      # The payload a malicious/careless agent might emit: content that
      # itself carries a CUP back to row 1 and repaints it.
      IO.write(device, "\e[1;1Hagent-forged repaint\r\n")

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert {:violation, _idx, _expected, _actual} =
               SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "GREEN: the same bytes, through seal/2, never disturb the immutable prefix" do
      {device, authority} = new_authority()

      authority =
        Enum.reduce(1..3, authority, fn n, auth ->
          InlineAuthority.seal(auth, "correct block #{n}\r\n")
        end)

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      _ = InlineAuthority.seal(authority, "\e[1;1Hagent-forged repaint\r\n")

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert :ok == SealOracle.immutable_prefix?(history_k, history_final)

      # Visible-honest: the ESC is gone, the digits/letters that followed
      # it survive as literal text on the row the append path actually
      # used (the next unfilled history row -- row 4 -- never row 1).
      assert row_text(emulator_final, 3) == "[1;1Hagent-forged repaint"
    end
  end

  describe "\\e[5A embedded in content (relative cursor-up + overwrite)" do
    test "RED: raw bytes moving up then overwriting are caught by the immutable-prefix oracle" do
      {device, authority} = new_authority()

      authority =
        Enum.reduce(1..5, authority, fn n, auth ->
          InlineAuthority.seal(auth, "correct block #{n}\r\n")
        end)

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      _ = authority
      IO.write(device, "\e[5Aovershoots up 5 and repaints\r\n")

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert {:violation, _idx, _expected, _actual} =
               SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "GREEN: the same bytes, through seal/2, never disturb the immutable prefix" do
      {device, authority} = new_authority()

      authority =
        Enum.reduce(1..5, authority, fn n, auth ->
          InlineAuthority.seal(auth, "correct block #{n}\r\n")
        end)

      raw_k = raw(device)
      hw_k = SealOracle.seal_high_water(raw_k)
      emulator_k = SealOracle.replay(raw_k, width: @width, height: @height)
      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      _ =
        InlineAuthority.seal(authority, "\e[5Aovershoots up 5 and repaints\r\n")

      raw_final = raw(device)
      hw_final = SealOracle.seal_high_water(raw_final)

      emulator_final =
        SealOracle.replay(raw_final, width: @width, height: @height)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert :ok == SealOracle.immutable_prefix?(history_k, history_final)
    end
  end

  describe "OSC (\\e]0;title\\a) embedded in content" do
    test "RED: raw bytes actually set the emulator's window title (a real, executed side effect)" do
      fresh = SealOracle.replay("", width: @width, height: @height)
      assert fresh.window_title == nil

      raw_bytes = "\e]0;title\atext after\r\n"
      emulator = SealOracle.replay(raw_bytes, width: @width, height: @height)

      assert emulator.window_title == "title"
    end

    test "GREEN: the same bytes, through seal/2, never touch the window title -- the residue is left visible instead" do
      {device, authority} = new_authority()
      _ = InlineAuthority.seal(authority, "\e]0;title\atext after\r\n")

      emulator = SealOracle.replay(raw(device), width: @width, height: @height)

      assert emulator.window_title == nil
      assert row_text(emulator, 0) == "]0;titletext after"
    end
  end

  describe "bare partial escape at end-of-line" do
    test "RED: a truncated CSI at the end of one write corrupts and merges the NEXT line, once concatenated on the wire" do
      {device, _authority} = new_authority()

      # Simulates two separate emits that end up concatenated on the same
      # physical byte stream (exactly what two consecutive `IO.write/2`
      # calls to the same device produce) -- the first ends mid-escape
      # (no final byte before its own, otherwise-valid, `\r\n` terminator).
      IO.write(device, "block one \e[9\r\n")
      IO.write(device, "block two starts here\r\n")

      emulator = SealOracle.replay(raw(device), width: @width, height: @height)

      # The dangling CSI parameter byte is still "open" across the `\r\n`
      # boundary: the parser keeps hunting for a valid CSI final byte
      # (`0x40..0x7E`, which covers every letter), finds one in "block"
      # itself (the leading `b`), and the whole intervening span --
      # including the line break -- is consumed as that sequence's
      # parameters instead of being printed. Both lines end up merged
      # onto one row, with a letter eaten.
      assert row_text(emulator, 0) == "block one lock two starts here"
      assert row_text(emulator, 1) == ""
    end

    test "GREEN: the same two blocks, through separate seal/2 calls, never bleed into each other" do
      {device, authority} = new_authority()

      authority = InlineAuthority.seal(authority, "block one \e[9\r\n")
      _ = InlineAuthority.seal(authority, "block two starts here\r\n")

      emulator = SealOracle.replay(raw(device), width: @width, height: @height)

      # Each `seal/2` call sanitizes its OWN iodata completely before any
      # byte reaches the device -- a dangling escape can never persist
      # parser state into a LATER seal call the way it can on the raw,
      # unguarded wire. Row 1 shows the visible residue; row 2 is
      # completely intact.
      assert row_text(emulator, 0) == "block one [9"
      assert row_text(emulator, 1) == "block two starts here"
    end
  end

  describe "a legitimately styled line stays styled (SGR passes through byte-identical)" do
    test "GREEN: \\e[1;31m...\\e[0m survives seal/2 unchanged" do
      {device, authority} = new_authority()
      bytes_before = raw(device)

      styled = "\e[1;31mcolored\e[0m\r\n"
      _ = InlineAuthority.seal(authority, styled)

      all_bytes = raw(device)

      new_bytes =
        binary_part(
          all_bytes,
          byte_size(bytes_before),
          byte_size(all_bytes) - byte_size(bytes_before)
        )

      expected =
        Dialect.cursor_save() <>
          Dialect.cursor_position(1) <> styled <> Dialect.cursor_restore()

      assert new_bytes == expected
    end
  end

  # ---------------------------------------------------------------------
  # Newline-termination enforcement
  # ---------------------------------------------------------------------

  describe "seal/2 enforces \\r\\n-termination" do
    test "raises ArgumentError on a dangling partial line" do
      {_device, authority} = new_authority()

      assert_raise ArgumentError, ~r/\\r\\n-terminated/, fn ->
        InlineAuthority.seal(authority, "partial")
      end
    end

    test "raises ArgumentError when terminated with only \\n (no \\r)" do
      {_device, authority} = new_authority()

      assert_raise ArgumentError, fn ->
        InlineAuthority.seal(authority, "partial\n")
      end
    end

    test "does not raise on a properly \\r\\n-terminated block" do
      {_device, authority} = new_authority()

      assert %InlineAuthority{} = InlineAuthority.seal(authority, "fine\r\n")
    end
  end

  # ---------------------------------------------------------------------
  # with_cursor/3 nesting guard
  # ---------------------------------------------------------------------

  describe "with_cursor/3 nesting guard: the sole-DECSC-owner invariant, enforced in code" do
    test "a nested with_cursor/3 call raises" do
      {_device, authority} = new_authority()

      assert_raise RuntimeError, ~r/nesting|already open/i, fn ->
        InlineAuthority.with_cursor(authority, :history, fn inner ->
          InlineAuthority.with_cursor(inner, :history, fn _ -> inner end)
        end)
      end
    end

    test "seal/2 called from inside a with_cursor/3 bracket raises" do
      {_device, authority} = new_authority()

      assert_raise RuntimeError, ~r/nesting|already open/i, fn ->
        InlineAuthority.with_cursor(authority, :history, fn inner ->
          InlineAuthority.seal(inner, "nested seal\r\n")
        end)
      end
    end

    test "the guard does not permanently lock the authority: sequential seals after a normal with_cursor/3 still work" do
      {device, authority} = new_authority()

      authority =
        InlineAuthority.with_cursor(authority, :history, fn inner ->
          InlineAuthority.append_sealed(inner, "first\r\n")
        end)

      authority = InlineAuthority.seal(authority, "second\r\n")
      _ = InlineAuthority.seal(authority, "third\r\n")

      emulator = SealOracle.replay(raw(device), width: @width, height: @height)
      assert row_text(emulator, 0) == "first"
      assert row_text(emulator, 1) == "second"
      assert row_text(emulator, 2) == "third"
    end
  end

  # ---------------------------------------------------------------------
  # cup routed through Dialect.cursor_position/1
  # ---------------------------------------------------------------------

  describe "cursor positioning is routed through Dialect.cursor_position/1" do
    test "byte format is pinned: CSI row;1H" do
      assert Dialect.cursor_position(1) == "\e[1;1H"
      assert Dialect.cursor_position(23) == "\e[23;1H"
    end

    test "append_sealed/2's CUP byte-matches Dialect.cursor_position/1 exactly" do
      {device, authority} = new_authority()
      bytes_before = raw(device)

      _ = InlineAuthority.append_sealed(authority, "line\r\n")

      all_bytes = raw(device)

      new_bytes =
        binary_part(
          all_bytes,
          byte_size(bytes_before),
          byte_size(all_bytes) - byte_size(bytes_before)
        )

      assert new_bytes == Dialect.cursor_position(1) <> "line\r\n"
    end
  end

  # ---------------------------------------------------------------------
  # ContentGuard.sanitize_line/1: direct grammar tests
  # ---------------------------------------------------------------------

  describe "ContentGuard.sanitize_line/1: allowlist grammar" do
    test "printable ASCII and UTF-8 pass through unchanged" do
      assert ContentGuard.sanitize_line("hello, world! 123") ==
               "hello, world! 123"

      assert ContentGuard.sanitize_line("héllo wörld — emoji: 🎉") ==
               "héllo wörld — emoji: 🎉"
    end

    test "\\t, \\r, \\n pass through unchanged" do
      assert ContentGuard.sanitize_line("a\tb\r\nc") == "a\tb\r\nc"
    end

    test "SGR sequences pass through byte-identical" do
      assert ContentGuard.sanitize_line("\e[1;31mred\e[0m") ==
               "\e[1;31mred\e[0m"

      assert ContentGuard.sanitize_line("\e[m") == "\e[m"
      assert ContentGuard.sanitize_line("\e[0m") == "\e[0m"
    end

    test "non-SGR CSI has only its ESC stripped, residue stays visible" do
      assert ContentGuard.sanitize_line("\e[2J") == "[2J"
      assert ContentGuard.sanitize_line("\e[1;1H") == "[1;1H"
      assert ContentGuard.sanitize_line("\e[5A") == "[5A"
    end

    test "OSC has only its ESC stripped; the terminating BEL is silently dropped (no residue)" do
      assert ContentGuard.sanitize_line("\e]0;title\atext") == "]0;titletext"
    end

    test "OSC with an ST (ESC \\\\) terminator: both ESCs stripped" do
      assert ContentGuard.sanitize_line("\e]0;title\e\\text") ==
               "]0;title\\text"
    end

    test "DCS has only its ESC stripped" do
      assert ContentGuard.sanitize_line("\eP1$q\e\\rest") == "P1$q\\rest"
    end

    test "a bare, unterminated ESC at end-of-string is stripped cleanly (no crash)" do
      assert ContentGuard.sanitize_line("text\e") == "text"
      assert ContentGuard.sanitize_line("text\e[") == "text["
      assert ContentGuard.sanitize_line("text\e[9") == "text[9"
    end

    test "every other C0 control (except \\t/\\r/\\n) is stripped silently" do
      assert ContentGuard.sanitize_line("a\ab\bc\vd\fe") == "abcde"
    end

    test "DEL is stripped silently" do
      assert ContentGuard.sanitize_line("a\x7Fb") == "ab"
    end

    test "empty input round-trips to an empty binary" do
      assert ContentGuard.sanitize_line("") == ""
      assert ContentGuard.sanitize_line([]) == ""
    end

    test "accepts iodata (lists), not just binaries" do
      assert ContentGuard.sanitize_line(["ab", ?c, ["d", "\e[2J"]]) == "abcd[2J"
    end
  end
end
