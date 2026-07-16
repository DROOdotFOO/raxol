defmodule Raxol.Agent.SpendGate do
  @moduledoc """
  U7 — reserve-before-call at the harness primary-loop tool/provider boundary
  (AD-6a). **Skeleton only** — every function here returns
  `{:error, :not_implemented}`. The permanent U7-R red suite
  (`test/raxol/agent/red/u7_spend_gate_red_test.exs`) is authored against this
  seam *before* the implementation exists (the red-first fan-out).

  ## The law

  Every spend-bearing call (an LLM provider call, a paid tool) journals

      reserve → call → settle

  **in that order, per call**, correlated by an opaque `cost_ref`. This is the
  same reserve-before-call law the payments stack enforces at the wallet
  boundary (`Raxol.Payments.Ledger.try_spend/5` +
  `Raxol.Payments.Actions.SpendGate`), generalized to the harness loop.
  raxol_agent does **not** depend on raxol_payments (the dependency runs the
  other way), so U7 replicates the atomic `try_spend` *shape* — it does not
  import the module.

    * **Fail-closed.** No reserve ⇒ no call, EVER. A refused reserve means the
      call does not happen and a typed refusal record states why.
    * **Settlement is internal.** `settle/3` records the actual cost; the refund
      of `estimate - actual` is a Gate↔budget internal step. The `settle` record
      is the authoritative post-hoc fact — the refund is *derivable* from the
      `(reserve, settle)` pair, never a separate truth.
    * **The journal fold IS the accounting.** There is no side ledger of truth
      for the harness loop; folding the reserve/settle records reconstructs the
      spend state, including a reserve left dangling by a crash between reserve
      and call (visible in the fold, never silently lost).

  ## Observable seam (frozen by the red suite)

  The Gate emits one cost record per step through an injectable sink in
  `context` — `context.emit.(record)` where `record` is

      %{kind: :reserve | :reserve_refused | :call | :settle,
        cost_ref: String.t(),
        estimate: non_neg_integer() | nil,
        actual: non_neg_integer() | nil,
        reason: atom() | nil}

  In production the sink is wired to the per-session journal (the durable
  reserve/call/settle records — likely `family: :meta` with a `cost_ref`, per
  `harness-freeze-contracts.md` §2.1); in the red suite it is an in-memory
  recorder the checkers fold. Binding `emit` to the real journal is U7
  implementation work, not part of this skeleton.

  ## The reserve seam (frozen — binds atomicity to the GATE, not a test helper)

  Reservation is atomic against `context.try_reserve` — a callable in the
  frozen context shape:

      context.try_reserve.(estimate()) ::
        {:ok, remaining :: non_neg_integer()} | {:error, :over_limit}

  This is the `try_spend` shape (mirrors `Raxol.Payments.Ledger.try_spend/5`),
  generalized as a plain closure so raxol_agent doesn't need to depend on
  raxol_payments. **Both** the eventual U7 implementation of `reserve/3` and
  any test/injector caller MUST reserve through this SAME callable — freezing
  it here in the context shape (rather than letting each caller reach into a
  test-support module function directly) is what makes the atomicity
  guarantee a property of the GATE's contract, not an artifact of the probe.
  A run-level and session-level cap can each be represented as their own
  `try_reserve` seam, composed by the caller that builds `context`.

  **U7-I must accept and invoke `context.try_reserve`** when it implements
  `reserve/3` — wiring the production closure to the real
  `Raxol.Payments.Ledger.try_spend/5`-shaped budget is production work, not
  part of this skeleton.
  """

  @typedoc """
  Context passed to every SpendGate call. Frozen fields:

    * `:emit` — `(record :: map() -> :ok)`, the cost-journal sink.
    * `:try_reserve` — `(estimate() -> {:ok, remaining :: non_neg_integer()} |
      {:error, :over_limit})`, the atomic reserve seam (see moduledoc). BOTH
      the real gate and any test/injector implementation reserve through
      this SAME callable.

  Other fields are caller-defined and opaque to this module (e.g. an
  `agent_id`, a raw budget handle the closure above captures, ...).
  """
  @type context :: %{
          required(:emit) => (map() -> :ok),
          required(:try_reserve) => (non_neg_integer() -> {:ok, non_neg_integer()} | {:error, :over_limit}),
          optional(atom()) => term()
        }

  @typedoc "Opaque correlation id tying one reserve to its call and its settle."
  @type cost_ref :: String.t()

  @typedoc "Token estimate reserved BEFORE a spend-bearing call is made."
  @type estimate :: non_neg_integer()

  @typedoc "Actual token cost, known only AFTER the call returns."
  @type actual :: non_neg_integer()

  @typedoc "Handle for a reservation held between reserve and settle."
  @type reservation :: %{cost_ref: cost_ref(), estimate: estimate()}

  @typedoc "Why a reserve was refused (fail-closed)."
  @type refusal :: :over_run_cap | :over_session_cap | :invalid_amount | atom()

  @doc """
  Atomically reserve `estimate` tokens for the spend-bearing call `cost_ref`,
  against the run + session caps (the `try_spend` shape). On success, journals a
  `reserve` record and returns `{:ok, reservation}`. On refusal, journals a
  `reserve_refused` record and returns `{:error, {:refused, reason}}` — and the
  caller MUST NOT make the call (fail-closed).
  """
  @callback reserve(context :: context(), cost_ref(), estimate()) ::
              {:ok, reservation()} | {:error, {:refused, refusal()}}

  @doc """
  Settle a reservation with the `actual` cost once the call returned. Journals a
  `settle` record and refunds `estimate - actual` to the budget internally. The
  `settle` record is authoritative; the refund is derivable from the pair.
  """
  @callback settle(context :: context(), reservation(), actual()) :: :ok

  @doc """
  Reserve-before-call combinator — the single seam the primary loop wraps around
  every provider / paid-tool call. Reserves, then (only on a successful reserve)
  invokes `call_fun`, then settles with the actual `call_fun` reports.
  Fail-closed: on a refused reserve, `call_fun` is NEVER invoked.

  `call_fun` returns `{actual, result}`; on success the combinator returns
  `{:ok, result}`. On a refused reserve it returns
  `{:error, {:reserve_refused, reason}}`.
  """
  @callback around(
              context :: context(),
              cost_ref(),
              estimate(),
              call_fun :: (-> {actual(), result :: term()})
            ) ::
              {:ok, result :: term()} | {:error, {:reserve_refused, refusal()}}

  # --- skeleton: not implemented until U7 lands -----------------------------
  #
  # These stubs let the red suite compile and RUN (red) against a real symbol.
  # U7 replaces the bodies; the red suite turns green when it does.

  @doc false
  def reserve(_context, _cost_ref, _estimate), do: {:error, :not_implemented}

  @doc false
  def settle(_context, _reservation, _actual), do: {:error, :not_implemented}

  @doc false
  def around(_context, _cost_ref, _estimate, _call_fun), do: {:error, :not_implemented}
end
