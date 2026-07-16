defmodule Raxol.Agent.Red.U6SteerRedTest do
  @moduledoc """
  U6-R — the permanent red suite for U6 "Steer" (AD-13), authored BEFORE the
  implementation exists.

  Steer = redirect a running turn with new user input WITHOUT killing it. The
  core mechanism is `expected_turn_id` compare-and-swap: a steer command carries
  the turn it believes is running; if the actual current turn differs (the turn
  ended, or another steer already won), the steer is REJECTED with a typed error
  — never silently misdirected into the wrong turn. An accepted steer lands a
  durable event in the target turn; a duplicate `client_msg_id` deduplicates
  (freeze-contracts §5.1).

  ## Red-first discipline

  Every test here drives `Raxol.Agent.Steer.resolve/2`. This suite was authored
  red-first — the contract frozen in executable form before the code existed —
  and the unit was built until these went green, never the reverse. U6 has now
  landed, so `@moduletag :harness_red` is dropped and this suite runs GREEN in
  CI.

  The contours live in `Raxol.Agent.Red.SteerContours` (the single source of
  truth); the in-CI negative controls (`u6_steer_controls_test.exs`) run those
  same contours against dead injectors to prove none of these tests is vacuous.

  Part of the red-first fan-out authored against docs PR #569.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Red.SteerContours
  alias Raxol.Agent.Steer

  describe "POSITIVE contours (fail until U6 lands)" do
    test "steer with a correct expected_turn_id lands: durable event, correct turn attribution" do
      SteerContours.assert_lands(Steer)
    end

    test "steer with a stale expected_turn_id is rejected with {:error, {:stale_turn, expected, actual}}" do
      SteerContours.assert_stale_reject(Steer)
    end

    test "nothing is journaled on reject (zero model effect)" do
      SteerContours.assert_nothing_on_reject(Steer)
    end

    test "serialized CAS ordering: exactly one steer wins per schedule, the loser gets a typed reject (seed-reproducible)" do
      # The property is order-independent — assert it across a spread of
      # seed-chosen schedules so a one-sided implementation can't slip through.
      for seed <- 0..9 do
        SteerContours.assert_serialized_cas_order(Steer, seed)
      end
    end

    test "duplicate client_msg_id deduplicates: one durable event, second delivery acked-as-duplicate" do
      SteerContours.assert_dedup(Steer)
    end

    test "idempotency survives a BEAM restart: dedup index rebuilt by journal fold (§5.1)" do
      SteerContours.assert_dedup_survives_restart(Steer)
    end

    test "the CAS token is distinct from every previously observed token, not just the current one (ABA hazard, AD-13)" do
      SteerContours.assert_token_uniqueness(Steer)
    end

    test "a steer against a session with no running turn is rejected with {:error, :no_live_turn}" do
      SteerContours.assert_no_live_turn_reject(Steer)
    end

    test "a re-delivered client_msg_id carrying a different payload is rejected with {:error, :client_msg_id_reuse}" do
      SteerContours.assert_dedup_payload_mismatch_rejected(Steer)
    end

    test "two steers with a nil client_msg_id are never deduped against each other" do
      SteerContours.assert_nil_client_msg_id_not_deduped(Steer)
    end
  end
end
