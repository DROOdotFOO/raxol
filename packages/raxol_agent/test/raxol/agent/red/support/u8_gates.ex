defmodule Raxol.Agent.Red.U8Gates do
  @moduledoc """
  Support for the U8-R red suite (`u8_blast_radius_red_test.exs`).

  Holds:

    * `Counter` — a stub side-effect counter: the gate must never run the
      guarded effect while locked/pending/denied.
    * `Fired` — the dead-injector fire registry (meta-invariant m1: a dead
      injector = green lies).
    * `Tip` — an independent oracle for the freeze's `conversational?`/tip
      predicate (§1.1). Asserts an `approval_requested` is tip-eligible and a
      trailing checkpoint/meta record is NOT (Dormammu-lite, FI-12).
    * `ReferenceGate` — a correct, journal-free implementation of the
      `Raxol.Agent.Authorization.BlastRadiusGate` behaviour. It is the executable
      spec: the contours pass against it, proving they are not vacuous. The
      production module must eventually match its behavior.
    * The dead injectors — each violates exactly one contour, proving the
      contour has teeth (negative controls, meta-invariant m4).
    * `Contours` — the shared contour predicates, gate-parameterized. Each
      returns `:ok` or `{:violation, detail}`. The red tests assert `:ok`
      against the production skeleton (RED until U8 lands); the discrimination
      tests assert `:ok` against `ReferenceGate`; the negative controls assert
      the specific violation signature against each dead injector.

  ## Taint is a FOLD, never a field read (HIGH-1)

  A call carries its argument derivation graph (`arg_refs` entry points +
  `lineage` id → `%{trust: stamped, refs: [...]}`). The gate derives trust by
  folding the U11 tainted-absorbing algebra over the reachable closure — a
  `:trusted`-STAMPED direct argument whose chain reaches a tainted record IS
  tainted (mis-stamp, N-U11.3 class). The `ReadsStampedTrust` injector is the
  field-reading gate that lets exactly that mis-stamped call through.

  ## Replay law checked behaviorally

  `rebuild/1` equality is asserted as BEHAVIOR (the rebuilt gate authorizes
  probe calls identically to the live gate), never by comparing private state —
  so the contour survives any internal representation the real U8 picks.
  """

  # ===========================================================================
  # Counter — a stub side effect the gate must not run while locked/pending
  # ===========================================================================

  defmodule Counter do
    @moduledoc false
    def start, do: Agent.start_link(fn -> 0 end)
    def bump(pid), do: Agent.update(pid, &(&1 + 1))
    def value(pid), do: Agent.get(pid, & &1)
  end

  # ===========================================================================
  # Fired — the dead-injector fire registry (m1)
  # ===========================================================================

  defmodule Fired do
    @moduledoc false
    def start, do: Agent.start_link(fn -> MapSet.new() end)
    def fire(pid, site), do: Agent.update(pid, &MapSet.put(&1, site))
    def fired(pid), do: Agent.get(pid, & &1)
  end

  # ===========================================================================
  # Tip oracle — the freeze §1.1 conversational?/tip predicate (independent)
  # ===========================================================================

  defmodule Tip do
    @moduledoc false

    # Grow-only whitelist (freeze §1.1 CONVERSATIONAL). approval_requested IS a
    # member (ratified F3: family :loop, a pending approval is where a resumed
    # conversation lands); checkpoint / meta / idle / woken are NOT.
    @conversational ~w(turn_started item_started item_completed
                       turn_completed turn_canceled error approval_requested)a

    @doc "The freeze's conversational? predicate (the ONLY tip door)."
    def conversational?(record) when is_map(record) do
      kind = record |> Map.get(:kind, "event") |> to_string()

      kind == "event" and
        Map.get(record, :family) == :loop and
        Map.get(record, :type) in @conversational
    end

    @doc "The tip = highest-position conversational record, or :no_tip."
    def tip(records) when is_list(records) do
      records
      |> Enum.with_index()
      |> Enum.filter(fn {r, _i} -> conversational?(r) end)
      |> case do
        [] -> :no_tip
        pairs -> pairs |> Enum.max_by(fn {_r, i} -> i end) |> elem(0)
      end
    end
  end

  # ===========================================================================
  # Shared builders + reference logic (plain functions, reused by injectors)
  # ===========================================================================

  @doc "Fresh enforcement state: pending requests, once/session grants, durable denies."
  def new_state,
    do: %{
      pending: %{},
      once: MapSet.new(),
      session: MapSet.new(),
      denied: MapSet.new()
    }

  @doc """
  The pure §5.2 predicate: escalate iff irreversible_external OR egress. Fails
  CLOSED (matches production): an unknown effect_class or a non-boolean egress
  escalates — auto-proceed only for a recognized benign class with egress
  exactly false.
  """
  def escalate_p(call) do
    # Map.get, never dot access (matches production): a call MISSING a
    # structural field fails CLOSED to escalation, never raises a KeyError.
    effect_class = Map.get(call, :effect_class, :__missing__)
    egress = Map.get(call, :egress, :__missing__)

    cond do
      effect_class == :irreversible_external -> true
      egress == true -> true
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
  The reference taint FOLD (HIGH-1): tainted iff any record reachable from
  `arg_refs` through `lineage` refs is stamped `:tainted`. Fails CLOSED (matches
  production): an unresolvable ref, an unrecognized trust stamp (a future lattice
  point / garbage), or a malformed (:refs-less / trust-less) entry all fold as
  tainted. Only an HONEST `:trusted` node has its ref chain followed. Cycle-safe.
  """
  def fold_tainted?(call) do
    lineage = Map.get(call, :lineage, %{})
    tainted_reach?(Map.get(call, :arg_refs, []), lineage, MapSet.new())
  end

  defp tainted_reach?([], _lineage, _seen), do: false

  defp tainted_reach?([id | rest], lineage, seen) do
    if MapSet.member?(seen, id) do
      tainted_reach?(rest, lineage, seen)
    else
      case Map.get(lineage, id) do
        # a taint source: absorbing (refs not followed)
        %{trust: :tainted} ->
          true

        # an HONEST :trusted node: fold its ref chain (a mis-stamped :trusted
        # over a tainted chain still folds tainted)
        %{trust: :trusted, refs: refs} ->
          tainted_reach?(refs ++ rest, lineage, MapSet.put(seen, id))

        # Fail CLOSED (matches production): an unknown ref (nil), an unrecognized
        # trust stamp (a future lattice point / garbage), or a malformed
        # (:refs-less / trust-less) entry all read as tainted — U11 §2.1
        # unknown-trust rule. Never follow the refs of a stamp we don't
        # recognize, and never crash on a malformed entry.
        _ ->
          true
      end
    end
  end

  @doc "The ONE canonical tool representation (string) — live-store == parse_ref == rebuild."
  def tool_key(tool) when is_atom(tool), do: Atom.to_string(tool)
  def tool_key(tool) when is_binary(tool), do: tool

  @doc """
  request_ref — the ONE request identity (pending key, once-grant key, deny
  key) — encodes tool + call_id + a digest of the argument lineage, so a
  journaled decision alone rebuilds the grant key. INJECTIVE + delimiter-safe:
  tool and call_id are both length-prefixed, so a ":" in either can't mis-split
  the ref; the digest binds a grant to the request's vetted lineage.
  """
  def request_ref(call),
    do: ref_encode(tool_key(call.tool), call.call_id, lineage_digest(call))

  @doc "Digest of the call's argument-lineage identity (in-session binder)."
  def lineage_digest(call) do
    {Map.get(call, :arg_refs, []), Map.get(call, :lineage, %{})}
    |> :erlang.phash2(4_294_967_296)
    |> Integer.to_string()
  end

  @doc "Encode {tool, call_id, digest} into a delimiter-safe, injective request_ref."
  def ref_encode(tool, cid, digest)
      when is_binary(tool) and is_binary(cid) and is_binary(digest) do
    "req:" <>
      Integer.to_string(byte_size(tool)) <>
      ":" <> tool <> Integer.to_string(byte_size(cid)) <> ":" <> cid <> digest
  end

  @doc """
  Fail-closed parse of a request_ref back into {:ok, {tool, call_id}} (tool is
  the canonical string); :error — never a raise — on any ref that did not
  originate from `ref_encode/3` (matches production).
  """
  def parse_ref("req:" <> rest) do
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

  def parse_ref(_), do: :error

  @doc "The approval_requested neutral event a gate returns on escalation (family :loop — frozen F3)."
  def approval_request(ref, call) do
    # Map.get: a call escalating BECAUSE a structural field is missing must
    # still produce a well-formed request (matches production).
    effect_class = Map.get(call, :effect_class)
    egress = Map.get(call, :egress)

    %{
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
  end

  @doc """
  Reference evaluate, parameterized on the taint function (so injectors swap
  only the part they break). Order is load-bearing:

    1. `:once` grant for this exact call_id → proceed (a completed approval
       cycle covers precisely this request);
    2. durable deny for this call_id → reject (deny survives retries);
    3. tainted lineage → escalate REGARDLESS of class/egress and regardless of
       any session blanket (FI-5: the tainted path is a distinct confirmation);
    4. session/root grant for the tool → proceed;
    5. §5.2 escalation (irreversible_external OR egress) → escalate;
    6. otherwise → auto-proceed (YOLO-applicable over trusted lineage).
  """
  def evaluate_with(state, call, taint_fun) do
    # ONE request identity at every site (matches production): once grants AND
    # durable denies are keyed by the full request_ref (tool + call_id +
    # lineage digest), never a bare call_id — a grant unlocks exactly that
    # request; a DIFFERENT request falls through to the taint fold.
    ref = request_ref(call)

    cond do
      MapSet.member?(state.once, ref) ->
        {:proceed, %{state | once: MapSet.delete(state.once, ref)}}

      MapSet.member?(state.denied, ref) ->
        {:reject, :denied, state}

      taint_fun.(call) ->
        escalate(state, call)

      MapSet.member?(state.session, tool_key(call.tool)) ->
        {:proceed, state}

      escalate_p(call) ->
        escalate(state, call)

      true ->
        {:proceed, state}
    end
  end

  defp escalate(state, call) do
    ref = request_ref(call)
    req = approval_request(ref, call)

    pending =
      Map.put(state.pending, ref, %{call_id: call.call_id, tool: tool_key(call.tool)})

    {:escalate, req, %{state | pending: pending}}
  end

  @doc "authorize in terms of the module's own evaluate — run_fn runs IFF proceed."
  def authorize_via(mod, state, call, run_fn) do
    case mod.evaluate(state, call) do
      {:proceed, st} -> {:proceeded, run_fn.(), st}
      {:escalate, req, st} -> {:escalated, req, st}
      {:reject, reason, st} -> {:rejected, reason, st}
    end
  end

  @doc """
  Fold one decision into the enforcement projection (grant/deny at scope). The
  ref (the ONE request identity) keys both once grants and durable denies; each
  polarity clears the other (matches production).
  """
  def grant(state, :approved, :once, ref, _tool),
    do: %{
      state
      | denied: MapSet.delete(state.denied, ref),
        once: MapSet.put(state.once, ref)
    }

  def grant(state, :approved, scope, ref, tool) when scope in [:session, :root],
    do: %{
      state
      | denied: MapSet.delete(state.denied, ref),
        session: MapSet.put(state.session, tool_key(tool))
    }

  def grant(state, :denied, _scope, ref, _tool),
    do: %{
      state
      | denied: MapSet.put(state.denied, ref),
        once: MapSet.delete(state.once, ref)
    }

  @doc "Actor authentication (matches production): only kind: :human decisions are enacted."
  def authenticate_actor(%{kind: :human}), do: :ok
  def authenticate_actor(actor), do: {:error, {:unauthorized_actor, actor_kind(actor)}}

  defp actor_kind(%{kind: kind}), do: kind
  defp actor_kind(_), do: nil

  @doc "Decision-domain validation (matches production): fail-closed on unknown values."
  def validate_decision(%{decision: d} = decision) when d in [:approved, :denied] do
    case Map.get(decision, :scope, :once) do
      scope when scope in [:once, :session, :root] -> :ok
      other -> {:error, {:unknown_scope, other}}
    end
  end

  def validate_decision(decision),
    do: {:error, {:unknown_decision, Map.get(decision, :decision)}}

  # --- call builders ----------------------------------------------------------

  @doc "A trusted, ≥3-deep, all-:trusted-stamped derivation chain."
  def clean_lineage do
    %{
      arg_refs: [3],
      lineage: %{
        1 => %{trust: :trusted, refs: []},
        2 => %{trust: :trusted, refs: [1]},
        3 => %{trust: :trusted, refs: [2]}
      }
    }
  end

  @doc "Direct argument stamped :tainted (taint entered at a tool_result)."
  def tainted_arg_lineage do
    %{
      arg_refs: [2],
      lineage: %{
        1 => %{trust: :trusted, refs: []},
        2 => %{trust: :tainted, refs: [1]}
      }
    }
  end

  @doc """
  The HIGH-1 vector: the direct argument is STAMPED :trusted (mis-stamp,
  N-U11.3 class) but its ref chain reaches a tainted root. The fold says
  tainted; a field-reading gate says trusted.
  """
  def mis_stamped_lineage do
    %{
      arg_refs: [3],
      lineage: %{
        1 => %{trust: :tainted, refs: []},
        2 => %{trust: :trusted, refs: [1]},
        3 => %{trust: :trusted, refs: [2]}
      }
    }
  end

  @doc "A write call that ESCALATES under §5.2 (irreversible-external), trusted lineage."
  def escalating_call(overrides \\ %{}) do
    %{
      call_id: "c-#{System.unique_integer([:positive])}",
      tool: :fs_write,
      effect_class: :irreversible_external,
      egress: false
    }
    |> Map.merge(clean_lineage())
    |> Map.merge(overrides)
  end

  @doc "A benign call: reversible-local, no egress, trusted lineage → auto-proceeds."
  def benign_call(overrides \\ %{}) do
    %{
      call_id: "c-#{System.unique_integer([:positive])}",
      tool: :fs_touch,
      effect_class: :reversible_local,
      egress: false
    }
    |> Map.merge(clean_lineage())
    |> Map.merge(overrides)
  end

  # ===========================================================================
  # ReferenceGate — the correct executable spec
  # ===========================================================================

  defmodule ReferenceGate do
    @moduledoc false
    @behaviour Raxol.Agent.Authorization.BlastRadiusGate

    alias Raxol.Agent.Red.U8Gates

    def new, do: U8Gates.new_state()

    @impl true
    def escalate?(call), do: U8Gates.escalate_p(call)

    @impl true
    def tainted_lineage?(call), do: U8Gates.fold_tainted?(call)

    @impl true
    def evaluate(state, call),
      do: U8Gates.evaluate_with(state, call, &tainted_lineage?/1)

    @impl true
    def authorize(state, call, run_fn),
      do: U8Gates.authorize_via(__MODULE__, state, call, run_fn)

    @impl true
    def apply_decision(state, %{request_ref: ref} = decision, actor) do
      # The approver is authenticated by the gate (fail-closed): only a
      # kind: :human envelope actor's decision is enacted. Unknown decision/
      # scope values are errors, never crashes.
      with :ok <- U8Gates.authenticate_actor(actor),
           :ok <- U8Gates.validate_decision(decision),
           {:ok, %{tool: tool}} <- fetch_pending(state, ref) do
        state = %{state | pending: Map.delete(state.pending, ref)}
        scope = Map.get(decision, :scope, :once)
        {:ok, U8Gates.grant(state, decision.decision, scope, ref, tool)}
      end
    end

    def apply_decision(_state, decision, _actor),
      do: {:error, {:malformed_decision, decision}}

    defp fetch_pending(state, ref) do
      case Map.fetch(state.pending, ref) do
        # forged / dangling decision: no live request names this ref
        :error -> {:error, :no_such_request}
        {:ok, entry} -> {:ok, entry}
      end
    end

    @impl true
    def rebuild(events) do
      # The journal is the authority: the fold re-derives the enforcement
      # projection from the decisions alone (request_ref encodes the grant
      # key). It re-applies the SAME actor authentication as apply_decision (a
      # non-human decision was never enacted live, so replay enacts nothing),
      # and degrades fail-closed (no-op, never crash) on out-of-domain input.
      # A `:once`-grant consumption marker (%{consumed_ref}) reproduces
      # post-consumption state; removal is restrictive, so no actor gate.
      Enum.reduce(events, new(), fn
        {%{consumed_ref: ref}, _actor}, state ->
          %{state | once: MapSet.delete(state.once, ref)}

        {decision, actor}, state when is_map(decision) ->
          fold_decision(state, decision, actor)

        _malformed, state ->
          state
      end)
    end

    defp fold_decision(state, decision, actor) do
      with :ok <- U8Gates.authenticate_actor(actor),
           :ok <- U8Gates.validate_decision(decision),
           ref when is_binary(ref) <- Map.get(decision, :request_ref, :error),
           {:ok, {tool, _cid}} <- U8Gates.parse_ref(ref) do
        U8Gates.grant(state, decision.decision, Map.get(decision, :scope, :once), ref, tool)
      else
        _ -> state
      end
    end
  end

  # ===========================================================================
  # Dead injectors — each breaks exactly one contour (negative controls, m4)
  # ===========================================================================

  # (a) executes the guarded side effect even while the approval is pending.
  defmodule ExecutesWhilePending do
    @moduledoc false
    defdelegate new, to: ReferenceGate
    defdelegate escalate?(call), to: ReferenceGate
    defdelegate tainted_lineage?(call), to: ReferenceGate
    defdelegate evaluate(state, call), to: ReferenceGate
    defdelegate apply_decision(state, decision, actor), to: ReferenceGate
    defdelegate rebuild(events), to: ReferenceGate

    def authorize(state, call, run_fn) do
      # BUG: runs the side effect regardless of the gate decision.
      result = run_fn.()

      case ReferenceGate.evaluate(state, call) do
        {:proceed, st} -> {:proceeded, result, st}
        {:escalate, req, st} -> {:escalated, req, st}
        {:reject, reason, st} -> {:rejected, reason, st}
      end
    end
  end

  # (b) forgets that deny != approve: any decision unlocks the call.
  defmodule ForgetsDeny do
    @moduledoc false
    alias Raxol.Agent.Red.U8Gates

    defdelegate new, to: ReferenceGate
    defdelegate escalate?(call), to: ReferenceGate
    defdelegate tainted_lineage?(call), to: ReferenceGate
    defdelegate evaluate(state, call), to: ReferenceGate
    defdelegate authorize(state, call, run_fn), to: ReferenceGate
    defdelegate rebuild(events), to: ReferenceGate

    def apply_decision(state, %{request_ref: ref} = decision, _actor) do
      case Map.fetch(state.pending, ref) do
        :error ->
          {:error, :no_such_request}

        {:ok, %{tool: tool}} ->
          # BUG: drops the decision polarity — a deny grants like an approve.
          state = %{state | pending: Map.delete(state.pending, ref)}

          {:ok,
           U8Gates.grant(
             state,
             :approved,
             Map.get(decision, :scope, :once),
             ref,
             tool
           )}
      end
    end
  end

  # (c) accepts a forged/dangling decision (no live request names its ref).
  defmodule AcceptsForgedDecision do
    @moduledoc false
    defdelegate new, to: ReferenceGate
    defdelegate escalate?(call), to: ReferenceGate
    defdelegate tainted_lineage?(call), to: ReferenceGate
    defdelegate evaluate(state, call), to: ReferenceGate
    defdelegate authorize(state, call, run_fn), to: ReferenceGate
    defdelegate rebuild(events), to: ReferenceGate

    def apply_decision(state, %{request_ref: _ref} = _decision, _actor) do
      # BUG: no pending-request check; any decision is silently accepted.
      {:ok, state}
    end
  end

  # (d) keeps approval state only in memory: the fold cannot reconstruct it.
  defmodule InMemoryOnly do
    @moduledoc false
    defdelegate new, to: ReferenceGate
    defdelegate escalate?(call), to: ReferenceGate
    defdelegate tainted_lineage?(call), to: ReferenceGate
    defdelegate evaluate(state, call), to: ReferenceGate
    defdelegate authorize(state, call, run_fn), to: ReferenceGate
    defdelegate apply_decision(state, decision, actor), to: ReferenceGate

    def rebuild(_events) do
      # BUG: ignores the journaled decisions — the projection dies with the BEAM.
      ReferenceGate.new()
    end
  end

  # (e) reads the tool's self-reported destructive_hint instead of effect_class.
  defmodule ReadsDestructiveHint do
    @moduledoc false
    defdelegate new, to: ReferenceGate
    defdelegate tainted_lineage?(call), to: ReferenceGate
    defdelegate evaluate(state, call), to: ReferenceGate
    defdelegate authorize(state, call, run_fn), to: ReferenceGate
    defdelegate apply_decision(state, decision, actor), to: ReferenceGate
    defdelegate rebuild(events), to: ReferenceGate

    def escalate?(call) do
      # BUG: trusts an attacker-controllable hint (N-Y5); egress leg dropped too.
      Map.get(call, :destructive_hint, false) == true
    end
  end

  # (HIGH-1) reads the stamped trust FIELD of the direct args, never folds refs.
  defmodule ReadsStampedTrust do
    @moduledoc false
    alias Raxol.Agent.Red.U8Gates

    defdelegate new, to: ReferenceGate
    defdelegate escalate?(call), to: ReferenceGate
    defdelegate apply_decision(state, decision, actor), to: ReferenceGate
    defdelegate rebuild(events), to: ReferenceGate

    def tainted_lineage?(call) do
      # BUG: field read — a mis-stamped :trusted arg over a tainted chain passes.
      lineage = Map.get(call, :lineage, %{})

      Enum.any?(Map.get(call, :arg_refs, []), fn id ->
        match?(%{trust: :tainted}, Map.get(lineage, id))
      end)
    end

    def evaluate(state, call),
      do: U8Gates.evaluate_with(state, call, &tainted_lineage?/1)

    def authorize(state, call, run_fn),
      do: U8Gates.authorize_via(__MODULE__, state, call, run_fn)
  end

  # (taint) ignores lineage taint entirely: only the pure §5.2 predicate gates.
  defmodule IgnoresTaint do
    @moduledoc false
    alias Raxol.Agent.Red.U8Gates

    defdelegate new, to: ReferenceGate
    defdelegate escalate?(call), to: ReferenceGate
    defdelegate apply_decision(state, decision, actor), to: ReferenceGate
    defdelegate rebuild(events), to: ReferenceGate

    def tainted_lineage?(_call), do: false

    def evaluate(state, call),
      do: U8Gates.evaluate_with(state, call, fn _ -> false end)

    def authorize(state, call, run_fn),
      do: U8Gates.authorize_via(__MODULE__, state, call, run_fn)
  end

  # (meta) emits approval_requested as family :meta — never tip-eligible (F3).
  defmodule EmitsMetaFamily do
    @moduledoc false
    alias Raxol.Agent.Red.U8Gates

    defdelegate new, to: ReferenceGate
    defdelegate escalate?(call), to: ReferenceGate
    defdelegate tainted_lineage?(call), to: ReferenceGate
    defdelegate apply_decision(state, decision, actor), to: ReferenceGate
    defdelegate rebuild(events), to: ReferenceGate

    def evaluate(state, call) do
      case ReferenceGate.evaluate(state, call) do
        {:escalate, req, st} -> {:escalate, %{req | family: :meta}, st}
        other -> other
      end
    end

    def authorize(state, call, run_fn),
      do: U8Gates.authorize_via(__MODULE__, state, call, run_fn)
  end

  # ===========================================================================
  # Contours — shared, gate-parameterized. :ok | {:violation, detail}
  # ===========================================================================

  defmodule Contours do
    @moduledoc false

    alias Raxol.Agent.Red.U8Gates
    alias Raxol.Agent.Red.U8Gates.{Counter, Tip}

    # C1 — locked by default: a write call with no approval never runs the side
    # effect; the outcome is a typed non-proceed (escalate or reject).
    def locked_by_default(gate) do
      safe(fn ->
        {:ok, exec} = Counter.start()
        call = U8Gates.escalating_call()
        result = gate.authorize(gate.new(), call, fn -> Counter.bump(exec) end)

        cond do
          Counter.value(exec) != 0 ->
            {:violation, {:executed_while_locked, Counter.value(exec)}}

          match?({:escalated, _, _}, result) or
              match?({:rejected, _, _}, result) ->
            :ok

          true ->
            {:violation, {:not_a_typed_reject, result}}
        end
      end)
    end

    # C2 — escalation emits approval_requested family :loop (frozen F3), with a
    # request_ref, and it IS the tip when trailed by checkpoint/meta records.
    def escalation_emits_tip_eligible_request(gate) do
      safe(fn ->
        call = U8Gates.escalating_call()

        case gate.evaluate(gate.new(), call) do
          {:escalate, req, _st} ->
            cond do
              Map.get(req, :family) != :loop ->
                {:violation, {:not_loop_family, Map.get(req, :family)}}

              Map.get(req, :type) != :approval_requested ->
                {:violation, {:wrong_type, Map.get(req, :type)}}

              not Map.has_key?(Map.get(req, :payload, %{}), :request_ref) ->
                {:violation, {:no_request_ref, req}}

              not Tip.conversational?(req) ->
                {:violation, {:not_tip_eligible, req}}

              Tip.tip([req, checkpoint_record(), meta_decided_record()]) != req ->
                {:violation, {:trailing_tail_stole_tip, req}}

              true ->
                :ok
            end

          other ->
            {:violation, {:did_not_escalate, other}}
        end
      end)
    end

    # C3 — approve(:once) unlocks exactly that request; a different call to the
    # same tool still escalates.
    def approve_once_unlocks(gate) do
      safe(fn ->
        {:ok, exec} = Counter.start()
        call = U8Gates.escalating_call()
        run = fn -> Counter.bump(exec) end

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call),
             ref = req.payload.request_ref,
             {:ok, s2} <-
               gate.apply_decision(s1, decision(ref, :approved, :once), human()),
             {:proceeded, _, s3} <- gate.authorize(s2, call, run) do
          if Counter.value(exec) == 1 do
            other = U8Gates.escalating_call(%{tool: call.tool})

            case gate.authorize(s3, other, run) do
              {:escalated, _, _} -> :ok
              bad -> {:violation, {:once_blanket_unlocked, bad}}
            end
          else
            {:violation, {:side_effect_count, Counter.value(exec)}}
          end
        else
          bad -> {:violation, {:approved_once_flow_broke, bad}}
        end
      end)
    end

    # C4 — deny is durable: after a deny, a bare retry of the same request must
    # NOT be retried into success without a NEW approval cycle.
    def deny_is_durable(gate) do
      safe(fn ->
        {:ok, exec} = Counter.start()
        call = U8Gates.escalating_call()
        run = fn -> Counter.bump(exec) end

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call),
             ref = req.payload.request_ref,
             {:ok, s2} <-
               gate.apply_decision(s1, decision(ref, :denied, :once), human()) do
          case gate.authorize(s2, call, run) do
            {:proceeded, _, _} ->
              {:violation, {:proceeded_after_deny, Counter.value(exec)}}

            _typed_non_proceed ->
              if Counter.value(exec) == 0,
                do: :ok,
                else: {:violation, {:executed_after_deny, Counter.value(exec)}}
          end
        else
          bad -> {:violation, {:deny_flow_broke, bad}}
        end
      end)
    end

    # C5 — :session scope persists across distinct calls within the session.
    def session_scope_persists(gate) do
      safe(fn ->
        {:ok, exec} = Counter.start()
        run = fn -> Counter.bump(exec) end
        c1 = U8Gates.escalating_call(%{tool: :fs_write})

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), c1),
             ref = req.payload.request_ref,
             {:ok, s2} <-
               gate.apply_decision(
                 s1,
                 decision(ref, :approved, :session),
                 human()
               ),
             {:proceeded, _, s3} <- gate.authorize(s2, c1, run) do
          c2 = U8Gates.escalating_call(%{tool: :fs_write})

          case gate.authorize(s3, c2, run) do
            {:proceeded, _, _} ->
              if Counter.value(exec) == 2,
                do: :ok,
                else: {:violation, {:side_effect_count, Counter.value(exec)}}

            bad ->
              {:violation, {:session_did_not_persist, bad}}
          end
        else
          bad -> {:violation, {:session_flow_broke, bad}}
        end
      end)
    end

    # C6 — fold-rebuild: state reconstructed by folding approval_decided events
    # authorizes probe calls identically to the live state (§2.1 replay law).
    # Behavioral equality — never a peek into the gate's private struct.
    def fold_rebuild_equals_live(gate, seed) do
      safe(fn ->
        {live_state, events, probes} = drive_decision_sequence(gate, seed)
        rebuilt = gate.rebuild(events)

        mismatches =
          for probe <- probes,
              live_tag = authorize_tag(gate, live_state, probe),
              rebuilt_tag = authorize_tag(gate, rebuilt, probe),
              live_tag != rebuilt_tag do
            {probe.call_id, live_tag, rebuilt_tag}
          end

        case mismatches do
          [] -> :ok
          list -> {:violation, {:rebuild_diverged, seed, list}}
        end
      end)
    end

    # C7 — a forged/dangling approval_decided (no live request names its
    # request_ref) is rejected, never enacted.
    def forged_decision_rejected(gate) do
      safe(fn ->
        forged = decision("req:fs_write:ghost", :approved, :session)

        case gate.apply_decision(gate.new(), forged, human()) do
          {:error, _reason} -> :ok
          {:ok, _st} -> {:violation, :forged_decision_accepted}
          other -> {:violation, {:unexpected, other}}
        end
      end)
    end

    # C8 — the pure §5.2 predicate table: escalate iff
    # irreversible_external OR egress; both benign classes without egress → auto.
    def escalate_predicate(gate) do
      safe(fn ->
        checks = [
          {U8Gates.escalating_call(%{
             effect_class: :irreversible_external,
             egress: false
           }), true},
          {U8Gates.escalating_call(%{
             effect_class: :irreversible_external,
             egress: true
           }), true},
          {U8Gates.benign_call(%{
             effect_class: :reversible_local,
             egress: true
           }), true},
          {U8Gates.benign_call(%{
             effect_class: :bounded_sandboxable,
             egress: true
           }), true},
          {U8Gates.benign_call(%{
             effect_class: :reversible_local,
             egress: false
           }), false},
          {U8Gates.benign_call(%{
             effect_class: :bounded_sandboxable,
             egress: false
           }), false}
        ]

        case Enum.find(checks, fn {call, expected} ->
               gate.escalate?(call) != expected
             end) do
          nil ->
            :ok

          {call, expected} ->
            {:violation, {:predicate_wrong, call.effect_class, call.egress, expected}}
        end
      end)
    end

    # C9 — the predicate reads STRUCTURAL effect_class, never a
    # self-reported hint: an irreversible call claiming destructive_hint: false
    # still escalates.
    def predicate_ignores_destructive_hint(gate) do
      safe(fn ->
        lying =
          U8Gates.escalating_call(%{
            effect_class: :irreversible_external,
            egress: false,
            destructive_hint: false
          })

        if gate.escalate?(lying),
          do: :ok,
          else: {:violation, {:trusted_self_report, lying.effect_class}}
      end)
    end

    # C10 — taint escalation is a FOLD over refs (HIGH-1), and taint escalates
    # regardless of a benign class (FI-5). Three legs, distinct signatures:
    #   1. direct :tainted arg → escalate  (a field-reading gate passes this leg)
    #   2. mis-stamped :trusted arg over tainted chain → escalate (fold-only leg)
    #   3. clean trusted chain, benign → proceed (no false-positive fold)
    def taint_escalates(gate) do
      safe(fn ->
        direct =
          U8Gates.benign_call() |> Map.merge(U8Gates.tainted_arg_lineage())

        mis_stamped =
          U8Gates.benign_call() |> Map.merge(U8Gates.mis_stamped_lineage())

        clean = U8Gates.benign_call()

        with :ok <- expect_escalate(gate, direct, :tainted_auto_proceeded),
             :ok <-
               expect_escalate(gate, mis_stamped, :mis_stamped_auto_proceeded) do
          case gate.evaluate(gate.new(), clean) do
            {:proceed, _st} -> :ok
            other -> {:violation, {:clean_lineage_escalated, other}}
          end
        end
      end)
    end

    # C12 (Fix 2 regression) — a `:once` grant unlocks EXACTLY that request
    # (tool + call_id), never a different tool sharing the call_id, and can never
    # let a DIFFERENT request bypass the taint fold (AD-14). Two legs:
    #   1. a once-grant for (tool_a, cid) does NOT admit (tool_b, cid) — it
    #      escalates (the pre-fix call_id-only key admitted it);
    #   2. a TAINTED (tool_b, cid) still escalates — the once branch (keyed by the
    #      full identity) doesn't match, so the taint fold runs (the pre-fix
    #      call_id-only key short-circuited the fold and auto-proceeded).
    def once_grant_is_request_scoped(gate) do
      safe(fn ->
        cid = "shared-once-cid"
        call_a = U8Gates.escalating_call(%{tool: :once_tool_a, call_id: cid})

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call_a),
             ref = req.payload.request_ref,
             {:ok, s2} <-
               gate.apply_decision(s1, decision(ref, :approved, :once), human()) do
          other_tool =
            U8Gates.escalating_call(%{tool: :once_tool_b, call_id: cid})

          tainted_other =
            U8Gates.escalating_call(%{tool: :once_tool_b, call_id: cid})
            |> Map.merge(U8Gates.tainted_arg_lineage())

          cond do
            authorize_tag(gate, s2, other_tool) != :escalated ->
              {:violation, {:once_grant_admitted_other_tool, authorize_tag(gate, s2, other_tool)}}

            not match?({:escalate, _, _}, gate.evaluate(s2, tainted_other)) ->
              {:violation, {:tainted_request_bypassed_fold, gate.evaluate(s2, tainted_other)}}

            true ->
              :ok
          end
        else
          bad -> {:violation, {:once_scope_flow_broke, bad}}
        end
      end)
    end

    # C15 (Fix 5 regression) — the taint fold fails CLOSED on inputs it does not
    # recognize, matching production: an UNKNOWN-trust leaf (a no-refs leaf whose
    # trust is an unrecognized value) escalates, and a MALFORMED (:refs-less /
    # trust-less) entry escalates rather than crashing. Pins the ReferenceGate
    # spec against a regression toward the old fail-OPEN / CaseClauseError fold.
    def taint_fold_fails_closed(gate) do
      safe(fn ->
        unknown_trust =
          U8Gates.benign_call(%{
            arg_refs: [1],
            lineage: %{1 => %{trust: :unknown_future_value, refs: []}}
          })

        malformed =
          U8Gates.benign_call(%{
            arg_refs: [1],
            lineage: %{1 => %{note: "no trust, no refs"}}
          })

        with :ok <-
               expect_escalate(gate, unknown_trust, :unknown_trust_leaf_proceeded),
             :ok <-
               expect_escalate(gate, malformed, :malformed_entry_proceeded) do
          :ok
        end
      end)
    end

    # C14 (Fix 4 regression) — the §5.2 predicate fails CLOSED on inputs it does
    # not recognize: an UNKNOWN effect_class escalates, and a NON-boolean egress
    # escalates (the pre-fix `class == :irreversible_external or egress == true`
    # returned false — a silent proceed — for both).
    def escalate_predicate_fails_closed(gate) do
      safe(fn ->
        unknown_class =
          U8Gates.escalating_call(%{
            effect_class: :quantum_teleport,
            egress: false
          })

        non_boolean_egress =
          U8Gates.escalating_call(%{
            effect_class: :reversible_local,
            egress: :maybe
          })

        cond do
          not gate.escalate?(unknown_class) ->
            {:violation, {:unknown_class_proceeded, unknown_class.effect_class}}

          not gate.escalate?(non_boolean_egress) ->
            {:violation, {:non_boolean_egress_proceeded, non_boolean_egress.egress}}

          true ->
            :ok
        end
      end)
    end

    # C13 (Fix 3 regression) — a CONSUMED `:once` grant is reconstructed by the
    # fold as consumed: after consuming a once-grant and rebuilding from the
    # journal (the decision + the consumption marker), the same call is NOT
    # re-admitted (rebuild == post-consumption live). The pre-fix rebuild folded
    # only approval_decided, so it resurrected the spent grant on resume.
    def once_consumption_survives_rebuild(gate) do
      safe(fn ->
        {:ok, exec} = Counter.start()
        run = fn -> Counter.bump(exec) end
        call = U8Gates.escalating_call()

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call),
             ref = req.payload.request_ref,
             d = decision(ref, :approved, :once),
             {:ok, s2} <- gate.apply_decision(s1, d, human()),
             {:proceeded, _, s3} <- gate.authorize(s2, call, run) do
          # Live state after the one-shot grant is spent: a re-issue escalates.
          live_tag = authorize_tag(gate, s3, call)

          # The journal the runtime records for this flow: the decision, then the
          # consumption marker naming the spent grant's ref.
          journal = [{d, human()}, {%{consumed_ref: ref}, human()}]
          rebuilt_tag = authorize_tag(gate, gate.rebuild(journal), call)

          cond do
            Counter.value(exec) != 1 ->
              {:violation, {:side_effect_count, Counter.value(exec)}}

            live_tag == :proceeded ->
              {:violation, {:once_not_consumed_live, live_tag}}

            rebuilt_tag != live_tag ->
              {:violation, {:consumption_not_reconstructed, live_tag, rebuilt_tag}}

            true ->
              :ok
          end
        else
          bad -> {:violation, {:once_consumption_flow_broke, bad}}
        end
      end)
    end

    # C11 (Fix 1 regression) — request_ref is INJECTIVE + string-canonical:
    # a STRING-named tool and a tool/call_id containing ":" both survive the
    # request_ref → parse_ref round-trip, and the fold-rebuilt enforcement state
    # authorizes the same call identically to the live state. The pre-fix gate
    # (atom-stringified tool + `String.to_existing_atom` + `split(":", parts: 2)`)
    # crashes or diverges on exactly these inputs.
    def ref_roundtrips_string_and_colon(gate) do
      safe(fn ->
        cases = [
          # ":" in BOTH the tool name and the call_id — the naive split mis-parses.
          %{tool: "weird:tool", call_id: "c:1:x"},
          # a plain STRING tool — the naive rebuild does String.to_existing_atom.
          %{tool: "string_only_tool", call_id: "c-plain"}
        ]

        Enum.reduce_while(cases, :ok, fn overrides, _acc ->
          case session_grant_rebuild_equals_live(gate, overrides) do
            :ok -> {:cont, :ok}
            violation -> {:halt, violation}
          end
        end)
      end)
    end

    # Escalate a call, approve at :session scope, then assert live and the
    # decision-folded rebuild admit the SAME call identically — exercising the
    # tool round-trip (session grants are tool-keyed) across the ref encoding.
    defp session_grant_rebuild_equals_live(gate, overrides) do
      call = U8Gates.escalating_call(overrides)

      with {:escalate, req, s1} <- gate.evaluate(gate.new(), call),
           ref = req.payload.request_ref,
           d = decision(ref, :approved, :session),
           {:ok, s2} <- gate.apply_decision(s1, d, human()) do
        live_tag = authorize_tag(gate, s2, call)
        rebuilt_tag = authorize_tag(gate, gate.rebuild([{d, human()}]), call)

        cond do
          live_tag != :proceeded ->
            {:violation, {:session_grant_did_not_admit, overrides, live_tag}}

          rebuilt_tag != live_tag ->
            {:violation, {:rebuild_diverged_for_ref, ref, live_tag, rebuilt_tag}}

          true ->
            :ok
        end
      else
        bad -> {:violation, {:ref_roundtrip_flow_broke, overrides, bad}}
      end
    end

    # C16 (Drew HIGH-1 regression) — the approver is AUTHENTICATED: an
    # approval_decided whose envelope actor is not kind: :human (agent, system,
    # nil, kindless) does NOT unlock the escalated call — neither live
    # (apply_decision) nor on rebuild (a forged agent-authored decision folded
    # from the journal) — and the guarded side effect never runs. A :human
    # approval on the same still-pending request still works. The pre-fix gate
    # discarded the actor entirely, so an agent self-approved its own write.
    def non_human_approver_never_grants(gate) do
      safe(fn ->
        {:ok, exec} = Counter.start()
        run = fn -> Counter.bump(exec) end
        call = U8Gates.escalating_call()

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call) do
          d = decision(req.payload.request_ref, :approved, :session)

          bad_actors = [
            %{kind: :agent, id: "agent-1"},
            %{kind: :system, id: "sys-1"},
            nil,
            %{id: "kindless"}
          ]

          live_violation =
            Enum.find_value(bad_actors, fn actor ->
              state =
                case gate.apply_decision(s1, d, actor) do
                  {:ok, st} -> st
                  {:error, _} -> s1
                end

              case gate.authorize(state, call, run) do
                {:proceeded, _, _} ->
                  {:violation, {:non_human_approver_granted_live, actor}}

                _ ->
                  nil
              end
            end)

          rebuild_violation =
            Enum.find_value(bad_actors, fn actor ->
              case gate.authorize(gate.rebuild([{d, actor}]), call, run) do
                {:proceeded, _, _} ->
                  {:violation, {:non_human_approver_granted_rebuild, actor}}

                _ ->
                  nil
              end
            end)

          cond do
            live_violation != nil ->
              live_violation

            rebuild_violation != nil ->
              rebuild_violation

            Counter.value(exec) != 0 ->
              {:violation, {:side_effect_ran_unapproved, Counter.value(exec)}}

            true ->
              # the human decision still works on the untouched pending request
              case gate.apply_decision(s1, d, human()) do
                {:ok, s2} ->
                  case gate.authorize(s2, call, run) do
                    {:proceeded, _, _} -> :ok
                    bad -> {:violation, {:human_approval_stopped_working, bad}}
                  end

                bad ->
                  {:violation, {:human_approval_rejected, bad}}
              end
          end
        else
          bad -> {:violation, {:approver_auth_flow_broke, bad}}
        end
      end)
    end

    # C17 (Drew HIGH-2 regression) — deny and grant use ONE key (the full
    # request identity), so a deny is request-scoped: after denying
    # (tool_a, cid), the SAME request stays durably rejected, but a DIFFERENT
    # tool sharing the bare call_id gets its own approval cycle (escalates) —
    # it is never blanket-rejected by another request's deny. The pre-fix gate
    # keyed denies by bare call_id (asymmetric with the ref-keyed once grants):
    # this leg over-blocked, and the mirrored keying admitted deny bypass.
    def deny_is_request_scoped(gate) do
      safe(fn ->
        cid = "shared-deny-cid"
        call_a = U8Gates.escalating_call(%{tool: :deny_tool_a, call_id: cid})
        call_b = U8Gates.escalating_call(%{tool: :deny_tool_b, call_id: cid})

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call_a),
             {:ok, s2} <-
               gate.apply_decision(
                 s1,
                 decision(req.payload.request_ref, :denied, :once),
                 human()
               ) do
          cond do
            not match?({:reject, :denied, _}, gate.evaluate(s2, call_a)) ->
              {:violation, {:deny_did_not_stick, gate.evaluate(s2, call_a)}}

            not match?({:escalate, _, _}, gate.evaluate(s2, call_b)) ->
              {:violation, {:deny_over_blocked_other_tool, gate.evaluate(s2, call_b)}}

            true ->
              :ok
          end
        else
          bad -> {:violation, {:deny_scope_flow_broke, bad}}
        end
      end)
    end

    # C18 (Drew MEDIUM regression) — the decision folds degrade fail-closed on
    # out-of-domain journal input, never crash (replay-DoS class): an unknown
    # decision value, an out-of-domain scope, an unparseable/foreign
    # request_ref, and a malformed record all fold as NO-GRANT in rebuild/1
    # (the session still reconstructs; a valid human grant in the same journal
    # still applies), and apply_decision returns {:error, _} for out-of-domain
    # values. The pre-fix folds raised FunctionClauseError/MatchError.
    def corrupt_journal_folds_fail_closed(gate) do
      safe(fn ->
        call = U8Gates.escalating_call(%{tool: :fold_tool, call_id: "c-fold"})

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call) do
          ref = req.payload.request_ref
          valid = decision(ref, :approved, :session)

          corrupt = [
            {%{request_ref: ref, decision: :corrupt, refs: []}, human()},
            {%{request_ref: ref, decision: :approved, scope: :global, refs: []}, human()},
            {%{request_ref: "not-a-ref", decision: :approved, scope: :session, refs: []},
             human()},
            {%{request_ref: "req:999:overflow", decision: :approved, scope: :session, refs: []},
             human()},
            {:not_even_a_decision, human()},
            :not_even_a_pair
          ]

          corrupt_only = gate.rebuild(corrupt)
          with_valid = gate.rebuild(corrupt ++ [{valid, human()}])

          cond do
            authorize_tag(gate, corrupt_only, call) == :proceeded ->
              {:violation, :corrupt_journal_granted}

            authorize_tag(gate, with_valid, call) != :proceeded ->
              {:violation,
               {:valid_grant_lost_among_corruption, authorize_tag(gate, with_valid, call)}}

            not match?(
              {:error, _},
              gate.apply_decision(
                s1,
                %{request_ref: ref, decision: :corrupt, refs: []},
                human()
              )
            ) ->
              {:violation, :unknown_decision_enacted_live}

            not match?(
              {:error, _},
              gate.apply_decision(
                s1,
                %{request_ref: ref, decision: :approved, scope: :global, refs: []},
                human()
              )
            ) ->
              {:violation, :unknown_scope_enacted_live}

            true ->
              :ok
          end
        else
          bad -> {:violation, {:corrupt_fold_flow_broke, bad}}
        end
      end)
    end

    # C19 (Drew LOW regression) — the §5.2 predicate is defensive on the
    # authorization path: a call map MISSING effect_class or egress fails
    # CLOSED to escalation (both in escalate?/1 and through evaluate/2), never
    # raises a KeyError. The pre-fix predicate used dot access and crashed.
    def predicate_missing_fields_fail_closed(gate) do
      safe(fn ->
        no_egress = Map.delete(U8Gates.benign_call(), :egress)
        no_class = Map.delete(U8Gates.benign_call(), :effect_class)

        cond do
          not gate.escalate?(no_egress) ->
            {:violation, :missing_egress_proceeded}

          not gate.escalate?(no_class) ->
            {:violation, :missing_class_proceeded}

          not match?({:escalate, _, _}, gate.evaluate(gate.new(), no_egress)) ->
            {:violation,
             {:evaluate_choked_on_missing_egress, gate.evaluate(gate.new(), no_egress)}}

          not match?({:escalate, _, _}, gate.evaluate(gate.new(), no_class)) ->
            {:violation, {:evaluate_choked_on_missing_class, gate.evaluate(gate.new(), no_class)}}

          true ->
            :ok
        end
      end)
    end

    # C20 (Drew LOW regression) — a standing `:once` grant is bound to the
    # request's VETTED lineage, not just (tool, call_id): re-issuing the same
    # ids with newly-TAINTED lineage misses the grant (the ref's lineage digest
    # differs), falls through to the decision-time taint fold, and escalates —
    # the side effect never runs on the stale grant. The pre-fix ref keyed only
    # tool + call_id, so the standing grant admitted the re-tainted call.
    def once_grant_bound_to_lineage(gate) do
      safe(fn ->
        {:ok, exec} = Counter.start()
        run = fn -> Counter.bump(exec) end
        call = U8Gates.escalating_call(%{tool: :lineage_tool, call_id: "c-lin"})

        with {:escalate, req, s1} <- gate.evaluate(gate.new(), call),
             {:ok, s2} <-
               gate.apply_decision(
                 s1,
                 decision(req.payload.request_ref, :approved, :once),
                 human()
               ) do
          retainted = Map.merge(call, U8Gates.tainted_arg_lineage())

          case gate.authorize(s2, retainted, run) do
            {:escalated, _, _} ->
              if Counter.value(exec) == 0,
                do: :ok,
                else: {:violation, {:side_effect_ran, Counter.value(exec)}}

            bad ->
              {:violation, {:stale_grant_admitted_retainted_call, bad}}
          end
        else
          bad -> {:violation, {:lineage_binding_flow_broke, bad}}
        end
      end)
    end

    # --- helpers -------------------------------------------------------------

    defp expect_escalate(gate, call, violation_tag) do
      case gate.evaluate(gate.new(), call) do
        {:escalate, _req, _st} -> :ok
        {:proceed, _st} -> {:violation, violation_tag}
        other -> {:violation, {:unexpected, violation_tag, other}}
      end
    end

    # A reproducible decision schedule: 8 escalating calls across 3 tools,
    # approved at rotating scopes, with fixed denies at i ∈ {4, 8}. The seed
    # rotates tool/scope assignment; failures report the seed (meta-inv m2).
    defp drive_decision_sequence(gate, seed) do
      steps =
        for i <- 1..8 do
          %{
            tool: Enum.at([:fs_write, :shell, :net_send], rem(i + seed, 3)),
            decision: if(rem(i, 4) == 0, do: :denied, else: :approved),
            scope: Enum.at([:once, :session, :root], rem(i + seed, 3))
          }
        end

      Enum.reduce(steps, {gate.new(), [], []}, fn step, {st, evs, probes} ->
        call =
          U8Gates.escalating_call(%{
            tool: step.tool,
            effect_class: :irreversible_external
          })

        case gate.evaluate(st, call) do
          {:escalate, req, st1} ->
            d = decision(req.payload.request_ref, step.decision, step.scope)

            case gate.apply_decision(st1, d, human()) do
              {:ok, st2} -> {st2, evs ++ [{d, human()}], probes ++ [call]}
              {:error, _} -> {st1, evs, probes ++ [call]}
            end

          {:proceed, st1} ->
            {st1, evs, probes ++ [call]}

          {:reject, _reason, st1} ->
            {st1, evs, probes ++ [call]}
        end
      end)
    end

    defp authorize_tag(gate, state, probe) do
      case gate.authorize(state, probe, fn -> :ran end) do
        {tag, _, _} -> tag
      end
    end

    defp decision(ref, decision, scope),
      do: %{request_ref: ref, decision: decision, scope: scope, refs: []}

    defp human, do: %{kind: :human, id: "u-1"}

    defp checkpoint_record,
      do: %{kind: "checkpoint", family: :loop, type: :checkpoint, tip_offset: 1}

    defp meta_decided_record,
      do: %{kind: "event", family: :meta, type: :approval_decided, payload: %{}}

    # A contour must never crash the suite: a :not_implemented raise (the
    # production skeleton) or any error is itself a violation of the contract.
    def safe(fun) do
      fun.()
    rescue
      e -> {:violation, {:raised, Exception.message(e)}}
    catch
      kind, reason -> {:violation, {:caught, kind, reason}}
    end
  end
end
