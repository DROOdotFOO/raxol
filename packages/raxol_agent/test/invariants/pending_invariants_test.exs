defmodule Raxol.Agent.Invariants.PendingInvariantsTest do
  @moduledoc """
  Tier-2 invariant SKELETONS: written now as `@tag :pending_unit`, activated
  when their named unit lands.

  Every test here is `@tag :pending_unit` and excluded in `test_helper.exs` —
  visible in the suite (counted as excluded), never run, never silently green.
  When the named unit lands, delete the tag, replace the `flunk/1` with the
  real property, and move the test into its tier-1 module if it fits better
  there. Writing these now is deliberate: they lock the WORDING of each
  contract before the implementation exists, so the unit is built against the
  property instead of the property being fitted to the unit.
  """
  use ExUnit.Case, async: true

  @moduletag :pending_unit

  # U4 (reattach): ∀ offset o ∈ 0..max:
  #   read(0..o−1) ++ attach_live(o..) == full durable stream — as a SEQUENCE,
  #   not a multiset (grok top-2; ordering bugs hide behind multiset equality).
  test "U4 — reattach at every offset yields the full durable stream as a sequence, gap-free and dup-free" do
    flunk(
      "pending: activates with U4 (reattach). Property: replay(0..o-1) ++ live_from(o) == full durable sequence, ∀ o."
    )
  end

  # U4 (late subscriber): a subscriber attaching mid-stream never receives an
  # earlier durable delivered as "live"; its first live id ≥ requested offset.
  test "U4 — late subscriber monotonic catch-up: no earlier durable ever arrives as live" do
    flunk(
      "pending: activates with U4 (reattach). Property: first live id ≥ from_offset; no pre-offset durable on the live channel."
    )
  end

  # U5 (interrupt): the staged-kill pipeline is ordered
  #   signal → wait → os_group_kill → turn_completed|error
  # and no tool_result for that turn's port lands after kill-complete.
  test "U5 — staged kill order: signal → wait → os_group_kill → bracket; no tool_result after kill-complete" do
    flunk(
      "pending: activates with U5 (interrupt). Property: event order ⊆ the staged-kill sequence; port results fenced by the kill."
    )
  end

  # U6 (steer CAS): a steer carrying a stale expected_turn_id is rejected with
  # a reject event and ZERO model effect (the CAS the turn_id snapshot protects).
  test "U6 — steer CAS: stale expected_turn_id → reject event, zero model effect" do
    flunk(
      "pending: activates with U6 (steer). Property: only expected_turn_id == current applies; stale → reject + unchanged model fold."
    )
  end

  # U9 (checkpoint): every checkpoint pointer references an existing journal
  # offset and fold(0..ptr) ⊕ snapshot == fold(0..now) for projection keys.
  test "U9 — checkpoint pointer validity: fold(0..ptr) ⊕ snapshot == fold(0..now)" do
    flunk(
      "pending: activates with U9 (checkpoint). Property: pointer offset exists; snapshot composes with the tail fold."
    )
  end

  # U9 × U7 (checkpoint vs spend-gate): a checkpoint never lands between a
  # spend-gate reserve and its terminal (commit/release) — restore would strand
  # or double the reservation.
  test "U9/U7 — never checkpoint mid-reserve: no checkpoint between reserve and commit/release" do
    flunk(
      "pending: activates with U9 (checkpoint) + U7 (spend gate). Property: journal order forbids checkpoint inside a reserve window; restored ledger reserved == journal reserved."
    )
  end

  # U7 (spend gate): journal order per paid call is
  #   reserve → call_started → outcome → release/commit,
  # and no call ever starts without a prior reserve for the same call_id.
  test "U7 — reserve-before-call: no call_started without a prior reserve for the same call_id" do
    flunk(
      "pending: activates with U7 (spend gate). Property: per-call_id journal order reserve → call_started → outcome → release/commit."
    )
  end

  # U8 (approval gate): a write-tool call without approval opens NO Port and
  # leaves a durable approval_required; after a deny, no later durable claims
  # success for that call_id (fail-closed, permanently).
  test "U8 — approval fail-closed: no Port without approval; deny is terminal for the call_id" do
    flunk(
      "pending: activates with U8 (approval gate). Property: unapproved write-tool → no side effect + durable approval_required; post-deny success for the call_id is a contract violation."
    )
  end

  # Causality (cross-unit): every tool_result.call_id has a prior tool_call
  # with the same id in the same turn, and after any fail-closed path no
  # subsequent durable claims success for the failed op_id.
  test "causality — every tool_result has a prior same-turn tool_call; fail-closed ops never later succeed" do
    flunk(
      "pending: activates with the tool-call vocabulary. Property: call_id causality within a turn; failed op_ids are terminal."
    )
  end
end
