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

  alias Raxol.Agent.Meta

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

  # The synthetic root offset the taint fold hangs the call's `arg_refs` under
  # before handing the translated lineage to `Meta.derive_taint/1`. A string so
  # it can never collide with an integer journal offset in the lineage.
  @taint_root "__u8_taint_root__"

  @behaviour __MODULE__

  @doc "A fresh, empty gate state: no pending requests, no grants, no denies."
  @spec new() :: state()
  def new,
    do: %{
      pending: %{},
      once: MapSet.new(),
      session: MapSet.new(),
      denied: MapSet.new()
    }

  @doc """
  The pure §5.2 auto-approve predicate: escalate iff
  `effect_class == :irreversible_external` OR `egress == true`.

  Reads STRUCTURAL fields only. A self-reported `destructive_hint` is never
  consulted — an irreversible call claiming `destructive_hint: false` still
  escalates (the `destructiveHint`-is-a-lie class, N-Y5).
  """
  @impl true
  @spec escalate?(call()) :: boolean()
  def escalate?(call),
    do: call.effect_class == :irreversible_external or call.egress == true

  @doc """
  The taint FOLD (HIGH-1 / §0 clause 7 decision-time law): derive the call's
  lineage trust by folding the U11 tainted-absorbing algebra over the `arg_refs`
  closure **at decision time**, via `Raxol.Agent.Meta.derive_taint/1` — the single
  source of truth for the taint algebra.

  Never a stamped-field read: the call's argument lineage is translated into
  journal-shaped records and folded, so a `:trusted`-STAMPED argument whose ref
  chain reaches a tainted record folds `:tainted` (mis-stamp, N-U11.3 class). An
  unresolvable ref folds as `:tainted` (fail-closed, §2.1 unknown-trust) — a
  guard the gate adds around the fold, since a dangling ref is untrusted.
  """
  @impl true
  @spec tainted_lineage?(call()) :: boolean()
  def tainted_lineage?(call) do
    arg_refs = Map.get(call, :arg_refs, [])
    lineage = Map.get(call, :lineage, %{})

    cond do
      # Fail closed: any ref reachable from arg_refs that does not resolve in the
      # declared lineage is untrusted (§2.1 unknown-trust). Meta.derive_taint
      # treats a missing ref as non-tainted, so the gate guards this itself.
      unresolved_closure?(arg_refs, lineage, MapSet.new()) ->
        true

      true ->
        records = lineage_records(lineage) ++ [taint_root_record(arg_refs)]
        Map.get(Meta.derive_taint(records), @taint_root) == :tainted
    end
  end

  # Walk the ref closure purely to detect a dangling (unresolvable) ref; the
  # trust math is Meta's job. A `:tainted`-stamped entry short-circuits (it is a
  # resolved taint source, refs not followed — tainted is absorbing).
  defp unresolved_closure?([], _lineage, _seen), do: false

  defp unresolved_closure?([id | rest], lineage, seen) do
    cond do
      MapSet.member?(seen, id) ->
        unresolved_closure?(rest, lineage, seen)

      true ->
        case Map.get(lineage, id) do
          nil -> true
          %{trust: :tainted} -> unresolved_closure?(rest, lineage, MapSet.put(seen, id))
          %{refs: refs} -> unresolved_closure?(refs ++ rest, lineage, MapSet.put(seen, id))
          _ -> true
        end
    end
  end

  # Translate one call's argument lineage into journal-shaped records the U11
  # taint algebra folds. Taint enters at leaves: a `:tainted`-stamped entry is a
  # taint-source leaf (refs irrelevant — absorbing short-circuit); a `:trusted`
  # leaf (no refs) anchors trusted; any entry WITH refs is a derived (meta)
  # record whose trust folds from its refs, so a mis-stamped `:trusted` node over
  # a tainted chain still folds tainted.
  defp lineage_records(lineage) do
    for {id, entry} <- lineage do
      cond do
        Map.get(entry, :trust) == :tainted ->
          %{"id" => id, "family" => "loop", "provenance" => %{"trust" => "tainted"}}

        Map.get(entry, :refs, []) == [] ->
          %{
            "id" => id,
            "family" => "loop",
            "provenance" => %{"trust" => trust_string(Map.get(entry, :trust))}
          }

        true ->
          %{"id" => id, "family" => "meta", "payload" => %{"refs" => entry.refs}}
      end
    end
  end

  defp taint_root_record(arg_refs),
    do: %{"id" => @taint_root, "family" => "meta", "payload" => %{"refs" => arg_refs}}

  defp trust_string(:trusted), do: "trusted"
  defp trust_string(:tainted), do: "tainted"
  # Any other stamp is handed to Meta verbatim, which fails it closed (:tainted).
  defp trust_string(other), do: to_string(other)

  @doc """
  Decide a gated call against the gate `state`, without running any side effect.

  Order is load-bearing (the YOLO-safe soundness ladder):

    1. an `:once` grant for exactly this `call_id` → `{:proceed, _}` (a completed
       approval cycle covers precisely this request; the grant is consumed);
    2. a durable deny for this `call_id` → `{:reject, :denied, _}` (deny survives
       a bare retry — AD-14);
    3. a tainted lineage (decision-time fold) → `{:escalate, _, _}` REGARDLESS of
       class/egress or any standing session grant (FI-5: the untrusted leg is a
       distinct confirmation);
    4. a standing `:session`/`:root` grant for the tool → `{:proceed, _}`;
    5. the §5.2 escalation predicate (irreversible_external OR egress) →
       `{:escalate, _, _}`;
    6. otherwise → `{:proceed, _}` (YOLO-applicable over trusted lineage).
  """
  @impl true
  @spec evaluate(state(), call()) ::
          {:proceed, state()}
          | {:escalate, request(), state()}
          | {:reject, term(), state()}
  def evaluate(state, call) do
    cid = call.call_id
    tool = call.tool

    cond do
      MapSet.member?(state.once, cid) ->
        {:proceed, %{state | once: MapSet.delete(state.once, cid)}}

      MapSet.member?(state.denied, cid) ->
        {:reject, :denied, state}

      tainted_lineage?(call) ->
        escalate(state, call)

      MapSet.member?(state.session, tool) ->
        {:proceed, state}

      escalate?(call) ->
        escalate(state, call)

      true ->
        {:proceed, state}
    end
  end

  # Register a pending approval and emit the `approval_requested` neutral event
  # (family :loop — frozen F3, so a resumed conversation lands on the pending
  # approval; the freeze tip predicate §1.1). The side effect does NOT run.
  defp escalate(state, call) do
    ref = request_ref(call)

    request = %{
      family: :loop,
      type: :approval_requested,
      payload: %{
        request_ref: ref,
        call_id: call.call_id,
        action: call.tool,
        effect_class: call.effect_class,
        egress: call.egress,
        blast_radius: %{effect_class: call.effect_class, egress: call.egress}
      }
    }

    pending = Map.put(state.pending, ref, %{call_id: call.call_id, tool: call.tool})
    {:escalate, request, %{state | pending: pending}}
  end

  # request_ref encodes tool + call_id so a journaled decision ALONE rebuilds the
  # grant key on replay (the enforcement projection needs no side table).
  defp request_ref(call), do: "req:#{call.tool}:#{call.call_id}"

  defp parse_ref("req:" <> rest) do
    [tool, cid] = String.split(rest, ":", parts: 2)
    {String.to_existing_atom(tool), cid}
  end

  @doc """
  Guard `run_fn` behind the gate: it is invoked **iff** the call proceeds.

  `{:proceeded, result, state}` (ran `run_fn`), `{:escalated, request, state}`
  (did NOT run), `{:rejected, reason, state}` (did NOT run). The locked-by-default
  seam: a write tool with no covering approval never reaches `run_fn`.
  """
  @impl true
  @spec authorize(state(), call(), (-> term())) ::
          {:proceeded, term(), state()}
          | {:escalated, request(), state()}
          | {:rejected, term(), state()}
  def authorize(state, call, run_fn) do
    case evaluate(state, call) do
      {:proceed, st} -> {:proceeded, run_fn.(), st}
      {:escalate, request, st} -> {:escalated, request, st}
      {:reject, reason, st} -> {:rejected, reason, st}
    end
  end

  @doc """
  Fold one OBSERVED `approval_decided` event into the live approval state.

  `decision.request_ref` MUST name a live pending request; a forged/dangling
  decision is `{:error, :no_such_request}` — a decision with no request is not a
  fact the gate may enact. A `:denied` decision is durable (records the deny so a
  bare retry can't succeed). `actor` comes from the envelope (unused for the
  enforcement projection — recorded upstream on the journal envelope, §2.1).
  """
  @impl true
  @spec apply_decision(state(), decision(), actor()) ::
          {:ok, state()} | {:error, term()}
  def apply_decision(state, %{request_ref: ref} = decision, _actor) do
    case Map.fetch(state.pending, ref) do
      :error ->
        {:error, :no_such_request}

      {:ok, %{call_id: cid, tool: tool}} ->
        state = %{state | pending: Map.delete(state.pending, ref)}
        scope = Map.get(decision, :scope, :once)
        {:ok, grant(state, decision.decision, scope, cid, tool)}
    end
  end

  @doc """
  Rebuild live approval state by folding `approval_decided` events in order (the
  §2.1 replay/resume law): the journal is the authority, so the enforcement
  projection is re-derived from the decisions alone (`request_ref` encodes the
  grant key). Each decision was request-validated when first observed.
  """
  @impl true
  @spec rebuild([{decision(), actor()}]) :: state()
  def rebuild(events) do
    Enum.reduce(events, new(), fn {decision, _actor}, state ->
      {tool, cid} = parse_ref(decision.request_ref)
      scope = Map.get(decision, :scope, :once)
      grant(state, decision.decision, scope, cid, tool)
    end)
  end

  # Fold one decision into the enforcement projection at its scope. A grant also
  # clears any prior deny for the call_id (a fresh approval cycle supersedes it);
  # a deny records the call_id durably and drops any stale :once grant.
  defp grant(state, :approved, :once, cid, _tool),
    do: %{
      state
      | denied: MapSet.delete(state.denied, cid),
        once: MapSet.put(state.once, cid)
    }

  defp grant(state, :approved, scope, cid, tool) when scope in [:session, :root],
    do: %{
      state
      | denied: MapSet.delete(state.denied, cid),
        session: MapSet.put(state.session, tool)
    }

  defp grant(state, :denied, _scope, cid, _tool),
    do: %{
      state
      | denied: MapSet.put(state.denied, cid),
        once: MapSet.delete(state.once, cid)
    }
end
