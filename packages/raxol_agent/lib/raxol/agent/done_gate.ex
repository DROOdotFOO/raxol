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
       not count, else `{:error, {:stale_evidence, offset}}`.

  A done carrying no refs at all is `{:error, :evidence_required}`. Only when
  every ref satisfies (1)-(4) does the gate accept and hand back the durable
  `turn_completed{final: true, refs: [...]}` event for journaling — so a surface
  can render "done because X".

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
    last_mut = last_mutation(journal, turn_id)

    Enum.reduce_while(refs, {:ok, refs}, fn ref, acc ->
      case classify_ref(journal, turn_id, last_mut, ref) do
        :ok -> {:cont, acc}
        err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, _refs} -> {:ok, done_event(journal, turn_id, refs)}
      {:error, _} = err -> err
    end
  end

  # -- ref classification (existence -> class -> same-turn (H2) -> ordering) --

  defp classify_ref(journal, turn_id, last_mut, ref) do
    case resolve(journal, ref) do
      nil ->
        {:error, {:missing_ref, ref}}

      ev ->
        cond do
          not evidence_class?(ev) -> {:error, {:not_evidence, ref}}
          event_turn_id(ev) != turn_id -> {:error, {:foreign_turn, ref}}
          last_mut != nil and event_id(ev) <= last_mut -> {:error, {:stale_evidence, ref}}
          true -> :ok
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
    event_type(ev) == :item_completed and payload_field(ev, :item_type) == :tool_result
  end

  # Mutation predicate — DERIVED at decision time from the event's intrinsic
  # type + effect classification, never from a producer-stamped `mutating:`
  # boolean (§0 decision-time-fold law: ADMISSION gates fold truth
  # synchronously; the stamp is display/audit metadata, the fold is the
  # security boundary). A state-affecting action is an `:item_completed`
  # `:tool_use` that carries an `effect_class` — the tool's intrinsic effect
  # classification. Deriving mutating-ness from that classification, rather than
  # trusting a `mutating: false` self-report, is what stops a producer from
  # WIDENING the valid-evidence window to launder stale evidence past a real
  # mutation.
  #
  # The boolean flag survives ONLY as a fail-safe NARROWING tiebreak: an
  # explicit `mutating: true` also counts (shrinking the evidence window toward
  # safety), but a `false`/absent flag can never REMOVE an effect-bearing action
  # from the mutation set — ambiguity resolves toward "is a mutation".
  #
  # (`:state_change` is deliberately NOT in the mutating set: it is an internal
  # transition carrying no effect_class, is neither evidence nor mutation in the
  # v0 loop vocabulary, and the frozen Oracle/fold treats it the same way.)
  defp mutating?(ev) do
    event_type(ev) == :item_completed and
      payload_field(ev, :item_type) == :tool_use and
      (effect_bearing?(ev) or payload_field(ev, :mutating) == true)
  end

  defp effect_bearing?(ev), do: payload_field(ev, :effect_class) != nil

  defp resolve(journal, offset), do: Enum.find(journal, &(event_id(&1) == offset))

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

  # The durable done event handed back to the journal. `id`/`ts` are assigned by
  # the journal writer at append time; this carries the next-offset hint from the
  # journal tail so the event is well-formed even before it lands.
  defp done_event(journal, turn_id, refs) do
    next_id =
      journal
      |> Enum.map(&event_id/1)
      |> Enum.reject(&is_nil/1)
      |> case do
        [] -> 0
        ids -> Enum.max(ids) + 1
      end

    session_id = journal |> List.first() |> then(&(&1 && Map.get(&1, :session_id)))

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
