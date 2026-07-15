defmodule Raxol.Agent.Red.SteerReference do
  @moduledoc """
  A CORRECT reference implementation of the U6 steer CAS (`Raxol.Agent.Steer`
  behaviour), used by the U6-R negative controls.

  It exists so the contour checkers in `Raxol.Agent.Red.SteerContours` are
  provably **not vacuous**: a green suite must be green because the contract is
  honoured, not because the checker can never pass. The controls assert this
  reference satisfies every contour; the dead injectors each break exactly one.

  This is NOT the U6 implementation — it is a test oracle. When U6 lands,
  `Raxol.Agent.Steer.resolve/2` must satisfy the same checkers this reference
  does (drop `@moduletag :harness_red` and the reds go green).

  Decision order (freeze-contracts §5.1 + AD-13):

    1. **Idempotency first.** A re-delivered `client_msg_id` returns the ORIGINAL
       accept as `{:ok, {:duplicate, ref}}`, state unchanged — never a second
       durable event, even if the turn has since moved on.
    2. **CAS.** `expected_turn_id != turn_id` → `{:error, {:stale_turn, exp,
       act}}`, state unchanged (nothing journaled, zero model effect).
    3. **Accept.** Append one durable steer event to the target turn, swap the
       CAS token forward, memoise the `client_msg_id`.
  """

  @behaviour Raxol.Agent.Steer

  alias Raxol.Agent.Steer.{Request, TurnState}

  @impl Raxol.Agent.Steer
  def resolve(
        %TurnState{turn_id: cur, seen: seen, log: log} = state,
        %Request{expected_turn_id: expected, client_msg_id: cmid, text: text}
      ) do
    cond do
      not is_nil(cmid) and Map.has_key?(seen, cmid) ->
        # (1) idempotent replay — the original accept, no new durable event.
        {{:ok, {:duplicate, Map.fetch!(seen, cmid)}}, state}

      expected != cur ->
        # (2) stale — the turn changed (ended, or another steer won the race).
        {{:error, {:stale_turn, expected, cur}}, state}

      true ->
        # (3) accept — land a durable event in the TARGET turn, swap the token.
        offset = length(log) + 1
        ref = %{turn_id: cur, offset: offset, client_msg_id: cmid}

        event = %{
          type: :steer,
          tier: :durable,
          family: :loop,
          turn_id: cur,
          client_msg_id: cmid,
          text: text,
          offset: offset
        }

        seen2 = if is_nil(cmid), do: seen, else: Map.put(seen, cmid, ref)

        next = %TurnState{
          turn_id: swap(cur),
          seen: seen2,
          log: log ++ [event]
        }

        {{:ok, {:accepted, ref}}, next}
    end
  end

  @impl Raxol.Agent.Steer
  def rebuild(journal) when is_list(journal) do
    # Journal is the dedup truth (§5.1): fold the durable steer records back into
    # the idempotency index. Each accepted steer stored its client_msg_id, so the
    # index survives a BEAM restart. turn_id is NOT reconstructed here — it comes
    # from the loop's turn brackets on resume; dedup is checked before the CAS, so
    # a duplicate is caught regardless of which turn is running after the restart.
    seen =
      journal
      |> Enum.filter(&(&1[:type] == :steer and not is_nil(&1[:client_msg_id])))
      |> Map.new(fn ev ->
        {ev[:client_msg_id],
         %{turn_id: ev[:turn_id], offset: ev[:offset], client_msg_id: ev[:client_msg_id]}}
      end)

    %TurnState{turn_id: nil, seen: seen, log: journal}
  end

  # The CAS swap: a fresh, distinct token so a steer built against the old token
  # loses the race. Uniqueness comes from the runtime counter; the only frozen
  # property is `swap(cur) != cur`.
  defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
end
