defmodule Raxol.AgentClientProtocol.Session.SteerAdapter do
  @moduledoc """
  The Session's steer seam (Track E / U6-I) — the one injection point through
  which a live turn's compare-and-swap steer decision is driven.

  `Raxol.AgentClientProtocol.Session` is the single-writer turn owner Steer's
  contract demands (its `turn` field is `:idle | {:prompting, Turn} |
  {:cancelling, Turn}`, mutated only from its own mailbox). A steer decision is a
  read-modify-write over per-turn CAS state, and the concurrent-steer guarantee
  holds ONLY if that read-modify-write is serialized by exactly one owner
  process. This behaviour lets the Session BE that owner — it holds the opaque
  steer state and calls these callbacks from inside its own `handle_call`, so the
  serialization is satisfied by construction — WITHOUT the ACP package depending
  on the module that owns the pure CAS decision core
  (`Raxol.Agent.Steer.resolve/2`, in the `raxol_agent` package, which this
  package must never depend on). The `raxol_agent` side injects an adapter that
  closes over `Raxol.Agent.Steer`; this package ships only the seam and a
  default that refuses.

  ## The three callbacks and how the Session drives them

  The Session holds one OPAQUE `steer_state` term (the adapter's — this package
  never inspects it) and threads it through:

    * `turn_started(steer_state, turn_token)` — a prompt turn began; `turn_token`
      is the Session's own per-session turn ordinal (`turn_seq`), the same value
      the durable `turn_started` journal record and the client's turn events
      carry. The adapter binds it as the running turn's CAS token so a
      subsequent steer's `expected_turn_id` can match it. Returns the next
      steer_state.
    * `turn_ended(steer_state)` — the turn drained (any outcome). The adapter
      clears the CAS token so a steer arriving in the idle window between turns
      rejects `:no_live_turn` rather than landing on a dead turn. Returns the
      next steer_state. The DEDUP index (session-lifetime window, freeze §5.1)
      is NOT cleared here — only the turn liveness.
    * `resolve(steer_state, request)` — the CAS decision itself, run from the
      Session's mailbox. `request` is a plain map `%{text, expected_turn_id,
      client_msg_id}` (see `t:request/0`). Returns `{result, next_steer_state}`;
      `result` is the honest outcome vocabulary (`t:result/0`) the Session
      returns synchronously on the wire and — on `{:ok, {:accepted, _}}` only —
      the trigger to forward the steered text to the running turn and append one
      durable steer record. Rejections change nothing and journal nothing; they
      are still the wire response.

  ## Default: refuse

  `Raxol.AgentClientProtocol.Session.SteerAdapter.Unsupported` is the default. It
  holds no state, no-ops both turn hooks, and answers every `resolve/2` with
  `{:error, :no_steer_channel}` — so a base Session with no injected adapter is
  byte-identical to the frozen v2 Session (the turn hooks are identity) and
  honestly reports that live steering is not wired, exactly as the legacy lane
  did. Live steering "finally works" only once a real adapter is injected.
  """

  @typedoc """
  The normalized steer request the Session hands to `resolve/2`. Mirrors the
  `_raxol/session.steer` wire payload and `Raxol.Agent.Steer.Request`:

    * `:text` — the steering text (forwarded to the turn on accept).
    * `:expected_turn_id` — the turn ordinal the client believes is running
      (the CAS target).
    * `:client_msg_id` — the client-supplied idempotency key (may be `nil`).
  """
  @type request :: %{
          required(:text) => String.t() | nil,
          required(:expected_turn_id) => term(),
          required(:client_msg_id) => term() | nil
        }

  @typedoc "A reference to an accepted (or de-duplicated) steer."
  @type accepted_ref :: %{
          turn_id: term(),
          offset: non_neg_integer(),
          client_msg_id: term() | nil
        }

  @typedoc """
  The honest CAS outcome vocabulary — the same the Surface banner renders and
  `Raxol.AgentClientProtocol.Ext.Schema.SteerResponse` encodes on the wire.
  """
  @type result ::
          {:ok, {:accepted, accepted_ref()}}
          | {:ok, {:duplicate, accepted_ref()}}
          | {:error, {:stale_turn, term(), term()}}
          | {:error, :no_live_turn}
          | {:error, :client_msg_id_reuse}
          | {:error, :no_steer_channel}

  @doc "Bind the CAS token for a turn that just began (its per-session ordinal)."
  @callback turn_started(steer_state :: term(), turn_token :: term()) :: term()

  @doc "Clear the CAS token when the turn drained; preserve the dedup index."
  @callback turn_ended(steer_state :: term()) :: term()

  @doc "Resolve one steer request against the live turn's CAS state (single-writer)."
  @callback resolve(steer_state :: term(), request()) :: {result(), term()}
end

defmodule Raxol.AgentClientProtocol.Session.SteerAdapter.Unsupported do
  @moduledoc """
  The DEFAULT steer adapter — refuses. A Session with no injected `:steer_adapter`
  is byte-identical to the frozen v2 Session: the turn hooks are the identity
  function (they never touch `steer_state`, which stays `nil`), and `resolve/2`
  answers `{:error, :no_steer_channel}` — the same honest refusal the legacy
  non-ACP lane returns when no live `TurnState` owner exists.
  """

  @behaviour Raxol.AgentClientProtocol.Session.SteerAdapter

  @impl true
  def turn_started(steer_state, _turn_token), do: steer_state

  @impl true
  def turn_ended(steer_state), do: steer_state

  @impl true
  def resolve(steer_state, _request), do: {{:error, :no_steer_channel}, steer_state}
end
