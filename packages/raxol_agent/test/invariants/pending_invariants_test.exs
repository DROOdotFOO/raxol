defmodule Raxol.Agent.Invariants.PendingInvariantsTest do
  @moduledoc """
  Invariant SKELETONS for checkpoint, spend-gate and tool-call causality
  properties that no test asserts yet.

  Every test here is `@tag :pending_unit` and excluded in `test_helper.exs` —
  visible in the suite (counted as excluded), never run, never silently green.
  Each one fixes the wording of a property: to activate it, delete the tag
  and replace the `flunk/1` with the real property.
  """
  use ExUnit.Case, async: true

  @moduletag :pending_unit

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

  # Causality (cross-unit): every tool_result.call_id has a prior tool_call
  # with the same id in the same turn, and after any fail-closed path no
  # subsequent durable claims success for the failed op_id.
  test "causality — every tool_result has a prior same-turn tool_call; fail-closed ops never later succeed" do
    flunk(
      "pending: activates with the tool-call vocabulary. Property: call_id causality within a turn; failed op_ids are terminal."
    )
  end
end
