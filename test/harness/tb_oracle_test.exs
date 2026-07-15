defmodule Raxol.Harness.TbOracleTest do
  @moduledoc """
  TB (byte-capture test harness) acceptance suite. Per
  `docs/proposals/in-flight/harness-ui-roadmap.md`'s TB unit: "a hand-written
  violating stream is caught by both oracles; a known-good stream passes;
  origin tags survive interleaving."

  This is TB's own oracle self-test (R-P12 in
  `harness-ui-testing/02-renderer.md` §2/§4): "the oracle must flag a
  known-bad byte stream before any of its passes are trusted." T2b/T2c's own
  property suites (`test/property/renderer_seal_once_property_test.exs`,
  `renderer_adversarial_property_test.exs`) consume this same shared harness
  without duplicating it.
  """

  use ExUnit.Case, async: true

  alias Raxol.Harness.Test.{BuggyAuthority, CaptureAuthority}
  alias Raxol.Harness.Test.SealOracle
  alias Raxol.UI.Rendering.PaintAuthority.{Dialect, IOAuthority}

  # A small, fixed geometry used throughout: 10 rows total, region_top = 8
  # (rows 1..8 = history, rows 9..10 = footer). Small enough that no test
  # here scrolls a sealed row past the visible region (see the scrollback
  # spike test for that limitation).
  @width 40
  @height 10
  @region_top 8

  describe "R-P12 oracle self-test: violations are caught, good streams pass" do
    test "sealed-row rewrite (Ink-style failure) is caught by O2 (INV-1 immutable-prefix)" do
      {sealed_at_k, final} = BuggyAuthority.sealed_row_rewrite()

      emulator_k =
        SealOracle.replay(sealed_at_k, width: @width, height: @height)

      emulator_final = SealOracle.replay(final, width: @width, height: @height)

      history_k = SealOracle.history(emulator_k, @region_top)
      history_final = SealOracle.history(emulator_final, @region_top)

      assert {:violation, _idx, _expected, _actual} =
               SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "a known-good stream (seal once, then append below) passes the same check" do
      {sealed_at_k, final} = BuggyAuthority.sealed_stream_ok()

      emulator_k =
        SealOracle.replay(sealed_at_k, width: @width, height: @height)

      emulator_final = SealOracle.replay(final, width: @width, height: @height)

      history_k = SealOracle.history(emulator_k, @region_top)
      history_final = SealOracle.history(emulator_final, @region_top)

      assert :ok == SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "full-screen clear is caught by BOTH oracles (O1 mechanical + O2 content)" do
      sealed_at_k = "\e[1;1H\e[2Kimportant sealed content\r\n"
      final = sealed_at_k <> BuggyAuthority.full_screen_clear()

      # O1: the bytes themselves are forbidden on the inline path (INV-3),
      # independent of any replay.
      assert SealOracle.emits_full_clear?(final)
      refute SealOracle.emits_full_clear?(sealed_at_k)

      # O2: replaying through the clear actually wipes the on-screen content,
      # so the immutable-prefix check independently flags it too.
      emulator_k =
        SealOracle.replay(sealed_at_k, width: @width, height: @height)

      emulator_final = SealOracle.replay(final, width: @width, height: @height)

      history_k = SealOracle.history(emulator_k, @region_top)
      history_final = SealOracle.history(emulator_final, @region_top)

      assert {:violation, _idx, _expected, _actual} =
               SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "footer-bleed CUP is caught by O1 (INV-2 footer-confinement)" do
      bad = BuggyAuthority.footer_bleed_cup(@region_top)
      assert @region_top in SealOracle.cup_rows(bad)

      # A confined footer repaint (row region_top + 1, the first footer row)
      # never addresses region_top itself.
      good = "\e[#{@region_top + 1};1H\e[2Kstatus: ok"
      refute @region_top in SealOracle.cup_rows(good)
    end

    test "footer-bleed via RELATIVE movement (CUP into footer, CUU into history) is caught by O1" do
      bad = BuggyAuthority.footer_bleed_relative(@region_top)

      # The absolute CUP lands on the first footer row (legal); the CUU then
      # walks the cursor up into history. A CUP-only scanner sees only the
      # legal row — the stateful walk sees both.
      assert (@region_top + 1) in SealOracle.cup_rows(bad)
      assert @region_top in SealOracle.cup_rows(bad)

      # Relative movement that STAYS inside the footer is not flagged.
      good = "\e[#{@region_top + 1};1H\e[2Kstatus\e[1Bsecond footer row"
      refute @region_top in SealOracle.cup_rows(good)
      assert (@region_top + 2) in SealOracle.cup_rows(good)
    end

    test "sealed-BLANK-row rewrite: content trim is blind, emit-derived high-water catches it" do
      {sealed_at_k, final} = BuggyAuthority.sealed_blank_rewrite()

      emulator_k =
        SealOracle.replay(sealed_at_k, width: @width, height: @height)

      emulator_final = SealOracle.replay(final, width: @width, height: @height)

      # Characterized blind spot (kept deliberately): without write
      # tracking, a written-blank row is indistinguishable from
      # never-written capacity, so the content-based trim false-passes.
      blind_k = SealOracle.history(emulator_k, @region_top)
      blind_final = SealOracle.history(emulator_final, @region_top)
      assert :ok == SealOracle.immutable_prefix?(blind_k, blind_final)

      # With the high-water mark derived from the EMIT stream (newline-
      # terminated sealed lines), the sealed blank row is inside the sealed
      # window and its rewrite is a violation.
      hw_k = SealOracle.seal_high_water(sealed_at_k)
      hw_final = SealOracle.seal_high_water(final)
      assert hw_k == 2

      history_k = SealOracle.history(emulator_k, @region_top, high_water: hw_k)

      history_final =
        SealOracle.history(emulator_final, @region_top, high_water: hw_final)

      assert {:violation, _idx, _expected, _actual} =
               SealOracle.immutable_prefix?(history_k, history_final)
    end

    test "footer-bleed via VPA (absolute row set, not CUP) is caught by the modeled d clause" do
      bad = BuggyAuthority.footer_bleed_vpa(@region_top)

      assert (@region_top + 1) in SealOracle.cup_rows(bad)
      assert @region_top in SealOracle.cup_rows(bad)
    end

    test "fail-closed: unmodeled row-affecting tokens are rejected, never skipped" do
      # IL and partial ED die via the fail-closed path — that is the point:
      # the whitelist rejects what it cannot verify.
      assert {:unverifiable, {:csi, "2", "L"}} =
               SealOracle.row_walk(BuggyAuthority.il_shift())

      assert {:unverifiable, {:csi, "", "J"}} =
               SealOracle.row_walk(BuggyAuthority.ed_partial())

      # A sample of the enumerated advisory tokens, all rejected.
      assert {:unverifiable, {:csi, "2", "S"}} = SealOracle.row_walk("\e[2S")
      assert {:unverifiable, {:csi, "1", "e"}} = SealOracle.row_walk("\e[1e")
      assert {:unverifiable, {:esc, "c"}} = SealOracle.row_walk("\ec")
      assert {:unverifiable, {:csi, "", "s"}} = SealOracle.row_walk("\e[s")

      assert {:unverifiable, {:csi, "?1049", "h"}} =
               SealOracle.row_walk("\e[?1049h")

      # The list API raises so INV assertions cannot silently pass.
      assert_raise SealOracle.UnverifiableError, ~r/fail-closed/, fn ->
        SealOracle.cup_rows(BuggyAuthority.il_shift())
      end

      # Ignorable tokens (SGR, EL, column moves, non-alt-screen modes,
      # OSC marks) do NOT trip the walk.
      assert {:ok, [3]} =
               SealOracle.row_walk(
                 "\e[3;1H\e[0;1m\e[2K\e[5G\e[2C\e[?2026h\e]133;A\e\\ok"
               )
    end

    test "nested cursor save (net balance 0) is caught by max-depth tracking" do
      bad = BuggyAuthority.nested_cursor_save()

      # The net-balance check alone is blind to this stream...
      assert %{decsc: 0} = SealOracle.save_restore_balance(bad)
      # ...the running max-depth check is not: a second save before the
      # first restore clobbers the single DECSC register.
      assert %{decsc_max_depth: 2} = SealOracle.save_restore_balance(bad)

      good = "\e7\e[1;1Hx\e8"

      assert %{decsc: 0, decsc_max_depth: 1} =
               SealOracle.save_restore_balance(good)
    end

    test "unbalanced cursor save is caught by BOTH oracles (O1 balance + O2 drift)" do
      bad = BuggyAuthority.unbalanced_cursor_save()

      # O1: the DECSC save was never matched by a restore.
      assert %{decsc: decsc} = SealOracle.save_restore_balance(bad)
      assert decsc != 0

      # O2: cursor position after replay is wherever the unrestored write
      # left it, not back at the pre-bracket origin — demonstrated by
      # contrasting with a correctly balanced bracket that returns home.
      good = "\e7\e[1;1HAppended with restore\e8"
      emulator_bad = SealOracle.replay(bad, width: @width, height: @height)
      emulator_good = SealOracle.replay(good, width: @width, height: @height)

      assert Raxol.Terminal.Emulator.get_cursor_position(emulator_bad) !=
               Raxol.Terminal.Emulator.get_cursor_position(emulator_good)

      assert %{decsc: 0} = SealOracle.save_restore_balance(good)
    end
  end

  describe "CaptureAuthority: origin tags survive interleaving" do
    test "log preserves call-site origin and order across interleaved paths" do
      t = CaptureAuthority.new(@width, @height, @region_top)

      t =
        t
        |> CaptureAuthority.append_sealed("block one\r\n")
        |> CaptureAuthority.repaint_footer("footer v1")
        |> CaptureAuthority.with_cursor(:history, fn inner ->
          CaptureAuthority.append_sealed(
            inner,
            "block two (under cursor bracket)\r\n"
          )
        end)
        |> CaptureAuthority.keyframe_footer("footer redraw")
        |> CaptureAuthority.repaint_footer("footer v2")

      origins = t |> CaptureAuthority.log() |> Enum.map(& &1.origin)

      assert origins == [
               :seal,
               :footer,
               :cursor,
               :seal,
               :cursor,
               :keyframe,
               :footer
             ]

      # raw is exactly the concatenation of the tagged log, in order — the
      # tag layer is a pure superset of the byte stream, never a lossy view.
      concatenated =
        t |> CaptureAuthority.log() |> Enum.map_join("", & &1.bytes)

      assert concatenated == CaptureAuthority.raw(t)

      # Filtering by origin recovers exactly the seal-path bytes, uncontaminated
      # by the footer/keyframe/cursor bytes interleaved around them.
      seal_bytes =
        t
        |> CaptureAuthority.log_by_origin(:seal)
        |> Enum.map_join("", & &1.bytes)

      assert seal_bytes == "block one\r\nblock two (under cursor bracket)\r\n"
    end

    test "with_cursor brackets are single-owner: no nested unbalanced save across calls" do
      t = CaptureAuthority.new(@width, @height, @region_top)

      t =
        CaptureAuthority.with_cursor(t, :footer, fn inner ->
          CaptureAuthority.repaint_footer(inner, "status")
        end)

      cursor_emits = CaptureAuthority.log_by_origin(t, :cursor)
      assert length(cursor_emits) == 2
      assert Enum.map(cursor_emits, & &1.bytes) == ["\e7", "\e8"]

      assert %{decsc: 0} =
               SealOracle.save_restore_balance(CaptureAuthority.raw(t))
    end

    test "resize emits the region re-set through the capture path under a :region origin" do
      t = CaptureAuthority.new(@width, @height, @region_top)
      t = CaptureAuthority.resize(t, 80, 24)

      # INV-5's "DECSTBM re-set exactly once per resize as CSI 1;(h-N) r"
      # now has bytes to assert against.
      assert [%{origin: :region, bytes: bytes}] =
               CaptureAuthority.log_by_origin(t, :region)

      assert bytes == Dialect.region_set(1, 23)
      assert SealOracle.scroll_region(CaptureAuthority.raw(t)) == {1, 23}
      assert CaptureAuthority.region_top(t) == 23
    end

    test "nested with_cursor raises: the cursor-save slot is single-owner" do
      t = CaptureAuthority.new(@width, @height, @region_top)

      assert_raise ArgumentError, ~r/nested with_cursor/, fn ->
        CaptureAuthority.with_cursor(t, :history, fn inner ->
          CaptureAuthority.with_cursor(inner, :footer, fn i -> i end)
        end)
      end

      # Sequential (non-nested) brackets remain legal.
      t = CaptureAuthority.with_cursor(t, :history, fn i -> i end)
      t = CaptureAuthority.with_cursor(t, :footer, fn i -> i end)

      assert %{decsc: 0, decsc_max_depth: 1} =
               SealOracle.save_restore_balance(CaptureAuthority.raw(t))
    end
  end

  describe "high-water accounting from the authority's own emit records" do
    test "seal_high_water(capture) counts sealed lines exactly, from :seal-origin emits only" do
      t =
        CaptureAuthority.new(@width, @height, @region_top)
        |> CaptureAuthority.append_sealed("one\r\n")
        |> CaptureAuthority.repaint_footer("footer noise\n with newlines\n")
        |> CaptureAuthority.append_sealed("two\r\nthree\r\n")

      # Footer-origin newlines never contaminate the sealed-row count.
      assert SealOracle.seal_high_water(t) == 3
    end

    test "assert_seal_newline_terminated enforces the whole-lines emit discipline" do
      good =
        CaptureAuthority.new(@width, @height, @region_top)
        |> CaptureAuthority.append_sealed("one\r\n")
        |> CaptureAuthority.append_sealed("two\r\nthree\r\n")

      assert :ok == SealOracle.assert_seal_newline_terminated(good)

      bad =
        CaptureAuthority.new(@width, @height, @region_top)
        |> CaptureAuthority.append_sealed("dangling partial line")

      assert_raise ExUnit.AssertionError, ~r/not newline-terminated/, fn ->
        SealOracle.assert_seal_newline_terminated(bad)
      end
    end
  end

  describe "mutation completeness: every invariant has a kill stream" do
    test "for each INV-1..6, its named kill stream is detected" do
      {rewrite_k, rewrite_final} = BuggyAuthority.sealed_row_rewrite()

      inv1_detected? = fn ->
        history_k =
          SealOracle.history(
            SealOracle.replay(rewrite_k, width: @width, height: @height),
            @region_top
          )

        history_final =
          SealOracle.history(
            SealOracle.replay(rewrite_final, width: @width, height: @height),
            @region_top
          )

        match?(
          {:violation, _, _, _},
          SealOracle.immutable_prefix?(history_k, history_final)
        )
      end

      kill_matrix = [
        {"INV-1 sealed-row rewrite", inv1_detected?},
        {"INV-2 absolute footer bleed (CUP)",
         fn ->
           @region_top in SealOracle.cup_rows(
             BuggyAuthority.footer_bleed_cup(@region_top)
           )
         end},
        {"INV-2 relative footer bleed (CUU)",
         fn ->
           @region_top in SealOracle.cup_rows(
             BuggyAuthority.footer_bleed_relative(@region_top)
           )
         end},
        {"INV-2 VPA footer bleed",
         fn ->
           @region_top in SealOracle.cup_rows(
             BuggyAuthority.footer_bleed_vpa(@region_top)
           )
         end},
        {"INV-3 full-screen clear",
         fn ->
           SealOracle.emits_full_clear?(BuggyAuthority.full_screen_clear())
         end},
        {"INV-4 unbalanced cursor save",
         fn ->
           %{decsc: decsc} =
             SealOracle.save_restore_balance(
               BuggyAuthority.unbalanced_cursor_save()
             )

           decsc != 0
         end},
        {"INV-4 nested cursor save",
         fn ->
           %{decsc_max_depth: depth} =
             SealOracle.save_restore_balance(
               BuggyAuthority.nested_cursor_save()
             )

           depth > 1
         end},
        {"INV-5 doubled region re-set",
         fn ->
           SealOracle.region_sets(BuggyAuthority.double_region_set(@region_top)) !=
             [{1, @region_top}]
         end},
        {"INV-5 wrong region bounds",
         fn ->
           SealOracle.region_sets(
             BuggyAuthority.wrong_region_bounds(@region_top)
           ) !=
             [{1, @region_top}]
         end},
        {"INV-6 keyframe touches history row",
         fn ->
           @region_top in SealOracle.cup_rows(
             BuggyAuthority.keyframe_history_touch(@region_top)
           )
         end},
        {"fail-closed IL row shift",
         fn ->
           match?(
             {:unverifiable, _},
             SealOracle.row_walk(BuggyAuthority.il_shift())
           )
         end},
        {"fail-closed partial ED",
         fn ->
           match?(
             {:unverifiable, _},
             SealOracle.row_walk(BuggyAuthority.ed_partial())
           )
         end}
      ]

      for {name, detected?} <- kill_matrix do
        assert detected?.(), "kill stream NOT detected: #{name}"
      end
    end
  end

  describe "IOAuthority (production stub) parity with CaptureAuthority" do
    test "emits the same bytes CaptureAuthority records, minus the tags" do
      import ExUnit.CaptureIO

      capture_state = CaptureAuthority.new(@width, @height, @region_top)
      capture_state = CaptureAuthority.append_sealed(capture_state, "hello\r\n")
      capture_state = CaptureAuthority.repaint_footer(capture_state, "status")

      capture_state =
        CaptureAuthority.with_cursor(capture_state, :footer, fn t ->
          CaptureAuthority.repaint_footer(t, "bracketed")
        end)

      capture_state = CaptureAuthority.resize(capture_state, 80, 24)

      io_bytes =
        capture_io(fn ->
          io_state = IOAuthority.new(@width, @height, @region_top)
          io_state = IOAuthority.append_sealed(io_state, "hello\r\n")
          io_state = IOAuthority.repaint_footer(io_state, "status")

          io_state =
            IOAuthority.with_cursor(io_state, :footer, fn t ->
              IOAuthority.repaint_footer(t, "bracketed")
            end)

          _io_state = IOAuthority.resize(io_state, 80, 24)
        end)

      assert io_bytes == CaptureAuthority.raw(capture_state)
    end

    test "region_top defaults to a one-row footer when unspecified" do
      state = IOAuthority.new(@width, @height)
      assert IOAuthority.region_top(state) == @height - 1
    end
  end
end
