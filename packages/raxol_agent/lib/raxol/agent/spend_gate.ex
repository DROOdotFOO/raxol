defmodule Raxol.Agent.SpendGate do
  @moduledoc """
  U7 — reserve-before-call at the harness primary-loop tool/provider boundary
  (AD-6a). The permanent U7-R red suite
  (`test/raxol/agent/red/u7_spend_gate_red_test.exs`) — authored against this
  seam *before* the implementation existed (the red-first fan-out) — drives
  these functions and is now GREEN.

  ## Deferred (documented follow-ups, post-U11)

    * **`cost_ref` ↔ journal tie.** The gate emits its reserve/call/settle
      records through the injected `context.emit` sink; binding that sink to the
      real durable per-session journal (`family: :meta` records carrying
      `cost_ref`, per `harness-freeze-contracts.md` §2.1) is U7-I wiring, not
      done here.
    * **Budget-side release on settle.** `settle/3` records the authoritative
      `actual`; the refund of `estimate - actual` is *derivable* from the
      `(reserve, settle)` pair. Wiring that release back to the real
      `Raxol.Payments.Ledger.try_spend/5`-shaped budget is U7-I work — the
      frozen `context` exposes only the reserve seam, and the reserve/refund is
      a Gate↔budget-internal step (freeze §"Settlement is internal").

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

  **A real `emit` failure is never swallowed.** The fold is the accounting, so
  a silently dropped record on irreversible spend state (a charged reserve, a
  flipped settle guard) would be exactly the silent charge/record divergence
  this gate exists to prevent. A raising sink propagates as
  `Raxol.Agent.SpendGate.JournalWriteError`, carrying the record so the budget
  owner can reconcile (refund the estimate, halt the run). The only tolerated
  failure is an ephemeral `:noproc` exit — a dead in-memory test bus (the U12
  `safe_emit` narrowing).

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

  alias Raxol.Agent.SpendGate.JournalWriteError
  alias Raxol.Agent.SpendGate.Reservations

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
          required(:try_reserve) => (non_neg_integer() ->
                                       {:ok, non_neg_integer()} | {:error, :over_limit}),
          optional(atom()) => term()
        }

  @typedoc "Opaque correlation id tying one reserve to its call and its settle."
  @type cost_ref :: String.t()

  @typedoc "Token estimate reserved BEFORE a spend-bearing call is made."
  @type estimate :: non_neg_integer()

  @typedoc "Actual token cost, known only AFTER the call returns."
  @type actual :: non_neg_integer()

  @typedoc """
  Handle for a reservation held between reserve and settle.

  NODE-LOCAL and NOT serializable: the internal settle-once guard is an
  `:atomics` reference, dead outside the VM that created it. Handing a
  reservation across nodes (swarm) or persisting/replaying it silently voids
  double-settle protection — settle where you reserved. (Cross-node settle is
  out of scope for U7; the harness primary loop is node-local.)
  """
  @type reservation :: %{cost_ref: cost_ref(), estimate: estimate()}

  @typedoc "Why a reserve was refused (fail-closed)."
  @type refusal ::
          :over_run_cap
          | :over_session_cap
          | :over_limit
          | :invalid_amount
          | :duplicate_reserve
          | atom()

  @doc """
  Atomically reserve `estimate` tokens for the spend-bearing call `cost_ref`,
  against the caps behind `context.try_reserve` (the frozen `try_spend` shape).
  On success, journals a `reserve` record and returns `{:ok, reservation}`.

  Fail-closed refusals — the caller MUST NOT make the call:

    * a non-positive / non-integer (non-finite) `estimate` ⇒
      `{:error, {:refused, :invalid_amount}}` (journals `reserve_refused`, never
      touches the budget);
    * a live (unsettled) reservation already exists for `cost_ref` ⇒
      `{:error, {:refused, :duplicate_reserve}}` (reserve-once — journals
      NOTHING, never touches the budget: no second reserve record);
    * `context.try_reserve` rejects the amount ⇒
      `{:error, {:refused, reason}}` (releases the claim taken for `cost_ref`
      and journals `reserve_refused` with `reason`).
  """
  @callback reserve(context :: context(), cost_ref(), estimate()) ::
              {:ok, reservation()} | {:error, {:refused, refusal()}}

  @doc """
  Settle a reservation with the `actual` cost once the call returned. Journals a
  `settle` record; the refund of `estimate - actual` is derivable from the
  `(reserve, settle)` pair, so the `settle` record is authoritative. Settling
  the same reservation token twice is rejected (a replay would double-refund and
  inflate the budget): the first settle wins and returns `:ok`, the replay
  journals nothing and returns `{:error, {:already_settled, cost_ref()}}`.
  """
  @callback settle(context :: context(), reservation(), actual()) ::
              :ok | {:error, {:already_settled, cost_ref()}}

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

  # --- implementation (U7 / AD-6a) ------------------------------------------

  @doc """
  Reserve `estimate` for `cost_ref`. See the `reserve/3` callback for the
  success and fail-closed refusal contract.

  Raises `Raxol.Agent.SpendGate.JournalWriteError` when the budget was charged
  but the `:reserve` record could not be written (real journal failure, not a
  dead test bus): the claim is released (`cost_ref` retryable) and the error
  carries the record so the budget owner can reconcile the charge. It is never
  swallowed into `{:ok, reservation}` — charge and record must not silently
  diverge.
  """
  @spec reserve(context(), cost_ref(), estimate()) ::
          {:ok, reservation()} | {:error, {:refused, refusal()}}
  def reserve(context, cost_ref, estimate) do
    Reservations.ensure_started()

    if valid_amount?(estimate) do
      reserve_valid(context, cost_ref, estimate)
    else
      # Non-positive / non-finite estimate — fail closed BEFORE any budget or
      # claim mutation. Mirrors the payments Ledger's non-positive/non-finite
      # guard (`Raxol.Payments.Ledger` check_amount_positive).
      guarded_emit(context, %{kind: :reserve_refused, cost_ref: cost_ref, reason: :invalid_amount})

      {:error, {:refused, :invalid_amount}}
    end
  end

  defp reserve_valid(context, cost_ref, estimate) do
    scope = reserve_scope(context)

    case Reservations.claim(scope, cost_ref) do
      {:error, :duplicate} ->
        # A live reservation for this cost_ref already exists (reserve-once).
        # Refuse without a second reserve record and without touching the budget.
        {:error, {:refused, :duplicate_reserve}}

      :ok ->
        reserve_against_budget(context, cost_ref, estimate, scope)
    end
  end

  defp reserve_against_budget(context, cost_ref, estimate, scope) do
    # The FROZEN reserve seam — the same closure the caller composed over the
    # run/session budget, atomic under concurrency (`Ledger.try_spend` shape).
    #
    # Exception-safety (money-critical): if `context.try_reserve` RAISES (vs
    # returns `{:error, _}`), the ETS claim taken in `reserve_valid/3` would leak
    # and permanently wedge `cost_ref`. `safe_try_reserve/4` releases the claim
    # on any raise, then re-raises — so a raising budget seam leaves `cost_ref`
    # retryable, never stuck.
    case safe_try_reserve(context, cost_ref, estimate, scope) do
      {:ok, _remaining} ->
        # The budget is now CHARGED, and the journal fold IS the accounting —
        # so the charge and the `:reserve` record must not diverge. The frozen
        # context has no un-reserve seam, so a failed record write CANNOT roll
        # the charge back here. What it MUST NOT do is get swallowed into a
        # normal `{:ok, reservation}` (a charged-but-unrecorded reserve,
        # invisible to any ledger-vs-journal reconciliation). So the write goes
        # through `emit_or_release/4`: a REAL journal failure releases the
        # claim (`cost_ref` stays retryable, same contour as a raising
        # `call_fun`) and propagates a `JournalWriteError` carrying the record
        # — the caller owns the budget seam and can reconcile (refund the
        # estimate, halt the run). Only an ephemeral `:noproc` (dead test bus)
        # is tolerated; then the handle below is returned settle-able as usual.
        emit_or_release(
          context,
          %{kind: :reserve, cost_ref: cost_ref, estimate: estimate},
          scope,
          cost_ref
        )

        {:ok,
         %{
           cost_ref: cost_ref,
           estimate: estimate,
           scope: scope,
           settle_guard: :atomics.new(1, [])
         }}

      {:error, reason} ->
        # Budget refused: release the claim we took (fail-closed — no call will
        # happen) and journal a typed refusal.
        Reservations.release(scope, cost_ref)
        guarded_emit(context, %{kind: :reserve_refused, cost_ref: cost_ref, reason: reason})
        {:error, {:refused, reason}}
    end
  end

  # Invoke the frozen `try_reserve` seam, releasing the ETS claim taken for
  # `cost_ref` if the seam RAISES (or throws/exits), then re-raising so the
  # caller still sees the failure. A `{:error, _}` return is NOT a raise and
  # flows through untouched (the caller releases the claim on the refusal path).
  defp safe_try_reserve(context, cost_ref, estimate, scope) do
    context.try_reserve.(estimate)
  rescue
    error ->
      Reservations.release(scope, cost_ref)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      Reservations.release(scope, cost_ref)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  @doc """
  Settle a reservation with its `actual`. See the `settle/3` callback contract
  (double-settle is rejected).

  Raises `Raxol.Agent.SpendGate.JournalWriteError` when the `:settle` record
  could not be written for real: settle accounting is already COMPLETE by then
  (the once-guard stays flipped — a replay is still rejected — and the claim is
  released), but the missing record must surface rather than be swallowed into
  `:ok`; the fold conservatively shows the reserve dangling until reconciled.
  """
  @spec settle(context(), reservation(), actual()) ::
          :ok | {:error, {:already_settled, cost_ref()}}
  def settle(context, reservation, actual) do
    %{scope: scope, cost_ref: cost_ref, settle_guard: guard} = reservation
    Reservations.ensure_started()

    # Atomic settle-once: flip 0 -> 1. `:atomics.compare_exchange/4` returns
    # `:ok` when it matched (first settle) or the current value (already 1) on a
    # replay — so two concurrent settles of one token can never both win.
    case :atomics.compare_exchange(guard, 1, 0, 1) do
      :ok ->
        # First settle: release the active claim and journal the authoritative
        # `actual`. Budget-side refund of `estimate - actual` is a deferred
        # follow-up (see moduledoc) — derivable from the (reserve, settle) pair.
        #
        # The CAS flip above is IRREVERSIBLE — settle can never retry, and by
        # the time we emit, the claim is already released: settle accounting IS
        # complete regardless of what the journal write does. But the fold is
        # the accounting, so a REAL write failure must not be swallowed into a
        # normal `:ok` (the `actual` would be recorded nowhere): `guarded_emit`
        # propagates it as a `JournalWriteError` carrying the settle record.
        # The guard stays flipped (a replay is still rejected — never a
        # re-runnable settle) and the fold conservatively shows the reserve as
        # dangling (over-counts, fail-closed) until the caller reconciles.
        # Only an ephemeral `:noproc` (dead test bus) is tolerated as `:ok`.
        Reservations.release(scope, cost_ref)
        guarded_emit(context, %{kind: :settle, cost_ref: cost_ref, actual: actual})
        :ok

      _already_settled ->
        # Replayed reservation token: reject, journal nothing (a second settle
        # would double-refund / inflate the budget).
        {:error, {:already_settled, cost_ref}}
    end
  end

  @doc """
  Reserve-before-call combinator. See the `around/4` callback contract. On a
  successful reserve, invokes `call_fun` (which reports `{actual, result}`),
  journals the `call`, settles, and returns `{:ok, result}`. On a refused
  reserve, `call_fun` is NEVER invoked and it returns
  `{:error, {:reserve_refused, reason}}`.
  """
  @spec around(context(), cost_ref(), estimate(), (-> {actual(), term()})) ::
          {:ok, term()} | {:error, {:reserve_refused, refusal()}}
  def around(context, cost_ref, estimate, call_fun) do
    case reserve(context, cost_ref, estimate) do
      {:ok, reservation} ->
        # If `call_fun` RAISES, the reservation's ETS claim would leak and wedge
        # `cost_ref`. Release it on any raise (so `cost_ref` is reclaimable) then
        # re-raise — the caller sees the failure, the registry is not poisoned.
        {actual, result} = safe_call(reservation, call_fun)
        # The :call write follows the same law: a REAL journal failure releases
        # the claim (`cost_ref` reclaimable; the reserve shows dangling in the
        # fold — the crash contour's shape) and propagates `JournalWriteError`;
        # only a dead test bus (`:noproc`) is tolerated.
        emit_or_release(context, %{kind: :call, cost_ref: cost_ref}, reservation.scope, cost_ref)
        settle(context, reservation, actual)
        {:ok, result}

      {:error, {:refused, reason}} ->
        {:error, {:reserve_refused, reason}}
    end
  end

  # Run the spend-bearing `call_fun`, releasing the reservation's claim if it
  # raises/throws/exits, then re-raising. Releasing (not settling) keeps
  # `cost_ref` reclaimable; the un-settled reserve stays visible in the fold as
  # the crash-between-reserve-and-call contour requires.
  defp safe_call(%{scope: scope, cost_ref: cost_ref}, call_fun) do
    call_fun.()
  rescue
    error ->
      Reservations.release(scope, cost_ref)
      reraise error, __STACKTRACE__
  catch
    kind, reason ->
      Reservations.release(scope, cost_ref)
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # --- internals ------------------------------------------------------------

  # Journal a record through `context.emit` — in production, durable I/O (a
  # per-session journal write) that CAN fail. The journal fold IS the
  # accounting, so a dropped write is silent divergence between the charged
  # budget and the recorded truth — the exact loss the gate promises to
  # prevent. A REAL failure therefore PROPAGATES as a distinguishable
  # `JournalWriteError` carrying the record (the budget owner reconciles); it
  # is never swallowed into `:ok`.
  #
  # The ONLY tolerated failure is an ephemeral `:noproc` exit — a dead
  # in-memory test bus, where no durable journal existed to diverge from. This
  # is the same narrowing U12 applies in its `safe_emit`.
  defp guarded_emit(context, record) do
    context.emit.(record)
    :ok
  rescue
    error ->
      reraise JournalWriteError,
              [record: record, original: error],
              __STACKTRACE__
  catch
    :exit, reason when reason == :noproc or (is_tuple(reason) and elem(reason, 0) == :noproc) ->
      :ok

    kind, reason ->
      :erlang.raise(
        :error,
        JournalWriteError.exception(record: record, original: {kind, reason}),
        __STACKTRACE__
      )
  end

  # `guarded_emit/2` for the two sites that still HOLD the reservation claim
  # when they journal (the `:reserve` and `:call` writes): on a real journal
  # failure, release the claim first — `cost_ref` stays retryable, the same
  # contour as a raising `call_fun` — then let the `JournalWriteError`
  # propagate.
  defp emit_or_release(context, record, scope, cost_ref) do
    guarded_emit(context, record)
  rescue
    error in JournalWriteError ->
      Reservations.release(scope, cost_ref)
      reraise error, __STACKTRACE__
  end

  # The reservation namespace (dedup scope). Keying on the `try_reserve` CLOSURE
  # TERM is caller-fragile (finding #4): a caller that rebuilds the closure per
  # call — or composes run+session caps into a fresh closure each time — gets a
  # DIFFERENT term for the SAME budget, fragmenting the namespace so one cost_ref
  # can reserve twice; conversely two distinct budgets whose closures happen to
  # compare `=:=` would collide into a false `duplicate_reserve`.
  #
  # So we key on an explicit STABLE budget identity when the caller supplies one,
  # in preference order: `:budget_id` -> `:scope` -> a raw `:budget` handle. Each
  # is tagged so values from different fields can never alias. Only when NONE is
  # present do we fall back to the closure term (documented requirement below).
  #
  # NOTE (follow-up): the frozen SpendGate `context` shape (§ AD-6a) freezes only
  # `:emit` and `:try_reserve` — it has no stable budget-identity field yet.
  # U7-I callers SHOULD pass a stable `:budget_id` (one per run/session budget);
  # promoting `:budget_id` into the frozen context shape is the clean fix and is
  # tracked as a follow-up. Until then the closure-term fallback holds only for
  # callers that reuse ONE `try_reserve` closure per budget.
  defp reserve_scope(context) do
    cond do
      Map.has_key?(context, :budget_id) -> {:budget_id, context.budget_id}
      Map.has_key?(context, :scope) -> {:scope, context.scope}
      Map.has_key?(context, :budget) -> {:budget, context.budget}
      true -> {:try_reserve, context.try_reserve}
    end
  end

  # A valid token estimate is a positive integer. Rejects 0, negatives, floats,
  # and non-numbers (non-finite) — fail-closed, mirroring the payments Ledger.
  defp valid_amount?(estimate) when is_integer(estimate) and estimate > 0, do: true
  defp valid_amount?(_estimate), do: false
end
