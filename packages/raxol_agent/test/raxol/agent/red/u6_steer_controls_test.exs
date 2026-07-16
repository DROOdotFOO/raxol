defmodule Raxol.Agent.Red.U6SteerControlsTest do
  @moduledoc """
  U6-R negative controls — dead-injector detection for the steer red suite.

  These RUN IN CI (no `:harness_red` tag). They never touch the unimplemented
  `Raxol.Agent.Steer`; instead they exercise the same contours
  (`Raxol.Agent.Red.SteerContours`) the reds use against:

    * a CORRECT reference (`Raxol.Agent.Red.SteerReference`) — asserts every
      contour PASSES, so no red is vacuously failing (the checker can be
      satisfied); and
    * seven dead injectors (`Raxol.Agent.Red.SteerInjectors`) — asserts each one
      FAILS its target contour, so no red is a green lie (the checker catches its
      breakage).

  Plus the meta-invariant obligations (harness-invariants.md): fired-counters on
  every fault site (a site that stops injecting fails the control), and a
  seed-reproducible racing-steer schedule.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Raxol.Agent.Red.SteerContours
  alias Raxol.Agent.Red.SteerFaults

  alias Raxol.Agent.Red.SteerInjectors.{
    DropDedup,
    IgnorePayloadMismatch,
    InMemoryOnlyDedup,
    JournalBeforeCas,
    NilTurnAccept,
    RepeatableToken,
    SkipCas
  }

  alias Raxol.Agent.Red.SteerReference

  describe "the checkers are not vacuous (a correct impl is green)" do
    test "the reference implementation satisfies every U6 steer contour" do
      SteerContours.assert_lands(SteerReference)
      SteerContours.assert_stale_reject(SteerReference)
      SteerContours.assert_nothing_on_reject(SteerReference)
      SteerContours.assert_dedup(SteerReference)
      SteerContours.assert_dedup_survives_restart(SteerReference)
      SteerContours.assert_token_uniqueness(SteerReference)
      SteerContours.assert_no_live_turn_reject(SteerReference)
      SteerContours.assert_dedup_payload_mismatch_rejected(SteerReference)
      SteerContours.assert_nil_client_msg_id_not_deduped(SteerReference)
      for seed <- 0..9, do: SteerContours.assert_serialized_cas_order(SteerReference, seed)
    end
  end

  describe "the checkers are not green lies (each dead injector is caught)" do
    test "every dead injector fails its target contour, and every fault site fired" do
      harness = SteerFaults.new()
      for site <- SteerFaults.sites(), do: SteerFaults.arm(harness, site)

      # (a) skip-CAS applies any steer → must fail stale-reject.
      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_stale_reject(SkipCas)
      end

      SteerFaults.record_fired(harness, :skip_cas)

      # (b) journal-before-CAS writes then rejects → must fail nothing-on-reject.
      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_nothing_on_reject(JournalBeforeCas)
      end

      SteerFaults.record_fired(harness, :journal_before_cas)

      # (c) drop-dedup has no idempotency memory → must fail deduplication.
      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_dedup(DropDedup)
      end

      SteerFaults.record_fired(harness, :drop_dedup)

      # (c-variant) in-memory-only dedup: dedup index not rebuilt from the
      # journal → the post-restart redelivery is no longer recognised.
      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_dedup_survives_restart(InMemoryOnlyDedup)
      end

      SteerFaults.record_fired(harness, :in_memory_only_dedup)

      # (d) repeatable token: the CAS token cycles (ABA) → must fail
      # token-uniqueness even though every individual swap looks fine.
      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_token_uniqueness(RepeatableToken)
      end

      SteerFaults.record_fired(harness, :repeatable_token)

      # (e) nil-turn accept: skips the no-live-turn guard → must fail the
      # no-live-turn contour.
      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_no_live_turn_reject(NilTurnAccept)
      end

      SteerFaults.record_fired(harness, :nil_turn_accept)

      # (f) ignore-payload-mismatch: dedups on cmid alone → must fail the
      # dedup-payload-mismatch contour.
      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_dedup_payload_mismatch_rejected(IgnorePayloadMismatch)
      end

      SteerFaults.record_fired(harness, :ignore_payload_mismatch)

      # Meta-invariant 1: a fault site that never fired = a dead injector.
      SteerFaults.assert_all_fired!(harness, {:u6_steer_controls, SteerFaults.sites()})
    end

    test "an armed fault site that never fires FAILS the control (dead-injector detection is real)" do
      harness = SteerFaults.new()
      SteerFaults.arm(harness, :skip_cas)
      SteerFaults.arm(harness, :drop_dedup)
      SteerFaults.record_fired(harness, :skip_cas)

      err =
        assert_raise ExUnit.AssertionError, fn ->
          SteerFaults.assert_all_fired!(harness, [:u6, :schedule])
        end

      assert err.message =~ "dead injector"
      assert err.message =~ "drop_dedup"
      refute err.message =~ ~r/dead injector.*skip_cas/
      assert err.message =~ "[:u6, :schedule]"
    end
  end

  describe "the injectors are specific, not blanket breakage" do
    # Discrimination matters: if an injector broke EVERY contour, "it fails its
    # target red" would be meaningless. Each breaks exactly one arm.
    test "journal-before-CAS still returns the correct typed stale reject" do
      # It dirties the log, but the returned value is right — so it PASSES
      # stale-reject (whose concern is the return value) while FAILING
      # nothing-on-reject (asserted above).
      SteerContours.assert_stale_reject(JournalBeforeCas)
    end

    test "skip-CAS still lands a valid accept and deduplicates" do
      SteerContours.assert_lands(SkipCas)
      SteerContours.assert_dedup(SkipCas)
    end

    test "drop-dedup still lands, rejects stale steers, and picks one CAS-order winner" do
      SteerContours.assert_lands(DropDedup)
      SteerContours.assert_stale_reject(DropDedup)
      for seed <- 0..9, do: SteerContours.assert_serialized_cas_order(DropDedup, seed)
    end

    test "in-memory-only dedup PASSES in-process dedup but FAILS only across restart" do
      # It dedups correctly within a process (resolve is faithful) — the breakage
      # is exclusively that the index isn't rebuilt from the journal on restart.
      SteerContours.assert_dedup(InMemoryOnlyDedup)
      SteerContours.assert_lands(InMemoryOnlyDedup)
      SteerContours.assert_stale_reject(InMemoryOnlyDedup)

      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_dedup_survives_restart(InMemoryOnlyDedup)
      end
    end

    test "repeatable-token still lands, rejects stale steers, dedups, and picks one CAS-order winner — only token uniqueness breaks" do
      SteerContours.assert_lands(RepeatableToken)
      SteerContours.assert_stale_reject(RepeatableToken)
      SteerContours.assert_nothing_on_reject(RepeatableToken)
      SteerContours.assert_dedup(RepeatableToken)
      SteerContours.assert_dedup_survives_restart(RepeatableToken)
      SteerContours.assert_no_live_turn_reject(RepeatableToken)
      for seed <- 0..9, do: SteerContours.assert_serialized_cas_order(RepeatableToken, seed)

      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_token_uniqueness(RepeatableToken)
      end
    end

    test "nil-turn-accept still lands, rejects stale (non-nil) steers, dedups, and is ABA-safe — only the no-live-turn guard breaks" do
      SteerContours.assert_lands(NilTurnAccept)
      SteerContours.assert_stale_reject(NilTurnAccept)
      SteerContours.assert_nothing_on_reject(NilTurnAccept)
      SteerContours.assert_dedup(NilTurnAccept)
      SteerContours.assert_dedup_survives_restart(NilTurnAccept)
      SteerContours.assert_token_uniqueness(NilTurnAccept)

      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_no_live_turn_reject(NilTurnAccept)
      end
    end

    test "ignore-payload-mismatch still lands, rejects stale steers, dedups same-payload retries, and is ABA-safe — only payload-mismatch detection breaks" do
      SteerContours.assert_lands(IgnorePayloadMismatch)
      SteerContours.assert_stale_reject(IgnorePayloadMismatch)
      SteerContours.assert_nothing_on_reject(IgnorePayloadMismatch)
      SteerContours.assert_dedup(IgnorePayloadMismatch)
      SteerContours.assert_dedup_survives_restart(IgnorePayloadMismatch)
      SteerContours.assert_token_uniqueness(IgnorePayloadMismatch)
      SteerContours.assert_no_live_turn_reject(IgnorePayloadMismatch)

      assert_raise ExUnit.AssertionError, fn ->
        SteerContours.assert_dedup_payload_mismatch_rejected(IgnorePayloadMismatch)
      end
    end
  end

  describe "the racing-steer schedule is seed-reproducible" do
    test "the same seed always picks the same winner; different schedules can flip it" do
      # Reproducible: a fixed seed is deterministic across runs.
      assert SteerContours.winner(SteerReference, 7) ==
               SteerContours.winner(SteerReference, 7)

      assert SteerContours.winner(SteerReference, 4) ==
               SteerContours.winner(SteerReference, 4)

      # The schedule genuinely varies — even and odd seeds serialise the two
      # steers in opposite orders, so the winner flips (the race isn't rigged).
      assert SteerContours.winner(SteerReference, 0) == "m1"
      assert SteerContours.winner(SteerReference, 1) == "m2"
    end
  end
end
