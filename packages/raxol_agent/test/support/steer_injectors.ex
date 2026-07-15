defmodule Raxol.Agent.Red.SteerInjectors do
  @moduledoc """
  Dead injectors for the U6-R negative controls — broken implementations of the
  `Raxol.Agent.Steer` behaviour, each violating exactly one steer invariant.

  A red suite is only worth its green: if a contour would pass on a *broken*
  implementation, the contour is dead weight. Each injector here is the specific
  breakage its target contour must catch. The controls
  (`u6_steer_controls_test.exs`) run the SAME checker the reds run, against each
  injector, and assert it fails — closing the "green lies" hole
  (harness-invariants.md meta-invariant 1/4).

  | injector           | breaks                | target red                    |
  | ------------------ | --------------------- | ----------------------------- |
  | `SkipCas`          | the CAS compare       | stale-reject                  |
  | `JournalBeforeCas` | write-after-decide    | nothing-journaled-on-reject   |
  | `DropDedup`        | idempotency memory    | duplicate deduplication       |

  Each injector is otherwise faithful, so it fails ONLY its target contour — the
  discrimination the controls assert (a blanket "everything breaks" injector
  would prove nothing).
  """

  defmodule SkipCas do
    @moduledoc """
    Skips the compare-and-swap: applies ANY steer as if `expected_turn_id`
    matched. A stale steer is (wrongly) accepted instead of rejected — the exact
    "silent misdirection of input into the wrong turn" U6 exists to prevent.
    Must fail the stale-reject contour.
    """

    @behaviour Raxol.Agent.Steer

    alias Raxol.Agent.Steer.{Request, TurnState}

    @impl Raxol.Agent.Steer
    def resolve(
          %TurnState{turn_id: cur, seen: seen, log: log} = state,
          %Request{expected_turn_id: _ignored, client_msg_id: cmid, text: text}
        ) do
      if not is_nil(cmid) and Map.has_key?(seen, cmid) do
        {{:ok, {:duplicate, Map.fetch!(seen, cmid)}}, state}
      else
        # No CAS check at all: accept unconditionally against the current token.
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
        next = %TurnState{turn_id: cur, seen: seen2, log: log ++ [event]}
        {{:ok, {:accepted, ref}}, next}
      end
    end

    # Faithful fold — SkipCas breaks only the CAS, not idempotency-across-restart.
    @impl Raxol.Agent.Steer
    def rebuild(journal), do: Raxol.Agent.Red.SteerReference.rebuild(journal)
  end

  defmodule JournalBeforeCas do
    @moduledoc """
    Appends the durable steer event BEFORE deciding the CAS. On a stale reject
    it still returns the correct `{:error, {:stale_turn, ...}}` — but the durable
    log already carries the phantom event. Must fail the
    nothing-journaled-on-reject contour (and still pass stale-reject, whose
    concern is only the return value — the discrimination the controls assert).
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
          {{:ok, {:duplicate, Map.fetch!(seen, cmid)}}, state}

        true ->
          # Journal FIRST (the bug), then decide the CAS.
          offset = length(log) + 1

          event = %{
            type: :steer,
            tier: :durable,
            family: :loop,
            turn_id: cur,
            client_msg_id: cmid,
            text: text,
            offset: offset
          }

          dirtied = %TurnState{state | log: log ++ [event]}

          if expected != cur do
            # Reject value is correct, but `dirtied.log` already grew.
            {{:error, {:stale_turn, expected, cur}}, dirtied}
          else
            ref = %{turn_id: cur, offset: offset, client_msg_id: cmid}
            seen2 = if is_nil(cmid), do: seen, else: Map.put(seen, cmid, ref)
            {{:ok, {:accepted, ref}}, %TurnState{dirtied | turn_id: swap(cur), seen: seen2}}
          end
      end
    end

    # Faithful fold — this injector breaks only write-ordering, not restart dedup.
    @impl Raxol.Agent.Steer
    def rebuild(journal), do: Raxol.Agent.Red.SteerReference.rebuild(journal)

    defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
  end

  defmodule DropDedup do
    @moduledoc """
    Drops the idempotency check: a re-delivered `client_msg_id` is treated as a
    fresh command, so it re-runs the CAS instead of returning the original accept
    as a duplicate. Must fail the deduplication contour. (Depending on the token
    state a re-delivery then either double-accepts or stale-rejects — either way
    it is never `{:ok, {:duplicate, _}}`.)
    """

    @behaviour Raxol.Agent.Steer

    alias Raxol.Agent.Steer.{Request, TurnState}

    @impl Raxol.Agent.Steer
    def resolve(
          %TurnState{turn_id: cur, seen: seen, log: log} = state,
          %Request{expected_turn_id: expected, client_msg_id: cmid, text: text}
        ) do
      # No dedup lookup at all.
      if expected != cur do
        {{:error, {:stale_turn, expected, cur}}, state}
      else
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
        next = %TurnState{turn_id: swap(cur), seen: seen2, log: log ++ [event]}
        {{:ok, {:accepted, ref}}, next}
      end
    end

    # rebuild is faithful; the missing dedup lives entirely in `resolve/2`, so
    # DropDedup fails the dedup contours by never consulting the index at all.
    @impl Raxol.Agent.Steer
    def rebuild(journal), do: Raxol.Agent.Red.SteerReference.rebuild(journal)

    defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
  end

  defmodule InMemoryOnlyDedup do
    @moduledoc """
    Deduplicates correctly WITHIN a process lifetime (`resolve/2` is faithful),
    but treats the dedup index as process-local: `rebuild/1` does NOT fold it back
    from the durable journal, so a `client_msg_id` re-delivered after a BEAM
    restart is no longer recognised (§5.1 says the journal is the dedup truth,
    session-lifetime). Must PASS the in-process dedup contour and FAIL the
    post-restart dedup contour — the exact discrimination the coordinator pinned.
    """

    @behaviour Raxol.Agent.Steer

    alias Raxol.Agent.Steer.TurnState

    @impl Raxol.Agent.Steer
    def resolve(state, request),
      do: Raxol.Agent.Red.SteerReference.resolve(state, request)

    @impl Raxol.Agent.Steer
    def rebuild(journal) when is_list(journal) do
      # The bug: dedup state was only in process memory; on restart it is empty
      # instead of folded from the journal. The durable log is preserved, but the
      # idempotency index that guards it is lost.
      %TurnState{turn_id: nil, seen: %{}, log: journal}
    end
  end
end
