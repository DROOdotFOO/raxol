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

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Red.SteerContours
  alias Raxol.Agent.Steer
  alias Raxol.Agent.Steer.{Request, TurnState}

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

  describe "physical disk round-trip (the production seam, §5.1 + JS-FREEZE §1)" do
    # The other contours feed rebuild/1 only the ATOM-keyed in-memory log, which
    # hides the real seam: a durable steer event round-trips through the Jason
    # FileStore Reader as a STRING-keyed map with client_msg_id nested in payload.
    # This regression drives the accept through the REAL Writer, rebuilds the
    # dedup index from the SCANNED records, and proves dedup + reuse-reject still
    # fire — the untested seam the U6-I review flagged. Against the pre-fix
    # rebuild (atom-key access on a string-keyed map) the fold matches nothing,
    # `seen` rebuilds empty, and the post-restart duplicate wrongly stale-rejects.
    test "a steer written through the real FileStore, rebuilt from the scanned string-keyed records, still dedups (and rejects a reuse)" do
      base =
        Path.join(
          System.tmp_dir!(),
          "raxol_u6_steer_disk_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(base)
      on_exit(fn -> File.rm_rf(base) end)
      session = "sess-#{System.unique_integer([:positive])}"

      state = %TurnState{turn_id: "turn-A", seen: %{}, log: []}
      req = %Request{expected_turn_id: "turn-A", client_msg_id: "m-disk", text: "go left"}

      {{:ok, {:accepted, _ref}}, after_accept} = Steer.resolve(state, req)
      durable = hd(after_accept.log)

      # Sanity: the durable event nests the idempotency key in payload (§5.1).
      assert durable.payload.client_msg_id == "m-disk"

      # Write it through the REAL Writer and scan it back (as U9/U11 tests do).
      {:ok, journal} = FileStore.open(session, base_dir: base)
      assert {:ok, _offset} = FileStore.append(journal, durable)
      assert {:ok, records} = FileStore.read(journal)
      FileStore.close(journal)

      # The Reader returns STRING-keyed maps with client_msg_id nested in
      # payload — the exact shape rebuild/1 must fold, NOT the in-memory log.
      assert [%{"type" => "steer", "payload" => %{"client_msg_id" => "m-disk"}}] = records

      # BEAM restart: a different turn is running now; the dedup index is rebuilt
      # from the durable journal alone (dedup is checked before the CAS).
      restarted = %{Steer.rebuild(records) | turn_id: "turn-B"}

      # Same cmid + same payload re-delivered after restart → still a duplicate,
      # no second durable event.
      {duplicate, after_dup} = Steer.resolve(restarted, req)
      assert {:ok, {:duplicate, _}} = duplicate
      assert length(after_dup.log) == length(restarted.log)

      # Same cmid + DIFFERENT payload → reuse reject (the suppression vector),
      # state unchanged.
      reuse = %Request{expected_turn_id: "turn-B", client_msg_id: "m-disk", text: "go RIGHT"}
      {reuse_result, after_reuse} = Steer.resolve(restarted, reuse)
      assert reuse_result == {:error, :client_msg_id_reuse}
      assert after_reuse == restarted
    end
  end
end
