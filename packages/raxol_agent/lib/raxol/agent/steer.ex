defmodule Raxol.Agent.Steer do
  @moduledoc """
  U6 — Steer: redirect a running turn with new user input WITHOUT killing it.

  Steer is the sibling of interrupt (U5): interrupt is *kill now*, steer is
  *inject at the next boundary*. The two are distinct signals (protocol §4;
  AD-2). This module owns the **decision core** of steer: the
  `expected_turn_id` compare-and-swap (AD-13) plus the `client_msg_id`
  idempotency check (freeze-contracts §5.1). Everything else — finding the live
  turn process, writing the durable event, letting the model see the steering
  text at the next boundary — is the session runtime's job; it drives this pure
  function.

  ## The CAS state machine (the frozen seam)

  A steer command carries the `turn_id` it believes is running. `resolve/2` is
  the pure decision:

    * **Accept** — `request.expected_turn_id == state.turn_id`, AND a turn is
      actually running (`state.turn_id != nil`). A durable steer event is
      appended to the target turn (correct attribution), the CAS token is
      swapped forward, and the `client_msg_id` is memoised for idempotency.
      Returns `{:ok, {:accepted, ref}}`.
    * **Stale reject** — `request.expected_turn_id != state.turn_id` (the turn
      already ended, or another steer won the race). Returns
      `{:error, {:stale_turn, expected, actual}}`. **Nothing is journaled and
      the state is unchanged** — no silent misdirection of input into the wrong
      turn (zero model effect).
    * **No-live-turn reject** — `state.turn_id == nil` (an idle session with no
      running turn), regardless of what `expected_turn_id` the request carries.
      Returns `{:error, :no_live_turn}`, state unchanged. This is a DISTINCT
      case from stale reject, checked before the general CAS comparison: `nil
      == nil` must never read as "the CAS matched" — a steer landing on a
      nonexistent turn is the same silent-misdirection hazard the CAS exists to
      prevent, just at the boundary instead of mid-race.
    * **Duplicate** — the same `(session, client_msg_id)` re-delivered with the
      SAME payload (mobile retry over a flaky wire, §5.1). Returns
      `{:ok, {:duplicate, ref}}` referencing the ORIGINAL accept — one durable
      event, never a second turn.
    * **`client_msg_id` reuse reject** — the same `(session, client_msg_id)`
      re-delivered with a DIFFERENT payload (different `text`). This is never
      treated as a duplicate: a reused idempotency key carrying new content is
      a client bug or an attacker attempting to suppress new steering text
      under an old key. Returns `{:error, :client_msg_id_reuse}`, state
      unchanged — nothing is journaled, and the ORIGINAL accept is left
      untouched.

  `resolve/2` returns `{result, next_state}`; the session threads the state
  through the running turn process (its mailbox serialises concurrent steers, so
  "racing" steers resolve in a well-defined order and exactly one wins the CAS).

  ## CAS token uniqueness (ABA-safety, the load-bearing swap law)

  The CAS token issued after every accept MUST be **distinct from every
  previously observed token in that turn's history**, not merely different from
  the immediately-current one. A weaker `swap(cur) != cur` law is
  ABA-vulnerable: a token space that cycles (a boolean toggle, or a repeatable
  counter) can return to an EQUAL value after the turn advances, and a steer
  built against a stale earlier token would then wrongly pass the CAS once the
  token cycles back — exactly the "silent misdirection into the wrong turn"
  this mechanism exists to prevent. Implementations satisfy this with a
  globally-unique generator (e.g. `System.unique_integer/1`), never a
  finite/repeatable token space.

  ## Idempotency is journal-truth, not process memory (§5.1)

  The dedup window is the **session lifetime**, and the **journal is the dedup
  truth**: an accepted steer records its `client_msg_id` in the durable event's
  payload, and the in-memory dedup index is REBUILT BY FOLD over the journal on
  restart/replay (`rebuild/1`). So a `client_msg_id` re-delivered after a BEAM
  restart still deduplicates — process-local dedup state that is lost on restart
  is a bug, not a shortcut. A duplicate is a live ack referencing the original;
  nothing new is journaled for it.

  ## Status

  **Implemented (U6).** `resolve/2` and `rebuild/1` land the decision core above;
  the permanent suite in `test/raxol/agent/red/u6_steer_red_test.exs` — authored
  against this frozen shape — now runs GREEN in CI (the `@moduletag :harness_red`
  exclusion was dropped once the impl satisfied every contour). The negative
  controls (dead-injector detection) continue to run in CI against the reference
  oracle and injectors.
  """

  defmodule Request do
    @moduledoc """
    A steer request: the steering text, the CAS token the caller believes is
    running (`expected_turn_id`), and the client-supplied idempotency key
    (`client_msg_id`, §5.1 — generated client-side, never offset-derived).
    """

    @enforce_keys [:expected_turn_id]
    defstruct [:text, :expected_turn_id, :client_msg_id]

    @type t :: %__MODULE__{
            text: String.t() | nil,
            expected_turn_id: term(),
            client_msg_id: term() | nil
          }
  end

  defmodule TurnState do
    @moduledoc """
    The steer-relevant slice of a running turn's state, threaded through
    `Raxol.Agent.Steer.resolve/2`.

      * `turn_id` — the current CAS token (the running turn).
      * `seen`    — idempotency memory: `client_msg_id => accepted ref`.
      * `log`     — the append-only list of durable steer events landed in this
        turn (the pure-model stand-in for the journal; the runtime writes the
        real durable records).
    """

    defstruct turn_id: nil, seen: %{}, log: []

    @type t :: %__MODULE__{
            turn_id: term(),
            seen: %{optional(term()) => term()},
            log: [map()]
          }
  end

  @typedoc "A reference to an accepted steer — the turn it landed in and its position."
  @type accepted_ref :: %{
          turn_id: term(),
          offset: non_neg_integer(),
          client_msg_id: term() | nil
        }

  @typedoc "The typed outcome of a steer decision."
  @type result ::
          {:ok, {:accepted, accepted_ref()}}
          | {:ok, {:duplicate, accepted_ref()}}
          | {:error, {:stale_turn, term(), term()}}
          | {:error, :no_live_turn}
          | {:error, :client_msg_id_reuse}

  @doc """
  Resolve a steer request against the running turn's steer state.

  Returns `{result, next_state}`. See the moduledoc for the accept / stale-reject
  / duplicate semantics. Deterministic and side-effect-free: the session runtime
  supplies the state and consumes the returned state + result.
  """
  @callback resolve(TurnState.t(), Request.t()) :: {result(), TurnState.t()}

  @doc """
  Rebuild the steer dedup state by folding over the durable journal (§5.1).

  The journal is the dedup truth: each accepted steer recorded its
  `client_msg_id` in the durable event payload, so replaying the durable records
  reconstructs the `TurnState.seen` idempotency index. This is what makes a
  `client_msg_id` re-delivered after a BEAM restart still deduplicate — the
  in-memory index is derived from the log, never held only in process memory.

  `journal` is the durable steer records in offset order.
  """
  @callback rebuild(journal :: [map()]) :: TurnState.t()

  @doc """
  Resolve a steer request (see the `resolve/2` callback).

  Decision order is load-bearing (freeze-contracts §5.1 + AD-13):

    1. **Idempotency first** — a re-delivered `client_msg_id` is resolved against
       the journal-derived dedup index BEFORE the CAS, so a duplicate still
       deduplicates after a restart even when a different turn is running. Same
       payload → `{:ok, {:duplicate, ref}}` (the ORIGINAL accept); different
       payload → `{:error, :client_msg_id_reuse}`. Both leave the state
       unchanged.
    2. **No live turn** — `turn_id == nil` → `{:error, :no_live_turn}`, state
       unchanged. Checked before the CAS so a `nil == nil` request can never be
       read as a real match (Drew's nil-turn tooth).
    3. **CAS** — `expected_turn_id != turn_id` → `{:error, {:stale_turn, exp,
       act}}`, state unchanged (nothing journaled, zero model effect).
    4. **Accept** — append one durable steer event to the target turn, swap the
       CAS token forward to a globally-unique (ABA-safe) value, memoise the
       `client_msg_id` + payload.
  """
  @spec resolve(TurnState.t(), Request.t()) :: {result(), TurnState.t()}
  def resolve(
        %TurnState{turn_id: cur, seen: seen, log: log} = state,
        %Request{expected_turn_id: expected, client_msg_id: cmid, text: text}
      ) do
    cond do
      not is_nil(cmid) and Map.has_key?(seen, cmid) ->
        resolve_seen(state, Map.fetch!(seen, cmid), text)

      is_nil(cur) ->
        # No turn is running — a fresh steer has nowhere to land. `expected ==
        # nil` must NOT be read as a CAS match (silent-misdirection guard).
        {{:error, :no_live_turn}, state}

      expected != cur ->
        # Stale — the turn changed (ended, or another steer won the race). No
        # journaling, no token swap: zero model effect.
        {{:error, {:stale_turn, expected, cur}}, state}

      true ->
        accept(cur, seen, log, cmid, text)
    end
  end

  # (1) idempotency — same cmid seen before. The payload MUST match, or this is a
  # reused key carrying new content (a client bug/attack), never a retry (§5.1).
  defp resolve_seen(state, %{ref: ref, text: original_text}, text) do
    if original_text == text do
      {{:ok, {:duplicate, ref}}, state}
    else
      {{:error, :client_msg_id_reuse}, state}
    end
  end

  # (4) accept — land a durable event in the TARGET turn, swap the token forward.
  defp accept(cur, seen, log, cmid, text) do
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

    next = %TurnState{turn_id: swap(cur), seen: seen2, log: log ++ [event]}

    {{:ok, {:accepted, ref}}, next}
  end

  @doc """
  Rebuild the dedup index from the durable journal (see the `rebuild/1`
  callback).

  The journal is the dedup truth (§5.1): each accepted steer stored its
  `client_msg_id` AND its `text`, so folding the durable steer records back into
  the idempotency index survives a BEAM restart with the payload-mismatch check
  intact. `turn_id` is NOT reconstructed here — it comes from the loop's turn
  brackets on resume; dedup is checked before the CAS, so a duplicate is caught
  regardless of which turn is running after the restart.
  """
  @spec rebuild([map()]) :: TurnState.t()
  def rebuild(journal) when is_list(journal) do
    seen =
      journal
      |> Enum.filter(&(&1[:type] == :steer and not is_nil(&1[:client_msg_id])))
      |> Map.new(fn ev ->
        ref = %{turn_id: ev[:turn_id], offset: ev[:offset], client_msg_id: ev[:client_msg_id]}
        {ev[:client_msg_id], %{ref: ref, text: ev[:text]}}
      end)

    %TurnState{turn_id: nil, seen: seen, log: journal}
  end

  # The CAS swap: a fresh token, GLOBALLY DISTINCT from every token this turn has
  # ever held (not merely different from the current one) — the ABA-safety law.
  # `System.unique_integer/1` guarantees this; a boolean toggle or a repeatable
  # per-turn counter would NOT (see `SteerInjectors.RepeatableToken`).
  defp swap(cur), do: {:steered, cur, System.unique_integer([:positive])}
end
