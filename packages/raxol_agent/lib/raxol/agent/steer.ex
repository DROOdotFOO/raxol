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

    * **Accept** — `request.expected_turn_id == state.turn_id`. A durable steer
      event is appended to the target turn (correct attribution), the CAS token
      is swapped forward (so a second steer built against the old token loses),
      and the `client_msg_id` is memoised for idempotency. Returns
      `{:ok, {:accepted, ref}}`.
    * **Stale reject** — `request.expected_turn_id != state.turn_id` (the turn
      already ended, or another steer won the race). Returns
      `{:error, {:stale_turn, expected, actual}}`. **Nothing is journaled and
      the state is unchanged** — no silent misdirection of input into the wrong
      turn (zero model effect).
    * **Duplicate** — the same `(session, client_msg_id)` re-delivered (mobile
      retry over a flaky wire, §5.1). Returns `{:ok, {:duplicate, ref}}`
      referencing the ORIGINAL accept — one durable event, never a second turn.

  `resolve/2` returns `{result, next_state}`; the session threads the state
  through the running turn process (its mailbox serialises concurrent steers, so
  "racing" steers resolve in a well-defined order and exactly one wins the CAS).

  ## Idempotency is journal-truth, not process memory (§5.1)

  The dedup window is the **session lifetime**, and the **journal is the dedup
  truth**: an accepted steer records its `client_msg_id` in the durable event's
  payload, and the in-memory dedup index is REBUILT BY FOLD over the journal on
  restart/replay (`rebuild/1`). So a `client_msg_id` re-delivered after a BEAM
  restart still deduplicates — process-local dedup state that is lost on restart
  is a bug, not a shortcut. A duplicate is a live ack referencing the original;
  nothing new is journaled for it.

  ## Status

  **Skeleton only (U6 enabler).** `resolve/2` raises `:not_implemented`; the
  permanent red suite in `test/raxol/agent/red/u6_steer_red_test.exs` is authored
  against this frozen shape and fails until U6 lands. The
  `@moduletag :harness_red` reds are excluded from CI so the suite stays green;
  the negative controls (dead-injector detection) run in CI.
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

  Skeleton: raises `:not_implemented`. Lands with U6.
  """
  @spec resolve(TurnState.t(), Request.t()) :: {result(), TurnState.t()}
  def resolve(%TurnState{} = _state, %Request{} = _request) do
    raise "Raxol.Agent.Steer.resolve/2 not implemented (U6 — steer via expected_turn_id CAS, AD-13)"
  end

  @doc """
  Rebuild the dedup index from the durable journal (see the `rebuild/1`
  callback).

  Skeleton: raises `:not_implemented`. Lands with U6.
  """
  @spec rebuild([map()]) :: TurnState.t()
  def rebuild(journal) when is_list(journal) do
    raise "Raxol.Agent.Steer.rebuild/1 not implemented (U6 — journal-fold dedup, §5.1)"
  end
end
