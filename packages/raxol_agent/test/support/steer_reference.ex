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

    1. **Idempotency first.** A re-delivered `client_msg_id` carrying the SAME
       payload returns the ORIGINAL accept as `{:ok, {:duplicate, ref}}`, state
       unchanged — never a second durable event, even if the turn has since
       moved on. A re-delivery carrying a DIFFERENT payload is never a
       duplicate: `{:error, :client_msg_id_reuse}`, state unchanged (a reused
       idempotency key with new content is a client bug/attack, not a retry).
    2. **No live turn.** `turn_id == nil` (idle session) → `{:error,
       :no_live_turn}`, state unchanged, regardless of `expected_turn_id` — a
       nil-vs-nil CAS "match" must never be read as a real accept.
    3. **CAS.** `expected_turn_id != turn_id` → `{:error, {:stale_turn, exp,
       act}}`, state unchanged (nothing journaled, zero model effect).
    4. **Accept.** Append one durable steer event to the target turn, swap the
       CAS token forward to a value distinct from every token this turn has
       ever held (ABA-safe), memoise the `client_msg_id` + payload.
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
        # (1) idempotency — same cmid seen before. Payload MUST match or this
        # is a reuse, not a retry (§5.1: cmid alone is not a safe dedup key).
        %{ref: ref, text: original_text} = Map.fetch!(seen, cmid)

        if original_text == text do
          {{:ok, {:duplicate, ref}}, state}
        else
          {{:error, :client_msg_id_reuse}, state}
        end

      is_nil(cur) ->
        # (2) no turn is running — a fresh (non-duplicate) steer has nowhere to
        # land. `expected == nil` must NOT be read as a CAS match.
        {{:error, :no_live_turn}, state}

      expected != cur ->
        # (3) stale — the turn changed (ended, or another steer won the race).
        {{:error, {:stale_turn, expected, cur}}, state}

      true ->
        # (4) accept — land a durable event in the TARGET turn, swap the token.
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

        seen2 =
          if is_nil(cmid), do: seen, else: Map.put(seen, cmid, %{ref: ref, text: text})

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
    # the idempotency index. Each accepted steer stored its client_msg_id AND its
    # text, so the index survives a BEAM restart with the payload-mismatch check
    # intact. turn_id is NOT reconstructed here — it comes from the loop's turn
    # brackets on resume; dedup is checked before the CAS, so a duplicate is
    # caught regardless of which turn is running after the restart.
    seen =
      journal
      |> Enum.filter(&(&1[:type] == :steer and not is_nil(&1[:client_msg_id])))
      |> Map.new(fn ev ->
        ref = %{turn_id: ev[:turn_id], offset: ev[:offset], client_msg_id: ev[:client_msg_id]}
        {ev[:client_msg_id], %{ref: ref, text: ev[:text]}}
      end)

    %TurnState{turn_id: nil, seen: seen, log: journal}
  end

  # The CAS swap: a fresh token, GLOBALLY DISTINCT from every token this turn
  # has ever held (not merely different from the current one) — the ABA-safety
  # law (steer.ex moduledoc). `System.unique_integer/1` guarantees this; a
  # boolean toggle or a repeatable per-turn counter would NOT (see
  # `SteerInjectors.RepeatableToken`, the dead injector for this exact bug).
  defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
end
