defmodule Raxol.Agent.DoneGate do
  @moduledoc """
  U21 — Evidence-gated done (FI-6). A pure read/decision function over a turn
  journal: it never touches a shared write path (see
  `docs/proposals/in-flight/harness-roadmap.md` §U21 + FI-6 and
  `packages/raxol_agent/test/raxol/agent/red/u21_evidence_done_red_test.exs`).

  ## What U21 gates

  An agent may not declare a turn "done" on its own say-so. The
  done/turn-success transition (a `turn_completed` with `final: true`) is
  **gated on journaled evidence** — tool results and verification outputs (test
  runs, file checks) — that **postdates the last mutating action of the turn**.

  Evidence is named by `refs`: journal offsets carried on the proposed done.
  Each ref is checked, in `refs` order, and the **first violation wins**:

    1. **exist** — resolve to a real journal record, else `{:error, {:missing_ref, offset}}`;
    2. **be evidence-class** — a tool result / verification output, never the
       agent's own `:message` self-report and never an internal `:state_change`,
       else `{:error, {:not_evidence, offset}}`;
    3. **belong to the claiming turn** (H2) — a ref journaled under a *different*
       turn is `{:error, {:foreign_turn, offset}}`, even when its offset
       postdates this turn's last mutation (the cross-turn evidence spoof this
       check exists to close);
    4. **postdate the last mutation** — strictly greater offset than the turn's
       last mutating action; stale evidence that predates a later mutation does
       not count, else `{:error, {:stale_evidence, offset}}`;
    5. **not be the last mutation's own echo** — a `:tool_result` produced BY
       the turn's last mutating tool call is that mutation's byproduct, not
       independent verification of it, else `{:error, {:mutation_echo, offset}}`
       (see "What counts as a mutation" below for the pairing rule).

  A done carrying no refs at all is `{:error, :evidence_required}`. Only when
  every ref satisfies (1)-(5) does the gate accept and hand back the durable
  `turn_completed{final: true, refs: [...]}` event for journaling — so a surface
  can render "done because X".

  ## What counts as a mutation (fail-safe by construction)

  **Every completed `:tool_use` is a mutation.** The real producer
  (`Raxol.Agent.Contract.pump/3`) stamps no effect metadata on tool calls, and
  the frozen effect taxonomy (`harness-freeze-contracts.md` §5.2:
  `:reversible_local | :bounded_sandboxable | :irreversible_external`) contains
  only effect-BEARING classes and rules that effect enforcement is *structural,
  compiled in our own tree — never self-reported*. So:

    * an absent `effect_class` means UNCLASSIFIED, and unclassified resolves
      toward "is a mutation" (fail-safe) — never toward "is safe";
    * a producer-stamped `mutating: false` (or any `destructiveHint`-style
      self-report) can never REMOVE a tool call from the mutation set — a lying
      producer must not be able to widen the valid-evidence window and launder
      stale evidence past a real mutation;
    * the only future seam that may refine a `:tool_use` OUT of the mutation
      set is a structural effect classification from the F2 `Raxol.Action`
      draft (see `classified_effect_free?/1`), which does not exist yet.

  Because a `:tool_result` always postdates its own `:tool_use`, check 5 pins
  the corollary: the last mutation's own result echo is not evidence that the
  mutation was verified. A result is paired to its producing call by tool
  `name` + nearest-preceding order — the only pairing signal the frozen v0
  producer shape carries (it stamps `name` on both sides and no `call_id` on
  results).

  **Consequence, stated plainly:** on a journal produced by today's v0
  producer, where no tool carries a structural classification, every tool call
  gates and no tool result can green-light a done — the gate is *fully
  fail-closed* until a structurally-classified verification class exists.
  That is intentional; see "Wiring status".

  ## Wiring status (disclosure)

  `Contract.pump/3` consults `gate/3` on the real done path, in
  **observe-only** mode: it derives the turn's candidate evidence
  (`evidence_refs/2`), calls `gate/3`, and emits a telemetry signal for the
  verdict, but it does NOT hard-block completion — the turn still closes with
  `turn_completed{final: true}`, carrying the accepted `refs` when the gate
  accepts. Completion stays fail-open on purpose: until U8 (BlastRadiusGate)
  introduces structural mutation classes and a real verification class, the
  gate is fully fail-closed on v0 producer journals (see "What counts as a
  mutation"), so blocking every done would be wrong. The observe-only wiring
  makes the boundary live and measurable now:

    * `[:raxol, :agent, :done_gate, :ungated_done]` — a done citing no evidence
      (the parked zero-tool-turn policy path);
    * `[:raxol, :agent, :done_gate, :rejected_evidence]` — a done whose cited
      evidence the gate rejected (metadata carries the `reason`).

  Promoting this to a hard block is the U21-I impl unit, which follows U8 and
  the refs-citation seam (how an agent names its own evidence offsets). Both
  are tracked in `docs/proposals/in-flight/harness-parked.md` (U21
  gating-strength ruling; wiring debt).

  The gate never transitions the turn to done on a rejected claim; the turn
  stays open and the typed error is surfaced.

  ### A nil claiming turn is structurally rejected (`:unturned_done`)

  The whole gate hinges on turn identity: same-turn ownership (H2, check 3) and
  the per-turn last-mutation window (check 4) are both keyed on `turn_id`. A
  done whose *claiming* `turn_id` is `nil` therefore cannot be gated — its
  ownership check degenerates to `nil == nil` (any nil-turn ref would satisfy
  "same turn") and its last-mutation scan collapses onto the nil-turn slice, so
  cross-turn isolation evaporates for the whole claim. Rather than let value
  equality paper over a missing turn, a nil claiming turn is rejected up front
  as `{:error, :unturned_done}`, before any ref is examined and regardless of
  how many refs are cited. There is no such thing as a done that belongs to no
  turn.

  ### Content is NOT validated (intentional scope boundary)

  Evidence **class** is checked, not its **content**: a `:tool_result` that ran
  and reported *failure* (e.g. `"tests: 0 passed, 12 FAILED"`) still class-passes
  — the gate pins that a verification tool RAN and was journaled, not that it
  passed. A future unit may add content gating (parsing pass/fail out of the
  result payload); U21 deliberately stops at "a verification tool ran".

  ## Gating strength (policy note)

  The roadmap's U21 wording is the *weaker* reading: "`turn_completed{final:
  true}` carries verification artifacts ... as data" — i.e. the final event
  merely *reports* whatever evidence a run happened to produce. This
  implementation deliberately follows the **stronger** reading that the U21-R
  red suite encodes: a done that cites no journaled evidence (or cites refs
  that don't hold up) is **REJECTED** — the turn does not transition to done.
  The red suite (`Oracle.verdict/3` + `Contours`) is the authoritative contract
  here; this module matches it. The separate parked policy question about
  **zero-tool turns** (whether a turn that legitimately ran no tools may ever
  declare done) is left UNRESOLVED on purpose — this module does not
  special-case it, preserving the suite's current behaviour (a turn with no
  evidence refs is `:evidence_required`, full stop).

  ## Behaviour

  `gate/3` is declared as a behaviour callback so the red suite can drive
  deliberately-broken *dead injectors* (an impl that skips the ref check, one
  that checks existence but not ordering, one that lets self-reported text
  count as evidence, one that skips the turn-ownership check) through the same
  shape and prove each one fails its targeted red.

  ## Label key (review cross-references)

  Labels like `H2` and `M1` in this module and its red suite are finding ids
  from PR #570's adversarial review rounds — severity (High/Medium/Low) plus
  index — kept so each fix stays traceable to the finding it closes. `§0
  decision-time-fold law` = `docs/proposals/in-flight/harness-freeze-contracts.md`
  §0 clause 7; `§5.2` = the effect-class taxonomy in the same document; `FI-6`
  = the roadmap future-invariant this unit implements; `meta-inv N` = the
  red-suite meta-invariants in `docs/proposals/in-flight/harness-invariants.md`.
  """

  alias Raxol.Agent.Contract.Event

  @typedoc "A journal offset (`Event.id`), the currency `refs` are stated in."
  @type offset :: non_neg_integer()

  @typedoc """
  A turn's journal: contract events in offset order. Each carries `id` (the
  offset), `turn_id`, `type`, and `payload` (see `Raxol.Agent.Contract.Event`).
  """
  @type journal :: [Event.t() | map()]

  @typedoc """
  The gate verdict. Accept hands back the done event to journal; every reject is
  a distinct typed error naming the offending ref where one applies.
  """
  @type verdict ::
          {:ok, Event.t()}
          | {:error, :evidence_required}
          | {:error, :unturned_done}
          | {:error, {:missing_ref, offset()}}
          | {:error, {:not_evidence, offset()}}
          | {:error, {:foreign_turn, offset()}}
          | {:error, {:stale_evidence, offset()}}
          | {:error, {:mutation_echo, offset()}}

  @doc """
  Gate a proposed done for `turn_id` against `journal`, citing evidence `refs`.

  See the moduledoc for the acceptance contract. Returns `{:ok, done_event}`
  (a `turn_completed{final: true, refs: refs}` to be journaled) or a typed
  rejection; the turn does not transition to done on a rejection.
  """
  @callback gate(journal(), turn_id :: term(), refs :: [offset()]) :: verdict()

  @doc """
  Gate a proposed done for `turn_id` against `journal`, citing evidence `refs`.

  A nil claiming turn is `{:error, :unturned_done}` (structural — see the
  moduledoc; checked first, before evidence). A done with no refs is
  `{:error, :evidence_required}`. Otherwise refs are walked in caller order and
  the first violation wins (existence -> class -> same-turn -> ordering). On
  acceptance, hands back the durable `turn_completed{final: true, refs: refs}`
  event to journal.
  """
  @spec gate(journal(), term(), [offset()]) :: verdict()
  # A nil claiming turn cannot be gated: same-turn ownership and the last-
  # mutation window both key on turn_id, and `nil == nil` would let any nil-turn
  # ref pass. Reject structurally, ahead of the evidence checks, for ANY refs.
  def gate(_journal, nil, _refs), do: {:error, :unturned_done}

  def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

  def gate(journal, turn_id, refs) do
    # One walk builds the offset index; each ref is then an O(1) lookup
    # instead of a fresh whole-journal Enum.find per ref.
    by_offset = Map.new(journal, &{event_id(&1), &1})
    last_mut = last_mutation(journal, turn_id)

    Enum.reduce_while(refs, {:ok, refs}, fn ref, acc ->
      case classify_ref(journal, by_offset, turn_id, last_mut, ref) do
        :ok -> {:cont, acc}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _refs} -> {:ok, done_event(journal, turn_id, refs)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Candidate evidence refs for `turn_id`: journal offsets of the turn's own
  `:tool_result` events that postdate its last mutating action.

  This mirrors the gate's evidence-class + ordering window so a producer can
  cite the refs it would offer without re-deriving the notion of evidence.
  It does NOT pre-apply the mutation-echo check (check 5): those candidates are
  handed to `gate/3`, which remains the sole authority on acceptance. On a
  journal from today's v0 producer (no structural effect classification) the
  gate is fully fail-closed, so most candidates resolve to `:mutation_echo`;
  an empty list resolves to `:evidence_required`.
  """
  @spec evidence_refs(journal(), term()) :: [offset()]
  def evidence_refs(journal, turn_id) do
    last_mut = last_mutation(journal, turn_id)

    journal
    |> Enum.filter(fn ev ->
      event_turn_id(ev) == turn_id and evidence_class?(ev) and
        (last_mut == nil or event_id(ev) > last_mut)
    end)
    |> Enum.map(&event_id/1)
  end

  # -- ref classification -----------------------------------------------------
  # Order: existence -> class -> same-turn (H2) -> ordering -> mutation-echo.
  # First violation wins; refs are walked in caller order.

  defp classify_ref(journal, by_offset, turn_id, last_mut, ref) do
    case Map.get(by_offset, ref) do
      nil ->
        {:error, {:missing_ref, ref}}

      ev ->
        cond do
          not evidence_class?(ev) ->
            {:error, {:not_evidence, ref}}

          event_turn_id(ev) != turn_id ->
            {:error, {:foreign_turn, ref}}

          last_mut != nil and event_id(ev) <= last_mut ->
            {:error, {:stale_evidence, ref}}

          mutation_echo?(journal, turn_id, ev, last_mut) ->
            {:error, {:mutation_echo, ref}}

          true ->
            :ok
        end
    end
  end

  # Offset of the turn's last mutating action, or nil if the turn mutated nothing.
  defp last_mutation(journal, turn_id) do
    journal
    |> Enum.filter(&(event_turn_id(&1) == turn_id and mutating?(&1)))
    |> Enum.map(&event_id/1)
    |> case do
      [] -> nil
      ids -> Enum.max(ids)
    end
  end

  # Evidence-class predicate: a tool result / verification output.
  defp evidence_class?(ev) do
    event_type(ev) == :item_completed and
      payload_field(ev, :item_type) == :tool_result
  end

  # Mutation predicate — FAIL-SAFE, derived at decision time from the event's
  # intrinsic type (§0 decision-time-fold law: ADMISSION gates fold truth
  # synchronously; a producer stamp is display/audit metadata, the fold is the
  # security boundary). Every completed `:tool_use` is a mutation: the real
  # producer (`Contract.pump/3`) stamps no effect metadata, and the frozen
  # effect taxonomy (§5.2) contains only effect-BEARING classes, so neither an
  # absent `effect_class` nor any self-reported flag (`mutating: false`, a
  # `destructiveHint`-style claim) may ever REMOVE a tool call from the
  # mutation set — a lying producer must not be able to widen the
  # valid-evidence window and launder stale evidence past a real mutation.
  #
  # (`:state_change` is deliberately NOT in the mutating set: it is an internal
  # transition, neither evidence nor mutation in the v0 loop vocabulary, and
  # the frozen Oracle/fold treats it the same way.)
  defp mutating?(ev) do
    event_type(ev) == :item_completed and
      payload_field(ev, :item_type) == :tool_use and
      not classified_effect_free?(ev)
  end

  # The one refinement seam: a tool call leaves the mutation set ONLY via a
  # structural, compiled-in-our-own-tree classification proving it effect-free
  # (the F2 `Raxol.Action` draft — see the moduledoc). No such class exists in
  # the frozen taxonomy today, so this is constantly false: unclassified and
  # unknown both resolve toward "is a mutation".
  defp classified_effect_free?(_ev), do: false

  # Check 5 — is this `:tool_result` the last mutation's own echo?
  #
  # A result is paired to its producing call by tool NAME + nearest-preceding
  # order within the claiming turn: the v0 producer emits each result
  # sequentially after its call and stamps `name` on both sides (it stamps no
  # `call_id` on results, so name+order is the only pairing signal in the
  # frozen shape). If the producing call IS the turn's last mutation, the ref
  # is that mutation's byproduct — it postdates the mutation trivially and
  # verifies nothing. An unpaired result (no named preceding call in the turn)
  # is not an echo.
  defp mutation_echo?(_journal, _turn_id, _ev, nil), do: false

  defp mutation_echo?(journal, turn_id, ev, last_mut) do
    name = tool_name(ev)
    offset = event_id(ev)

    name != nil and
      journal
      |> Enum.filter(fn cand ->
        event_turn_id(cand) == turn_id and mutating?(cand) and
          event_id(cand) < offset and tool_name(cand) == name
      end)
      |> Enum.map(&event_id/1)
      |> case do
        [] -> false
        ids -> Enum.max(ids) == last_mut
      end
  end

  # Tool names are free-form strings on the wire — read raw (never atomized)
  # and normalize atoms from synthetic fixtures to their string form.
  defp tool_name(ev) do
    case get_either(ev, :payload) do
      %{} = payload ->
        case get_either(payload, :name) do
          name when is_binary(name) -> name
          name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # -- accessors tolerant of both decoded and JSON-replayed journals ----------
  #
  # A journal that reaches the gate straight from `Contract.pump`/`EmitBridge`
  # is atom-keyed `%Event{}` structs. One replayed from disk via
  # `Raxol.Agent.Journal.FileStore.Reader` is `Jason.decode`d into string-keyed
  # maps — both the KEYS and the stringifiable enum VALUES (`type`, `item_type`,
  # `effect_class`) arrive as strings. No layer rehydrates those back to atoms
  # before the gate, so these accessors read either shape and normalize enum
  # values with `atomize/1`, keeping the gate's verdict identical on the live
  # and replayed forms of the same journal.

  defp event_id(ev), do: get_either(ev, :id)
  defp event_turn_id(ev), do: get_either(ev, :turn_id)
  defp event_session_id(ev), do: get_either(ev, :session_id)
  defp event_type(ev), do: atomize(get_either(ev, :type))

  defp payload_field(ev, key) do
    case get_either(ev, :payload) do
      %{} = payload -> atomize(get_either(payload, key))
      _ -> nil
    end
  end

  # Prefer the atom key; fall back to its string form for replayed journals.
  defp get_either(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> Map.get(map, Atom.to_string(key))
      value -> value
    end
  end

  defp get_either(_map, _key), do: nil

  # Normalize a possibly-stringified enum value to its atom form so the type
  # comparisons hold across live and replayed journals. `to_existing_atom`
  # never fabricates atoms (no memory-leak risk on decoded input): an unknown
  # string simply stays a string and fails the atom comparisons — the safe
  # default. Booleans/numbers pass through unchanged.
  defp atomize(value) when is_binary(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> value
  end

  defp atomize(value), do: value

  # The durable done event handed back to the journal. On append the Writer
  # stamps only `id` (= the real journal offset), overwriting the `next_id`
  # hint carried here; it does NOT re-stamp `session_id`, `ts`, or the envelope
  # (`Writer.stamp/3` puts `"id"`/`"schema_version"` and nothing else), so those
  # must be well-formed at hand-back.
  #
  # `session_id` is derived from the CLAIMING TURN's own events (they carry the
  # session) rather than `List.first/1` of the journal: the head may belong to
  # an interleaved foreign turn or a GC-dropped prefix, and on a string-keyed
  # replay it would not even carry an atom `:session_id` key.
  #
  # `ts` is a monotonic, offset-derived placeholder — the gate is a pure
  # decision function and reads no wall clock; a producer seam may set a real
  # timestamp when the accepted done is actually emitted.
  defp done_event(journal, turn_id, refs) do
    next_id =
      journal
      |> Enum.map(&event_id/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 0
        ids -> Enum.max(ids) + 1
      end

    session_id =
      journal
      |> Enum.find(&(event_turn_id(&1) == turn_id))
      |> then(&(&1 && event_session_id(&1)))

    %Event{
      v: 0,
      id: next_id,
      session_id: session_id,
      turn_id: turn_id,
      ts: next_id,
      family: :loop,
      type: :turn_completed,
      tier: :durable,
      payload: %{final: true, refs: refs, usage: %{}}
    }
  end
end
