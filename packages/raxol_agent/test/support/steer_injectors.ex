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
  | `InMemoryOnlyDedup` | dedup index not journal-rebuilt | post-restart dedup survival |
  | `RepeatableToken`  | CAS token uniqueness (ABA)   | token-uniqueness (AD-13)      |
  | `NilTurnAccept`    | the no-live-turn guard       | no-live-turn reject           |
  | `IgnorePayloadMismatch` | payload check on cmid reuse | dedup-payload-mismatch reject |

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
          offset: offset,
          payload: %{client_msg_id: cmid, text: text}
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
            offset: offset,
            payload: %{client_msg_id: cmid, text: text}
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
          offset: offset,
          payload: %{client_msg_id: cmid, text: text}
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

  defmodule RepeatableToken do
    @moduledoc """
    Every individual CAS decision is correct (accept/stale-reject/dedup all
    behave faithfully) — the bug is ONLY in the token issued on accept. Instead
    of a globally-unique token, the swap toggles between exactly two fixed
    values (A <-> B), so the turn's CAS token repeats after two accepts
    (A -> B -> A -> ...). A steer built against the stale first-generation
    token would wrongly pass the CAS once the token cycles back to an EQUAL
    value — the exact ABA "silent misdirection into the wrong turn" AD-13's
    uniqueness law (steer.ex moduledoc) exists to prevent. Must fail the
    token-uniqueness contour while still passing every other contour.
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
          %{ref: ref, text: original_text} = Map.fetch!(seen, cmid)

          if original_text == text do
            {{:ok, {:duplicate, ref}}, state}
          else
            {{:error, :client_msg_id_reuse}, state}
          end

        is_nil(cur) ->
          {{:error, :no_live_turn}, state}

        expected != cur ->
          {{:error, {:stale_turn, expected, cur}}, state}

        true ->
          offset = length(log) + 1
          ref = %{turn_id: cur, offset: offset, client_msg_id: cmid}

          event = %{
            type: :steer,
            tier: :durable,
            family: :loop,
            turn_id: cur,
            offset: offset,
            payload: %{client_msg_id: cmid, text: text}
          }

          seen2 =
            if is_nil(cmid), do: seen, else: Map.put(seen, cmid, %{ref: ref, text: text})

          next = %TurnState{turn_id: swap(cur), seen: seen2, log: log ++ [event]}
          {{:ok, {:accepted, ref}}, next}
      end
    end

    @impl Raxol.Agent.Steer
    def rebuild(journal), do: Raxol.Agent.Red.SteerReference.rebuild(journal)

    # The bug: only two distinct values ever exist, so the token REPEATS
    # (ABA) instead of being drawn from a growing/unique space.
    defp swap({:steered, :a}), do: {:steered, :b}
    defp swap(_cur), do: {:steered, :a}
  end

  defmodule NilTurnAccept do
    @moduledoc """
    Skips the no-live-turn guard: `resolve/2` treats `expected_turn_id: nil`
    against an idle `state.turn_id: nil` as an ordinary CAS match and ACCEPTS,
    landing a durable steer event on a session with no running turn. Every
    other decision (dedup, non-nil stale reject, accept-with-a-live-turn) is
    faithful. Must fail the no-live-turn contour.
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
          %{ref: ref, text: original_text} = Map.fetch!(seen, cmid)

          if original_text == text do
            {{:ok, {:duplicate, ref}}, state}
          else
            {{:error, :client_msg_id_reuse}, state}
          end

        # BUG: no `is_nil(cur)` guard here — `nil == nil` falls straight
        # through to the ordinary CAS clause below and reads as a match.
        expected != cur ->
          {{:error, {:stale_turn, expected, cur}}, state}

        true ->
          offset = length(log) + 1
          ref = %{turn_id: cur, offset: offset, client_msg_id: cmid}

          event = %{
            type: :steer,
            tier: :durable,
            family: :loop,
            turn_id: cur,
            offset: offset,
            payload: %{client_msg_id: cmid, text: text}
          }

          seen2 =
            if is_nil(cmid), do: seen, else: Map.put(seen, cmid, %{ref: ref, text: text})

          next = %TurnState{turn_id: swap(cur), seen: seen2, log: log ++ [event]}
          {{:ok, {:accepted, ref}}, next}
      end
    end

    @impl Raxol.Agent.Steer
    def rebuild(journal), do: Raxol.Agent.Red.SteerReference.rebuild(journal)

    defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
  end

  defmodule IgnorePayloadMismatch do
    @moduledoc """
    Dedups on `client_msg_id` alone, ignoring the payload: a second delivery
    carrying the SAME `client_msg_id` but DIFFERENT `text` is silently acked as
    a duplicate of the original instead of rejected — the suppression vector
    where an attacker (or a buggy client) reuses a cmid to silently drop new
    steering text. Every other decision is faithful. Must fail the
    dedup-payload-mismatch contour (and still pass ordinary same-payload
    dedup).
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
          # BUG: no payload comparison — ANY re-delivery of this cmid is
          # silently acked as the original, even with different text.
          %{ref: ref} = Map.fetch!(seen, cmid)
          {{:ok, {:duplicate, ref}}, state}

        is_nil(cur) ->
          {{:error, :no_live_turn}, state}

        expected != cur ->
          {{:error, {:stale_turn, expected, cur}}, state}

        true ->
          offset = length(log) + 1
          ref = %{turn_id: cur, offset: offset, client_msg_id: cmid}

          event = %{
            type: :steer,
            tier: :durable,
            family: :loop,
            turn_id: cur,
            offset: offset,
            payload: %{client_msg_id: cmid, text: text}
          }

          seen2 =
            if is_nil(cmid), do: seen, else: Map.put(seen, cmid, %{ref: ref, text: text})

          next = %TurnState{turn_id: swap(cur), seen: seen2, log: log ++ [event]}
          {{:ok, {:accepted, ref}}, next}
      end
    end

    @impl Raxol.Agent.Steer
    def rebuild(journal), do: Raxol.Agent.Red.SteerReference.rebuild(journal)

    defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
  end
end
