defmodule Raxol.Agent.Authorization.BlastRadiusGate do
  @moduledoc """
  U8 — the blast-radius gate: write/destructive tools are **LOCKED by default**;
  unlocking requires an approval flow (AD-6b / AD-14).

  **SKELETON ONLY.** This module is the enabler for the permanent U8-R red suite
  (`test/raxol/agent/red/u8_blast_radius_red_test.exs`), authored *before*
  implementation per the red-first fan-out against the harness freeze contracts
  (`docs/proposals/in-flight/harness-freeze-contracts.md`). Every public function
  here raises `:not_implemented` — the red contours run against this skeleton and
  MUST fail until U8 lands, at which point they turn green in place. The suite's
  reference gate (test support) is the executable spec these callbacks must match.

  ## The contract this gate enforces

  A write/destructive tool call is gated. `authorize/3` evaluates the call
  (`effect_class` + `egress` + taint, §5.2 + FI-5) and either:

    * **proceeds** — a standing approval covers the call, or the call is
      auto-approvable (non-escalating class over trusted lineage); the guarded
      side effect runs;
    * **escalates** — the call requires a human decision; an `approval_requested`
      neutral event (`family: :loop`, so a resumed conversation lands on the
      pending approval — the freeze's tip predicate, §1.1) is returned and the
      side effect does NOT run;
    * **rejects** — the call is denied (a durable prior deny with no new approval
      cycle, or a hard reject); the side effect does NOT run.

  A decision arrives as an `approval_decided` meta event
  (`%{request_ref, decision, refs}`, `decision ∈ :approved | :denied`); the actor
  lives on the **envelope only**, never the payload (§2.1 uniform-actor). Live
  approval state is a **projection**: it MUST be rebuildable by a fold over
  `approval_decided` events (`rebuild/1`) so a resumed/replayed session
  reconstructs identical enforcement state — the journal is the authority.

  ## The auto-approve predicate (§5.2, inlined normative)

  A call **escalates** (requires human approval) iff
  `effect_class == :irreversible_external` **OR** `egress == true`. This predicate
  reads STRUCTURAL, compiled-in-our-tree fields — never an untrusted tool's
  self-reported `destructive_hint` (the `destructiveHint`-is-a-lie class, N-Y5).
  Tainted lineage escalates regardless (FI-5): taint (untrusted leg) + any
  effectful action still takes the confirmation path.

  ## Taint is FOLDED over refs, never field-read (HIGH-1)

  The gate's trust decision derives lineage taint by folding the U11 algebra
  (tainted-absorbing, no laundering) over the call's arg-lineage `refs` closure
  **at decision time** — it NEVER trusts the stamped `provenance.trust` field of
  the direct argument event alone. A `:trusted`-stamped event whose ref chain
  reaches a tainted record IS tainted (a mis-stamp, N-U11.3 class, must not fool
  the gate); an unknown/unresolvable ref folds as `:tainted` (fail-closed,
  U11 §2.1 unknown-trust rule).

  ## Scopes

  `:once | :session | :root` (mirrors `Raxol.Agent.Authorization.Policy` scope):
  a decision's scope decides how long an approval is remembered.
  """

  @typedoc "Action reversibility class (F2 `Raxol.Action` substrate, §5.2)."
  @type effect_class ::
          :reversible_local | :bounded_sandboxable | :irreversible_external

  @typedoc "Stamped trust of one lineage record (U11 provenance; advisory input to the fold)."
  @type trust :: :trusted | :tainted

  @typedoc "Approval memory scope (mirrors Authorization.Policy)."
  @type scope :: :once | :session | :root

  @typedoc """
  One record in a call's argument lineage: its STAMPED `provenance.trust` and the
  `refs` (ids of the records it derives from). The stamp alone is never the trust
  decision — the gate folds the tainted-absorbing algebra over the closure.
  """
  @type lineage_record :: %{
          required(:trust) => trust(),
          required(:refs) => [non_neg_integer()],
          optional(any()) => any()
        }

  @typedoc """
  A gated tool call. `effect_class`/`egress` are the structural §5.2 substrate;
  `arg_refs`/`lineage` carry the argument derivation graph the taint fold walks;
  `scope` is the memory the caller requests.
  """
  @type call :: %{
          required(:call_id) => String.t(),
          required(:tool) => atom() | String.t(),
          required(:effect_class) => effect_class(),
          required(:egress) => boolean(),
          optional(:arg_refs) => [non_neg_integer()],
          optional(:lineage) => %{non_neg_integer() => lineage_record()},
          optional(:scope) => scope(),
          optional(any()) => any()
        }

  @typedoc "Opaque gate state (pending requests, standing approvals, durable denies)."
  @type state :: term()

  @typedoc "The `approval_requested` neutral event a gate returns when it escalates."
  @type request :: %{
          required(:family) => :loop,
          required(:type) => :approval_requested,
          required(:payload) => map(),
          optional(any()) => any()
        }

  @typedoc "An `approval_decided` decision (payload of the meta event); actor is envelope-side."
  @type decision :: %{
          required(:request_ref) => String.t(),
          required(:decision) => :approved | :denied,
          required(:refs) => [non_neg_integer()],
          optional(:scope) => scope(),
          optional(any()) => any()
        }

  @typedoc "The envelope-side actor of an `approval_decided` event (§2.1)."
  @type actor :: %{
          required(:kind) => :human | :agent | :system,
          required(:id) => String.t()
        }

  @doc """
  The pure §5.2 auto-approve predicate: escalate iff
  `effect_class == :irreversible_external` OR `egress == true`.

  Reads structural fields only — never a self-reported destructiveHint.
  """
  @callback escalate?(call()) :: boolean()

  @doc """
  The taint FOLD (HIGH-1): derive the call's lineage trust by folding the U11
  tainted-absorbing algebra over the `arg_refs` closure through `lineage`.

  MUST NOT read only the direct argument's stamped `trust` — a `:trusted`-stamped
  record whose ref chain reaches a tainted record is tainted. An unresolvable ref
  folds as tainted (fail-closed). A tainted lineage escalates regardless of
  `escalate?/1` (FI-5).
  """
  @callback tainted_lineage?(call()) :: boolean()

  @doc """
  Decide a gated call against the gate `state`, without running any side effect.

  Returns `{:proceed, state}` (a standing approval covers it, or it auto-approves),
  `{:escalate, request, state}` (register a pending approval; emit
  `approval_requested`), or `{:reject, reason, state}` (durable prior deny / hard
  reject).
  """
  @callback evaluate(state(), call()) ::
              {:proceed, state()}
              | {:escalate, request(), state()}
              | {:reject, reason :: term(), state()}

  @doc """
  Guard `run_fn` behind the gate: it is invoked **iff** the call proceeds.

  `{:proceeded, result, state}` (ran `run_fn`), `{:escalated, request, state}`
  (did NOT run), `{:rejected, reason, state}` (did NOT run). This is the
  locked-by-default seam: a write tool with no covering approval never reaches
  `run_fn`.
  """
  @callback authorize(state(), call(), run_fn :: (-> term())) ::
              {:proceeded, term(), state()}
              | {:escalated, request(), state()}
              | {:rejected, reason :: term(), state()}

  @doc """
  Fold one OBSERVED `approval_decided` event into the live approval state.

  The `decision.request_ref` MUST name a live pending request; a forged/dangling
  decision (no matching request) is rejected `{:error, reason}` — a decision with
  no request is not a fact the gate may enact. `actor` comes from the envelope. A
  `:denied` decision is **durable**: after it, the same request may not be retried
  into success without a NEW approval cycle.
  """
  @callback apply_decision(state(), decision(), actor()) ::
              {:ok, state()} | {:error, reason :: term()}

  @doc """
  Rebuild live approval state by folding `approval_decided` events in order (the
  replay/resume law, §2.1): the reconstructed state MUST equal the live state that
  produced the same event sequence. In-memory-only enforcement state that a fold
  cannot reconstruct is a contract violation.
  """
  @callback rebuild([{decision(), actor()}]) :: state()

  @not_impl "Raxol.Agent.Authorization.BlastRadiusGate is a U8-R red-suite skeleton (:not_implemented)"

  @doc "Skeleton — see `c:escalate?/1`. Raises until U8 lands."
  @spec escalate?(call()) :: no_return()
  def escalate?(_call), do: raise(@not_impl)

  @doc "Skeleton — see `c:tainted_lineage?/1`. Raises until U8 lands."
  @spec tainted_lineage?(call()) :: no_return()
  def tainted_lineage?(_call), do: raise(@not_impl)

  @doc "Skeleton — see `c:evaluate/2`. Raises until U8 lands."
  @spec evaluate(state(), call()) :: no_return()
  def evaluate(_state, _call), do: raise(@not_impl)

  @doc "Skeleton — see `c:authorize/3`. Raises until U8 lands."
  @spec authorize(state(), call(), (-> term())) :: no_return()
  def authorize(_state, _call, _run_fn), do: raise(@not_impl)

  @doc "Skeleton — see `c:apply_decision/3`. Raises until U8 lands."
  @spec apply_decision(state(), decision(), actor()) :: no_return()
  def apply_decision(_state, _decision, _actor), do: raise(@not_impl)

  @doc "Skeleton — see `c:rebuild/1`. Raises until U8 lands."
  @spec rebuild([{decision(), actor()}]) :: no_return()
  def rebuild(_events), do: raise(@not_impl)

  @doc "A fresh, empty gate state (skeleton — raises until U8 lands)."
  @spec new() :: no_return()
  def new, do: raise(@not_impl)
end
