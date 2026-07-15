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

  Every test here drives `Raxol.Agent.Steer.resolve/2`, which is a skeleton that
  raises `:not_implemented`. So every test FAILS today — that is the point: the
  contract is frozen in executable form before the code exists, and the unit is
  built until these go green (drop `@moduletag :harness_red`), never the reverse.

  `@moduletag :harness_red` is excluded in `test_helper.exs`, so CI stays green
  while this suite is red. The contours live in `Raxol.Agent.Red.SteerContours`
  (the single source of truth); the in-CI negative controls
  (`u6_steer_controls_test.exs`) run those same contours against dead injectors
  to prove none of these reds is vacuous.

  Part of the red-first fan-out authored against docs PR #569.
  """
  use ExUnit.Case, async: true

  @moduletag :harness_red

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

    test "concurrent racing steers: exactly one wins the CAS, the loser gets a typed reject (seed-reproducible)" do
      # The property is order-independent — assert it across a spread of
      # seed-chosen schedules so a one-sided implementation can't slip through.
      for seed <- 0..9 do
        SteerContours.assert_one_winner(Steer, seed)
      end
    end

    test "duplicate client_msg_id deduplicates: one durable event, second delivery acked-as-duplicate" do
      SteerContours.assert_dedup(Steer)
    end

    test "idempotency survives a BEAM restart: dedup index rebuilt by journal fold (§5.1)" do
      SteerContours.assert_dedup_survives_restart(Steer)
    end
  end
end
