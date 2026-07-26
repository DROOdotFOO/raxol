defmodule Raxol.Agent.Authorization.BlastRadiusGate do
  @moduledoc """
  U8 — the blast-radius gate: write/destructive tools are **LOCKED by default**;
  unlocking requires an approval flow (AD-6b / AD-14).

  **SKELETON ONLY.** This module is the enabler for the permanent U8-R red suite
  (`test/raxol/agent/red/u8_blast_radius_red_test.exs`), authored *before*
  implementation per the red-first fan-out against the harness safety substrate
  (see `docs/harness/architecture.md`, "The safety substrate"). Every public
  function here raises `:not_implemented` — the red contours run against this
  skeleton and MUST fail until U8 lands, at which point they turn green in
  place. The suite's reference gate (test support) is the executable spec
  these callbacks must match.

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

  ## The approver is authenticated by the gate (fail-closed)

  The gate's reason to exist is "a destructive call requires a **human**
  decision", so the gate itself enforces it: `apply_decision/3` and the
  `rebuild/1` fold ENACT a decision **only** when the envelope actor is
  `%{kind: :human}`. A decision authored by an `:agent`, `:system`, a `nil`/
  absent actor (absent = system emission, §2.1 frozen fold rule), or a
  malformed actor is NOT a grant — live it is `{:error, {:unauthorized_actor,
  kind}}` (the request stays pending, awaiting the human), and on rebuild it
  folds as a no-op. This closes the self-approval hole: an agent that can emit
  `approval_decided` events naming its own live `request_ref` still cannot
  unlock its own escalated write. The trust boundary is thus IN the gate, not
  deferred to journal-producer discipline.

  ## One request identity everywhere

  A single injective key — the `request_ref`, encoding
  `{tool, call_id, lineage_digest}` — is the identity for pending requests,
  `:once` grants, AND durable denies (no bare-`call_id` side keys). So:

    * a `:once` grant unlocks exactly the approved request — a different tool
      sharing the `call_id`, or the same `(tool, call_id)` re-issued with
      DIFFERENT argument lineage (the digest differs), does not match and falls
      through to the taint fold / escalation (AD-14 "unlocks exactly that
      request");
    * a deny is durable **per request** (AD-14: "the *same request* may not be
      retried into success without a NEW approval cycle") — it never
      blanket-blocks an unrelated tool that happens to share a `call_id`.

  ## Deployment status (declared deferrals)

    * **Not yet wired**: no tool-dispatch path routes through `authorize/3` in
      this unit — "locked by default" describes the gate's contract, not yet a
      live control. Wiring the dispatch seam is a follow-up unit.
    * **State growth**: `pending`/`once`/`session`/`denied` are bounded only by
      session lifetime (undecided escalations and denies accumulate). A
      TTL/cap policy is a follow-up GC concern; sizes are O(decisions).

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

  @typedoc """
  A journaled `:once`-grant CONSUMPTION marker: the guarded action for
  `consumed_ref` ran, spending the one-shot grant. Folded by `rebuild/1` so a
  resumed session reproduces the POST-consumption state (a spent grant is not
  resurrected). `consumed_ref` is the request_ref the grant was keyed under.
  """
  @type consumption :: %{
          required(:consumed_ref) => String.t(),
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
  no request is not a fact the gate may enact. `actor` comes from the envelope
  and is AUTHENTICATED: only a `%{kind: :human}` actor's decision is enacted —
  any other actor (agent/system/nil/malformed) is rejected fail-closed, the
  request left pending. A `:denied` decision is **durable**: after it, the same
  request may not be retried into success without a NEW approval cycle.
  """
  @callback apply_decision(state(), decision(), actor()) ::
              {:ok, state()} | {:error, reason :: term()}

  @doc """
  Rebuild live approval state by folding `approval_decided` events in order (the
  replay/resume law, §2.1): the reconstructed state MUST equal the live state that
  produced the same event sequence. In-memory-only enforcement state that a fold
  cannot reconstruct is a contract violation.

  The journal also carries `:once`-grant CONSUMPTION markers (`%{consumed_ref}`):
  folding one reproduces the post-consumption state, so a spent one-shot grant is
  NOT resurrected on resume (a re-issued call must not auto-admit without a new
  approval cycle).

  The fold is reader-tolerant and fail-closed (never a crash, never a grant):
  a non-`:human` actor, an unknown `decision`/`scope` value, an unparseable
  `request_ref`, or a malformed record folds as a NO-OP — a version-skewed or
  partially-corrupt journal degrades to "nothing extra granted", it does not
  prevent the session from reconstructing enforcement state.
  """
  @callback rebuild([{decision() | consumption(), actor()}]) :: state()

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
  def escalate?(call) do
    # Map.get, never dot access: a call map MISSING a "required" structural
    # field must fail CLOSED to escalation on the authorization path, not raise
    # a KeyError out of evaluate/2. `:__missing__` is unrecognized, so both
    # cond arms below treat absence exactly like an unknown value.
    effect_class = Map.get(call, :effect_class, :__missing__)
    egress = Map.get(call, :egress, :__missing__)

    cond do
      effect_class == :irreversible_external -> true
      egress == true -> true
      # Auto-proceed ONLY for a recognized benign class with egress EXACTLY
      # false. An unknown/unrecognized/absent effect_class, or a non-boolean
      # egress, fails CLOSED to escalation (§2.1 unknown-trust doctrine) —
      # never a silent proceed on a field we don't understand.
      known_effect_class?(effect_class) and egress == false -> false
      true -> true
    end
  end

  @known_effect_classes [
    :reversible_local,
    :bounded_sandboxable,
    :irreversible_external
  ]

  defp known_effect_class?(class), do: class in @known_effect_classes

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

    1. an `:once` grant for exactly this request → `{:proceed, _}` (a completed
       approval cycle covers precisely this request; the grant is consumed);
    2. a durable deny for exactly this request → `{:reject, :denied, _}` (deny
       survives a bare retry — AD-14);
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
    # ONE request identity at every site: `:once` grants AND durable denies are
    # keyed by the FULL request_ref — tool + call_id + lineage digest — never a
    # bare call_id (asymmetric keys were the deny-bypass/over-block class). So:
    #   * a grant/deny for (toolA, c1) never touches (toolB, c1);
    #   * a re-issued (tool, c1) whose argument LINEAGE changed produces a
    #     DIFFERENT ref (the digest differs), misses the once branch, and falls
    #     through to the decision-time taint fold below — a standing grant can
    #     never smuggle newly-tainted lineage past the fold.
    # Grant and deny for one ref are mutually exclusive (each write clears the
    # other), so the once-before-deny order carries no hidden precedence.
    ref = request_ref(call)

    cond do
      MapSet.member?(state.once, ref) ->
        {:proceed, %{state | once: MapSet.delete(state.once, ref)}}

      MapSet.member?(state.denied, ref) ->
        {:reject, :denied, state}

      tainted_lineage?(call) ->
        escalate(state, call)

      MapSet.member?(state.session, tool_key(call.tool)) ->
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
    # Map.get: a call escalating BECAUSE a structural field is missing must
    # still produce a well-formed request, not raise while describing itself.
    effect_class = Map.get(call, :effect_class)
    egress = Map.get(call, :egress)

    request = %{
      family: :loop,
      type: :approval_requested,
      payload: %{
        request_ref: ref,
        call_id: call.call_id,
        action: call.tool,
        effect_class: effect_class,
        egress: egress,
        blast_radius: %{effect_class: effect_class, egress: egress}
      }
    }

    pending =
      Map.put(state.pending, ref, %{call_id: call.call_id, tool: tool_key(call.tool)})

    {:escalate, request, %{state | pending: pending}}
  end

  # The ONE canonical tool representation used identically in live-store,
  # request_ref, parse_ref, and rebuild: a string. `call.tool` is `atom() |
  # String.t()`; normalizing to a string means a STRING-named tool stored live
  # equals the tool reconstructed by `parse_ref` on replay (no atom/string
  # skew), and `String.to_existing_atom` — which crashes on an unknown tool — is
  # never reached.
  defp tool_key(tool) when is_atom(tool), do: Atom.to_string(tool)
  defp tool_key(tool) when is_binary(tool), do: tool

  # request_ref is the ONE request identity (pending key, `:once`-grant key,
  # deny key) and encodes tool + call_id + a digest of the argument lineage, so
  # a journaled decision ALONE rebuilds the grant key on replay (the enforcement
  # projection needs no side table).
  #
  # Wire format (documented — the load-bearing link between a journaled decision
  # and the grant key):
  #
  #     "req:" <> byte_size(tool) <> ":" <> tool
  #            <> byte_size(call_id) <> ":" <> call_id <> lineage_digest
  #
  # INJECTIVE and delimiter-safe: tool and call_id are length-prefixed, so a ":"
  # inside either can never mis-split the ref. The digest binds the grant to the
  # request's argument lineage: a re-issued (tool, call_id) with DIFFERENT
  # lineage produces a different ref, so a standing `:once` grant covers exactly
  # the vetted request — never the same ids over newly-tainted arguments. The
  # digest is a non-cryptographic in-session binder (`:erlang.phash2`); if it
  # ever skews across a runtime upgrade the mismatch fails CLOSED (the grant
  # simply doesn't match and the call re-escalates).
  defp request_ref(call),
    do: ref_encode(tool_key(call.tool), call.call_id, lineage_digest(call))

  defp lineage_digest(call) do
    {Map.get(call, :arg_refs, []), Map.get(call, :lineage, %{})}
    |> :erlang.phash2(4_294_967_296)
    |> Integer.to_string()
  end

  defp ref_encode(tool, cid, digest)
       when is_binary(tool) and is_binary(cid) and is_binary(digest) do
    "req:" <>
      Integer.to_string(byte_size(tool)) <>
      ":" <> tool <> Integer.to_string(byte_size(cid)) <> ":" <> cid <> digest
  end

  # Fail-closed parse: a ref that did not originate from `ref_encode/3` (foreign
  # producer, version skew, corruption) returns :error — never a raise on the
  # rebuild path (the fold treats it as no-grant).
  defp parse_ref("req:" <> rest) do
    with [tool_len_str, tail] <- String.split(rest, ":", parts: 2),
         {tool_len, ""} when tool_len >= 0 <- Integer.parse(tool_len_str),
         <<tool::binary-size(^tool_len), tail::binary>> <- tail,
         [cid_len_str, tail] <- String.split(tail, ":", parts: 2),
         {cid_len, ""} when cid_len >= 0 <- Integer.parse(cid_len_str),
         <<cid::binary-size(^cid_len), _digest::binary>> <- tail do
      {:ok, {tool, cid}}
    else
      _ -> :error
    end
  end

  defp parse_ref(_), do: :error

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

  The envelope `actor` is AUTHENTICATED first (fail-closed): only a
  `%{kind: :human}` actor's decision is enacted. Any other actor — `:agent`,
  `:system`, `nil`/absent (absent = system, §2.1), or malformed — returns
  `{:error, {:unauthorized_actor, kind}}` and leaves the state (including the
  pending request) untouched, so an agent can never self-approve its own
  escalated write and the request keeps awaiting its human.

  `decision.request_ref` MUST name a live pending request; a forged/dangling
  decision is `{:error, :no_such_request}` — a decision with no request is not a
  fact the gate may enact. An out-of-domain `decision`/`scope` value is
  `{:error, _}` — never a crash, never a grant. A `:denied` decision is durable
  (records the deny so a bare retry can't succeed).
  """
  @impl true
  @spec apply_decision(state(), decision(), actor()) ::
          {:ok, state()} | {:error, term()}
  def apply_decision(state, %{request_ref: ref} = decision, actor) do
    with :ok <- authenticate_actor(actor),
         :ok <- validate_decision(decision),
         {:ok, %{tool: tool}} <- Map.fetch(state.pending, ref) |> pending_or_error() do
      state = %{state | pending: Map.delete(state.pending, ref)}
      scope = Map.get(decision, :scope, :once)
      {:ok, grant(state, decision.decision, scope, ref, tool)}
    end
  end

  def apply_decision(_state, decision, _actor),
    do: {:error, {:malformed_decision, decision}}

  # The gate's own trust boundary (fail-closed): a grant takes effect ONLY for a
  # human approver. Absent/nil actor is a system emission by the frozen §2.1
  # fold rule — not a human, so not a decision the gate may enact.
  defp authenticate_actor(%{kind: :human}), do: :ok

  defp authenticate_actor(actor),
    do: {:error, {:unauthorized_actor, actor_kind(actor)}}

  defp actor_kind(%{kind: kind}), do: kind
  defp actor_kind(_), do: nil

  defp validate_decision(%{decision: d} = decision) when d in [:approved, :denied] do
    case Map.get(decision, :scope, :once) do
      scope when scope in [:once, :session, :root] -> :ok
      other -> {:error, {:unknown_scope, other}}
    end
  end

  defp validate_decision(decision),
    do: {:error, {:unknown_decision, Map.get(decision, :decision)}}

  defp pending_or_error(:error), do: {:error, :no_such_request}
  defp pending_or_error({:ok, entry}), do: {:ok, entry}

  @doc """
  Rebuild live approval state by folding `approval_decided` events in order (the
  §2.1 replay/resume law): the journal is the authority, so the enforcement
  projection is re-derived from the decisions alone (`request_ref` encodes the
  grant key).

  The fold applies the SAME actor authentication as `apply_decision/3` — a
  decision whose envelope actor is not `%{kind: :human}` folds as a no-op (it
  was never enacted live, so replay must not enact it either; a forged
  agent-authored `approval_decided` in the journal grants nothing on resume).
  Out-of-domain input (unknown `decision`/`scope`, unparseable `request_ref`,
  malformed record) also folds as a no-op — fail-closed degradation, never a
  crash: a version-skewed or partially-corrupt journal still rebuilds.
  """
  @impl true
  @spec rebuild([{decision() | consumption(), actor()}]) :: state()
  def rebuild(events) do
    Enum.reduce(events, new(), fn
      {%{consumed_ref: ref}, _actor}, state ->
        # A journaled once-grant consumption (the guarded action ran): reproduce
        # the POST-consumption state so resume does not resurrect a spent grant.
        # Removal is restrictive, so it needs no actor gate.
        %{state | once: MapSet.delete(state.once, ref)}

      {decision, actor}, state when is_map(decision) ->
        fold_decision(state, decision, actor)

      _malformed, state ->
        state
    end)
  end

  defp fold_decision(state, decision, actor) do
    with :ok <- authenticate_actor(actor),
         :ok <- validate_decision(decision),
         ref when is_binary(ref) <- Map.get(decision, :request_ref, :error),
         {:ok, {tool, _cid}} <- parse_ref(ref) do
      grant(state, decision.decision, Map.get(decision, :scope, :once), ref, tool)
    else
      # Fail-closed no-op: an unauthenticated, unknown, or corrupt decision
      # grants nothing — and never crashes the rebuild.
      _ -> state
    end
  end

  # Fold one decision into the enforcement projection at its scope. The ref (the
  # ONE request identity — tool + call_id + lineage digest) keys both `:once`
  # grants and durable denies; each polarity clears the other, so grant and deny
  # for one request are mutually exclusive. A fresh approval cycle supersedes a
  # prior deny of the same request (AD-14); a deny drops any stale :once grant.
  defp grant(state, :approved, :once, ref, _tool),
    do: %{
      state
      | denied: MapSet.delete(state.denied, ref),
        once: MapSet.put(state.once, ref)
    }

  defp grant(state, :approved, scope, ref, tool) when scope in [:session, :root],
    do: %{
      state
      | denied: MapSet.delete(state.denied, ref),
        session: MapSet.put(state.session, tool_key(tool))
    }

  defp grant(state, :denied, _scope, ref, _tool),
    do: %{
      state
      | denied: MapSet.put(state.denied, ref),
        once: MapSet.delete(state.once, ref)
    }
end
