defmodule Raxol.Earn.Xochi.SolverAgentPropertyTest do
  @moduledoc """
  Invariants behind two money-safety properties of the Xochi solver storefront:

  1. The storefront budget (the fee) never exceeds the transfer, for any transfer
     size and fee bps. The transfer settles through Xochi off-escrow, so the ACP
     budget only ever holds the fee -- a fraction of the transfer, never the
     transfer itself.

  2. A funded job settles only the session at its own `{chain_id, job_id}`, never
     another session, regardless of what else is in flight. This is the guard
     against a single funding event fanning out and spending funds for jobs that
     were never funded.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Earn.Xochi.SolverAgent

  @fundable [:budget_proposed, :awaiting_fund]

  # -- budget_for/2 --

  property "the storefront fee never exceeds the transfer for a fractional fee" do
    check all(
            transfer <- integer(0..1_000_000_000_000_000_000_000_000),
            fee_bps <- integer(0..10_000)
          ) do
      # budget is the fee (<= 100% of the transfer). The transfer itself flows
      # via Xochi, never through the escrow, so the budget is always <= transfer.
      assert SolverAgent.budget_for(transfer, fee_bps) <= transfer
    end
  end

  property "a zero fee yields a zero budget" do
    check all(transfer <- integer(0..1_000_000_000_000_000_000)) do
      assert SolverAgent.budget_for(transfer, 0) == 0
    end
  end

  property "the budget never shrinks as the fee grows (monotonic in fee_bps)" do
    check all(
            transfer <- integer(0..1_000_000_000_000_000_000),
            {lo, hi} <- ordered_fee_pair()
          ) do
      assert SolverAgent.budget_for(transfer, lo) <= SolverAgent.budget_for(transfer, hi)
    end
  end

  # -- settle_target/2 --

  property "settle_target selects only the funded key, never another session" do
    check all(
            sessions <- sessions_gen(),
            key <- job_key_gen()
          ) do
      case SolverAgent.settle_target(sessions, key) do
        {:ok, selected_key, session} ->
          assert selected_key == key
          assert session == Map.fetch!(sessions, key)
          assert session.status in @fundable

        :none ->
          case Map.fetch(sessions, key) do
            {:ok, %{status: status}} -> assert status not in @fundable
            :error -> assert true
          end
      end
    end
  end

  property "the target for a key ignores every other session in flight" do
    check all(
            sessions <- sessions_gen(),
            key <- job_key_gen(),
            other <- sessions_gen()
          ) do
      # Merge unrelated sessions at other keys; the funded key's own entry wins,
      # so the decision for `key` must be unchanged. A fan-out regression (any
      # dependence on other sessions) breaks this.
      merged = Map.merge(Map.delete(other, key), sessions)

      assert SolverAgent.settle_target(merged, key) == SolverAgent.settle_target(sessions, key)
    end
  end

  # -- generators --

  defp ordered_fee_pair do
    gen all(a <- integer(0..100_000), b <- integer(0..100_000)) do
      {min(a, b), max(a, b)}
    end
  end

  # A small key space so lookups hit present and absent keys roughly evenly.
  defp job_key_gen do
    gen all(chain <- integer(1..3), job <- integer(1..5)) do
      {chain, Integer.to_string(job)}
    end
  end

  defp session_gen do
    gen all(
          status <-
            member_of([
              :awaiting_requirement,
              :budget_proposed,
              :awaiting_fund,
              :settling,
              :submitted,
              :completed,
              :rejected,
              :failed
            ])
        ) do
      %{status: status}
    end
  end

  # Built by collapsing a plain list into a map, NOT by `map_of/3`.
  #
  # `map_of/3` gets its distinct keys from `uniq_list_of`, which is rejection
  # sampling: it draws, discards duplicates, and raises
  # `StreamData.TooManyDuplicatesError` after 10 consecutive collisions. That
  # cannot work against this key space. `job_key_gen/0` spans `1..3` chains and
  # `1..5` jobs, which is FIFTEEN keys total, and `max_length: 8` asks for up to
  # eight of them -- so once seven are drawn, better than half of every
  # subsequent draw is a duplicate and ten in a row is routine. It failed in CI
  # with exactly that shape: seven keys generated, one left to find.
  #
  # Widening the key space would fix the sampling and gut the property. The
  # space is small ON PURPOSE: `key` is drawn independently, and the invariant
  # under test (a funded key settles its own session and no other) is only
  # exercised when `key` actually collides with something in `sessions`. Make
  # keys unlikely to collide and the property still passes, having tested
  # nothing.
  #
  # So the collisions stay and the rejection goes. `Map.new/1` keeps the last
  # value for a repeated key, which is the same distinct-key map `map_of/3` was
  # after, reached by construction instead of by retrying. The map may hold
  # fewer than eight entries; it always used to as well.
  defp sessions_gen do
    gen all(pairs <- list_of({job_key_gen(), session_gen()}, max_length: 8)) do
      Map.new(pairs)
    end
  end
end
