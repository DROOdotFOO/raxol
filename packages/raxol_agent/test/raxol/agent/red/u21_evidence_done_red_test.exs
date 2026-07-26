# U21-R — evidence-gated-done suite (FI-6). Authored failing-first, now GREEN.
#
# Authored BEFORE the implementation existed, against the roadmap
# disposition (U21 + FI-6) and the freeze contracts' Event vocabulary, so
# the reds pin the contract instead of being fitted to it. U21 has since
# LANDED: `Raxol.Agent.DoneGate.gate/3` implements the gate, the
# `:harness_red` tag was removed, and these reds now run GREEN in CI
# against the real gate.
#
# ## What U21 gates
#
# An agent may not declare a turn done on its own say-so. The done transition
# (`turn_completed{final: true}`) is gated on journaled evidence — tool results
# / verification outputs — named by `refs` (journal offsets). Each ref must
# (1) exist, (2) be evidence-class (a tool result, never a `:message`
# self-report or an internal `:state_change`), (3) belong to the CLAIMING
# turn (H2 — a ref journaled under a different turn is `:foreign_turn`, even
# when its offset postdates this turn's last mutation: the cross-turn
# evidence spoof), (4) postdate the turn's last mutating action, and (5) not
# be that last mutation's own result echo. Stale evidence (predating a later
# mutation) does not count. A done with no refs is
# `{:error, :evidence_required}`; every reject leaves the turn open.
#
# ## What counts as a mutation (U21-R3, the fail-safe ruling)
#
# EVERY completed `:tool_use` is a mutation. The real producer
# (`Raxol.Agent.Contract.pump/3`) stamps no effect metadata on tool calls, and
# the frozen effect taxonomy (§5.2 of the frozen contract) contains only
# effect-BEARING classes and rules that effect enforcement is structural,
# never self-reported. So an absent `effect_class` resolves toward "is a
# mutation", and a stamped `mutating: false` (the `destructiveHint`-is-a-lie
# class) can never remove a call from the mutation set. The earlier suite
# semantics — trusting `mutating:`/`effect_class` stamps that no producer
# emits — were themselves the CRITICAL finding of review round 3: on every
# real journal `last_mutation` was nil and the staleness gate never fired.
#
# Evidence CLASS is validated, not its CONTENT (M1, explicit non-goal for
# U21 — see the `:evidence_content_not_validated` contour): a `:tool_result`
# that ran and reported failure still counts as evidence that a verification
# tool RAN.
#
# ## Label key (review cross-references)
#
# H1/H2, M1/M2, L1–L4 — finding ids from PR #570's adversarial review rounds
#   (severity High/Medium/Low + index), kept so each fix stays traceable to
#   the finding it closes. "U21-R2 #N" / "U21-R3" — fixes from review rounds
#   2 and 3 of the same PR.
# §0 / §5.2 — sections of the frozen contract (§0 clause 7 is the
#   decision-time-fold law; §5.2 the effect taxonomy).
# meta-inv N — the red-suite meta-invariants shared across the U-series
#   red suites.
# FI-6 — the roadmap future-invariant this unit implements (U21).
#
# ## Layout
#
#   * support modules (Build / Oracle / Injector.* / Contours / Gen / Fired) —
#     plain modules, compiled with the file, no elixirc_paths wiring;
#   * `...RedTest` (untagged since U21 landed, runs in CI) — the reds against
#     the real `DoneGate.gate/3`; now GREEN;
#   * `...ControlsTest` (UNtagged, runs in CI) — negative controls: each dead
#     injector must fail its targeted red, plus generator-coverage (meta-inv 5)
#     and fired-counters (meta-inv 1). The M2 CI tripwire that lived here was
#     removed when U21 landed (it asserted the reds were 0-passing).

# ---------------------------------------------------------------------------
# Support — journal builder (contract %Event{} at explicit offsets)
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Build do
  @moduledoc false
  alias Raxol.Agent.Contract.Event

  @session "sess-u21"

  @doc "A durable loop `%Event{}` at offset `id` (offset == journal id)."
  def ev(id, type, payload, opts \\ []) do
    %Event{
      v: 0,
      id: id,
      session_id: @session,
      turn_id: Keyword.get(opts, :turn_id, "t"),
      ts: id,
      family: Keyword.get(opts, :family, :loop),
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  def turn_started(id, opts \\ []),
    do: ev(id, :turn_started, %{prompt: "do the thing"}, opts)

  @doc "A mutating action (write/shell tool_use) — the thing evidence must postdate."
  def mutation(id, opts \\ []) do
    ev(
      id,
      :item_completed,
      %{
        item_type: :tool_use,
        mutating: true,
        name: Keyword.get(opts, :name, "fs_write"),
        effect_class: :reversible_local
      },
      opts
    )
  end

  @doc """
  A read-INTENDED tool_use, self-reporting `mutating: false`. Under the
  fail-safe ruling (U21-R3) it STILL counts as a mutation: the flag is a
  self-report, and no structural classification exists to prove the call
  effect-free — keeping the stamp here is what lets the suite pin that the
  gate ignores it.
  """
  def read_action(id, opts \\ []),
    do:
      ev(
        id,
        :item_completed,
        %{item_type: :tool_use, mutating: false, name: "fs_read"},
        opts
      )

  @doc """
  A tool_use in the REAL producer's shape (`Contract.pump/3`): no
  `effect_class`, no `mutating` flag — exactly the payload the fail-safe
  mutation default exists for.
  """
  def tool_call(id, opts \\ []) do
    ev(
      id,
      :item_completed,
      %{
        item_type: :tool_use,
        name: Keyword.get(opts, :name, "fs_write"),
        arguments: %{},
        call_id: "call-#{id}"
      },
      opts
    )
  end

  @doc """
  Evidence: a tool result / verification output (test run, file check).

  Default `name: "shell"` deliberately pairs with NO preceding tool_use in
  any contour journal, so the result reads as an independent verification
  output rather than some call's echo (echo pairing is by name +
  nearest-preceding order — see the mutation-echo contour for the paired
  case).
  """
  def evidence(id, opts \\ []) do
    ev(
      id,
      :item_completed,
      %{
        item_type: :tool_result,
        name: Keyword.get(opts, :name, "shell"),
        result: Keyword.get(opts, :result, "tests: 12 passed, 0 failed")
      },
      opts
    )
  end

  @doc "The agent's own say-so — a `:message` item. NOT evidence-class."
  def self_report(id, opts \\ []),
    do:
      ev(
        id,
        :item_completed,
        %{item_type: :message, content: "All done — everything works."},
        opts
      )

  @doc "An internal state transition. NOT evidence-class."
  def state_change(id, opts \\ []),
    do: ev(id, :state_change, %{from: :a, to: :b}, opts)

  @doc "Resolve a journal offset to its event, or nil."
  def resolve(journal, offset), do: Enum.find(journal, &(&1.id == offset))
end

# ---------------------------------------------------------------------------
# Support — the independent spec oracle (meta-inv 6: never consults DoneGate)
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Oracle do
  @moduledoc false
  alias Raxol.Agent.Red.U21.Build

  @doc "Evidence-class predicate: a tool result / verification output."
  def evidence_class?(%{type: :item_completed, payload: p}),
    do: Map.get(p, :item_type) == :tool_result

  def evidence_class?(_), do: false

  @doc """
  Mutation predicate — FAIL-SAFE (U21-R3): every completed `:tool_use` is a
  mutation. The real producer stamps no effect metadata, the frozen taxonomy
  (§5.2) has only effect-bearing classes, and a self-reported `mutating:`
  flag may never remove a call from the mutation set.
  """
  def mutating?(%{type: :item_completed, payload: p}),
    do: Map.get(p, :item_type) == :tool_use

  def mutating?(_), do: false

  @doc "Offset of the turn's last mutating action, or nil if the turn mutated nothing."
  def last_mutation(journal, turn_id) do
    journal
    |> Enum.filter(&(&1.turn_id == turn_id and mutating?(&1)))
    |> Enum.map(& &1.id)
    |> case do
      [] -> nil
      ids -> Enum.max(ids)
    end
  end

  @doc """
  The specification verdict a correct `DoneGate` must return. Reject reasons
  are checked existence -> class -> same-turn (H2) -> ordering, first
  violation wins, refs evaluated in list order.

  (L4) That last clause is an intentional evaluation contract, not an
  accident: `Contours.shape/1` compares the FULL reason tuple, including the
  offending offset, so when a claim cites multiple simultaneously-invalid
  refs, the spec pins WHICH one is reported (first-in-`refs`-order) rather
  than leaving it impl-defined (e.g. "worst severity" or "last checked"). A
  correct `DoneGate` must walk refs in the order the caller supplied them and
  report the first violation it hits — that's what makes "reject because ref
  X specifically" a debuggable, reproducible surface message instead of an
  arbitrary one.
  """
  def verdict(_journal, _turn_id, []), do: {:error, :evidence_required}

  def verdict(journal, turn_id, refs) do
    last_mut = last_mutation(journal, turn_id)

    Enum.reduce_while(refs, {:ok, refs}, fn ref, acc ->
      case classify_ref(journal, turn_id, last_mut, ref) do
        :ok -> {:cont, acc}
        err -> {:halt, err}
      end
    end)
  end

  @doc """
  Classify a single ref against the turn claiming it.

  H2: same-turn is checked BEFORE ordering. A ref from a foreign turn is
  rejected as `:foreign_turn` even when its offset happens to postdate this
  turn's last mutation — without that check first, a `:tool_result` journaled
  under turn A with a higher offset than turn B's last mutation would
  otherwise satisfy done for turn B (the cross-turn evidence spoof this
  check exists to close).
  """
  def classify_ref(journal, turn_id, last_mut, ref) do
    case Build.resolve(journal, ref) do
      nil ->
        {:error, {:missing_ref, ref}}

      ev ->
        cond do
          not evidence_class?(ev) ->
            {:error, {:not_evidence, ref}}

          ev.turn_id != turn_id ->
            {:error, {:foreign_turn, ref}}

          last_mut != nil and ev.id <= last_mut ->
            {:error, {:stale_evidence, ref}}

          mutation_echo?(journal, turn_id, ev, last_mut) ->
            {:error, {:mutation_echo, ref}}

          true ->
            :ok
        end
    end
  end

  @doc """
  Check 5 (U21-R3): a `:tool_result` produced BY the turn's last mutating
  call is that mutation's own echo — it postdates the mutation trivially and
  verifies nothing. Pairing is by tool name + nearest-preceding order within
  the turn (the only pairing signal in the frozen v0 producer shape); an
  unpaired result is not an echo.
  """
  def mutation_echo?(_journal, _turn_id, _ev, nil), do: false

  def mutation_echo?(journal, turn_id, ev, last_mut) do
    name = ev.payload[:name]

    producing_calls =
      journal
      |> Enum.filter(fn cand ->
        cand.turn_id == turn_id and mutating?(cand) and cand.id < ev.id and
          name != nil and cand.payload[:name] == name
      end)
      |> Enum.map(& &1.id)

    producing_calls != [] and Enum.max(producing_calls) == last_mut
  end
end

# ---------------------------------------------------------------------------
# Support — the correct reference + the three dead injectors
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Injector do
  @moduledoc false

  # Every injector fabricates its accepted-done event at offset 9_999 — a
  # sentinel comfortably beyond any contour or generated journal (max 8
  # records), so the fake done can never collide with a real offset.

  # A correct implementation — proves every contour is satisfiable and gives
  # the reds a target. NOT the production gate (`Raxol.Agent.DoneGate`, which
  # the RedTest drives directly).
  #
  # (M2 note) `Reference.gate/3` is a thin wrapper around `Oracle.verdict/3`,
  # so "Reference satisfies every contour" is tautological with respect to
  # Oracle's OWN logic — it can't prove Oracle is right on its own. What makes
  # the ControlsTest's positive-anchor check real independent teeth is that
  # `Contours.contours/0`'s `expected` shapes are hand-authored against the
  # spec (the moduledoc contract), not derived from Oracle's code; the other
  # independent teeth are the dead injectors below (plausible-but-wrong
  # `DoneGate` impls, proven via both the fixed contours and the generated
  # fold property to disagree with Oracle).
  defmodule Reference do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Red.U21.{Build, Oracle}

    @impl true
    def gate(journal, turn_id, refs) do
      case Oracle.verdict(journal, turn_id, refs) do
        {:ok, _} ->
          {:ok,
           Build.ev(
             9_999,
             :turn_completed,
             %{final: true, refs: refs, usage: %{}},
             turn_id: turn_id
           )}

        err ->
          err
      end
    end
  end

  # (a) accepts done without ever checking refs — must FAIL the evidence-required red.
  defmodule AcceptsWithoutRefs do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Red.U21.Build

    @impl true
    def gate(_journal, turn_id, refs),
      do: {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)}
  end

  # (b) checks existence + evidence-class but NOT ordering — must FAIL the stale-evidence red.
  defmodule ExistenceOnly do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Red.U21.{Build, Oracle}

    @impl true
    def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

    def gate(journal, turn_id, refs) do
      Enum.reduce_while(
        refs,
        {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)},
        fn ref, acc ->
          case Build.resolve(journal, ref) do
            nil ->
              {:halt, {:error, {:missing_ref, ref}}}

            ev ->
              if Oracle.evidence_class?(ev),
                do: {:cont, acc},
                else: {:halt, {:error, {:not_evidence, ref}}}
          end
        end
      )
    end
  end

  # (c) lets self-reported `:message` text count as evidence — must FAIL the evidence-class red.
  defmodule TextAsEvidence do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Red.U21.{Build, Oracle}

    @impl true
    def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

    def gate(journal, turn_id, refs) do
      last_mut = Oracle.last_mutation(journal, turn_id)

      Enum.reduce_while(
        refs,
        {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)},
        fn ref, acc ->
          case Build.resolve(journal, ref) do
            nil ->
              {:halt, {:error, {:missing_ref, ref}}}

            ev ->
              cond do
                not lenient_evidence?(ev) ->
                  {:halt, {:error, {:not_evidence, ref}}}

                last_mut != nil and ev.id <= last_mut ->
                  {:halt, {:error, {:stale_evidence, ref}}}

                true ->
                  {:cont, acc}
              end
          end
        end
      )
    end

    # The bug: a `:message` self-report is treated as evidence.
    defp lenient_evidence?(%{type: :item_completed, payload: p}),
      do: Map.get(p, :item_type) in [:tool_result, :message]

    defp lenient_evidence?(_), do: false
  end

  # (d) H2 — checks existence + evidence-class + ordering, but NOT that the
  # cited ref's own turn_id matches the claiming turn — must FAIL the new
  # foreign-turn red. `last_mutation/2` is still turn-scoped (it only counts
  # THIS turn's mutations), so the bug is narrower than "ignores turns
  # entirely": it fails to check that the CITED REF belongs to the turn
  # claiming it, which is exactly the cross-turn evidence spoof H2 closes.
  defmodule SkipsTurnCheck do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Red.U21.{Build, Oracle}

    @impl true
    def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

    def gate(journal, turn_id, refs) do
      last_mut = Oracle.last_mutation(journal, turn_id)

      Enum.reduce_while(
        refs,
        {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)},
        fn ref, acc ->
          case Build.resolve(journal, ref) do
            nil ->
              {:halt, {:error, {:missing_ref, ref}}}

            ev ->
              cond do
                not Oracle.evidence_class?(ev) ->
                  {:halt, {:error, {:not_evidence, ref}}}

                last_mut != nil and ev.id <= last_mut ->
                  {:halt, {:error, {:stale_evidence, ref}}}

                true ->
                  {:cont, acc}
              end
          end
        end
      )
    end
  end
end

# ---------------------------------------------------------------------------
# Support — contour fixtures + shape/outcome normalizers
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Contours do
  @moduledoc false
  alias Raxol.Agent.Red.U21.Build

  @doc """
  `{name, journal, turn_id, refs, expected_shape}`. Each is a hand-built,
  minimal journal exercising exactly one branch of the acceptance contract.
  """
  def contours do
    t = "t"

    [
      # done with valid postdating evidence -> accepted
      {:valid, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [3], :accept},
      # done with NO refs -> evidence_required, no done event
      {:evidence_required, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [],
       {:reject, :evidence_required}},
      # evidence PREDATES a later mutation -> stale
      {:stale, [Build.turn_started(1), Build.evidence(2), Build.mutation(3)], t, [2],
       {:reject, {:stale_evidence, 2}}},
      # ref points at an internal state_change -> not evidence-class
      {:not_evidence_state_change,
       [Build.turn_started(1), Build.mutation(2), Build.state_change(3)], t, [3],
       {:reject, {:not_evidence, 3}}},
      # ref points at the agent's own message text -> not evidence-class
      {:not_evidence_self_report,
       [Build.turn_started(1), Build.mutation(2), Build.self_report(3)], t, [3],
       {:reject, {:not_evidence, 3}}},
      # ref names an offset that does not exist
      {:missing_ref, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [99],
       {:reject, {:missing_ref, 99}}},
      # H2 — cross-turn evidence spoof: turn "t"'s last mutation is at offset
      # 2; a DIFFERENT turn ("other") starts afterward and journals its own
      # (legitimate, for ITS OWN turn) tool_result at offset 4 — an offset
      # that postdates turn "t"'s last mutation. A gate that checks class +
      # ordering but not ownership would accept this ref for turn "t"'s done.
      # It must not: the ref belongs to a foreign turn.
      {:foreign_turn,
       [
         Build.turn_started(1, turn_id: t),
         Build.mutation(2, turn_id: t),
         Build.turn_started(3, turn_id: "other"),
         Build.evidence(4, turn_id: "other")
       ], t, [4], {:reject, {:foreign_turn, 4}}},
      # M1 (non-goal pin) — evidence CLASS is validated (a :tool_result item
      # exists, is well-ordered, belongs to the turn), but its CONTENT is
      # not: a verification tool that ran and reported FAILURE still
      # satisfies the gate. This is an intentional U21 scope boundary — the
      # gate pins that a verification tool RAN and was journaled, not that
      # it passed. A future unit may add content gating (parsing pass/fail
      # out of the result payload).
      {:evidence_content_not_validated,
       [
         Build.turn_started(1),
         Build.mutation(2),
         Build.evidence(3, result: "tests: 0 passed, 12 FAILED")
       ], t, [3], :accept},
      # L3, INVERTED by the U21-R3 fail-safe ruling — a tool_use AFTER the
      # evidence gates it, even one self-reporting `mutating: false`: the flag
      # is a self-report and no structural classification exists to prove the
      # call effect-free, so the read-intended action at offset 4 counts as
      # the last mutation and the evidence at 3 goes stale. (Pre-R3 this
      # contour trusted the stamp and expected :accept — the exact
      # inoperative-staleness bug of the round-3 CRITICAL finding.)
      {:tool_use_after_evidence_gates,
       [
         Build.turn_started(1),
         Build.mutation(2),
         Build.evidence(3),
         Build.read_action(4)
       ], t, [3], {:reject, {:stale_evidence, 3}}},
      # U21-R3 — the mutation-echo spoof: the cited result at offset 3 is the
      # OWN echo of the last mutating call at offset 2 (paired by name +
      # nearest-preceding order). It postdates the mutation trivially and
      # verifies nothing; a gate checking only class + ordering would accept
      # the byproduct of the very action that needs verifying.
      {:mutation_echo,
       [
         Build.turn_started(1),
         Build.tool_call(2, name: "fs_write"),
         Build.evidence(3, name: "fs_write", result: "wrote 42 bytes")
       ], t, [3], {:reject, {:mutation_echo, 3}}}
    ]
  end

  def by_name(name),
    do: Enum.find(contours(), fn {n, _, _, _, _} -> n == name end)

  @doc "Collapse a verdict to its accept/reject shape for equality across impls."
  def shape({:ok, _}), do: :accept
  def shape({:error, reason}), do: {:reject, reason}

  @doc "Collapse a verdict to its outcome CLASS (for generator-coverage assertions)."
  def outcome_class({:ok, _}), do: :accept
  def outcome_class({:error, :evidence_required}), do: :evidence_required
  def outcome_class({:error, {:stale_evidence, _}}), do: :stale_evidence
  def outcome_class({:error, {:not_evidence, _}}), do: :not_evidence
  def outcome_class({:error, {:missing_ref, _}}), do: :missing_ref
  def outcome_class({:error, {:foreign_turn, _}}), do: :foreign_turn
  def outcome_class({:error, {:mutation_echo, _}}), do: :mutation_echo
end

# ---------------------------------------------------------------------------
# Support — seed-reproducible journal generator (StreamData)
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Gen do
  @moduledoc false
  alias Raxol.Agent.Red.U21.Build

  # H1/L1 — determinism contract for `sample/1`: same `n` -> byte-identical
  # output, every run, any process, with the `n` samples still diverse.
  #
  # Both are needed at once, which is why each sample index gets its OWN
  # deterministic seed (`@seed + index`) through `StreamData.__call__/3`
  # (the public entry point `seeded/2` and the property engine build on).
  # Enumerating a generator through the `Enumerable` protocol reseeds from
  # the wall clock (non-reproducible), and one shared seed for a whole take
  # collapses every element onto a single branch because our fixed-length
  # `one_of`/`member_of` choices don't consult StreamData's growing `size`
  # parameter (no diversity). Per-index seeding is the only combination that
  # provides both.
  #
  # The value is arbitrary (a date typed as hex); only its FIXEDNESS matters.
  @seed 0x51212026

  def steps_gen do
    StreamData.list_of(
      StreamData.member_of([
        :mutation,
        :read,
        :evidence,
        :self_report,
        :state_change,
        :foreign_evidence
      ]),
      min_length: 1,
      max_length: 7
    )
  end

  @doc "Generates `{journal, turn_id, refs}` triples over the contract vocabulary."
  def journal_and_refs_gen do
    StreamData.bind(steps_gen(), fn steps ->
      journal = build_journal(steps)
      offsets = Enum.map(journal, & &1.id)
      # 999 is guaranteed absent -> exercises the missing-ref branch.
      candidates = offsets ++ [999]

      # H2 — split evidence offsets by ownership: turn "t"'s own evidence
      # (may or may not be stale) vs. a DIFFERENT turn's evidence (`:foreign_evidence`
      # steps, always turn_id "other") that a buggy gate might accept anyway
      # if it checks ordering/class but not ownership.
      own_evidence_offsets =
        journal
        |> Enum.filter(&(&1.payload[:item_type] == :tool_result and &1.turn_id == "t"))
        |> Enum.map(& &1.id)

      foreign_evidence_offsets =
        journal
        |> Enum.filter(&(&1.payload[:item_type] == :tool_result and &1.turn_id != "t"))
        |> Enum.map(& &1.id)

      refs_gen =
        StreamData.one_of([
          StreamData.constant([]),
          StreamData.list_of(StreamData.member_of(candidates), max_length: 4),
          # cite every own-turn evidence offset — the branch that RELIABLY
          # surfaces the stale-evidence ordering (an evidence offset before a
          # later mutation), keeping the stale red non-vacuous (meta-inv 5).
          StreamData.constant(own_evidence_offsets),
          # cite every foreign-turn evidence offset — the branch that
          # RELIABLY surfaces the cross-turn spoof (H2), keeping the
          # foreign-turn red non-vacuous.
          StreamData.constant(foreign_evidence_offsets)
        ])

      StreamData.bind(refs_gen, fn refs ->
        StreamData.constant({journal, "t", refs})
      end)
    end)
  end

  @doc """
  Deterministic sample of `n` triples (H1: really seed-fixed — see the
  `@seed` comment). Each of the `n` triples gets its OWN deterministic seed
  (`@seed + index`), so the sample is both reproducible (same `n` -> same
  output, any process, any run) and diverse (distinct triples, not one
  branch choice repeated `n` times).
  """
  def sample(n) do
    gen = journal_and_refs_gen()

    for i <- 0..(n - 1) do
      seed = :rand.seed_s(:exsss, {0, 0, @seed + i})
      # `StreamData.__call__/3` (public despite `@doc false`, the same
      # primitive `seeded/2` and the property-check engine build on) returns
      # a `%StreamData.LazyTree{root: value, ...}` — we only want the root
      # value, not the shrink tree.
      %StreamData.LazyTree{root: value} = StreamData.__call__(gen, seed, 50)
      value
    end
  end

  defp build_journal(steps) do
    first = Build.turn_started(1, turn_id: "t")

    rest =
      steps
      |> Enum.with_index(2)
      |> Enum.map(fn {step, off} -> build_step(step, off) end)

    [first | rest]
  end

  defp build_step(:mutation, off), do: Build.mutation(off, turn_id: "t")
  defp build_step(:read, off), do: Build.read_action(off, turn_id: "t")
  defp build_step(:evidence, off), do: Build.evidence(off, turn_id: "t")
  defp build_step(:self_report, off), do: Build.self_report(off, turn_id: "t")
  # H2 — evidence journaled under a DIFFERENT (foreign) turn, interleaved
  # into the same session journal, as real concurrent-turn journals would be.
  defp build_step(:foreign_evidence, off),
    do: Build.evidence(off, turn_id: "other")

  defp build_step(:state_change, off), do: Build.state_change(off)
end

# ---------------------------------------------------------------------------
# Support — fired counters (meta-inv 1: an armed-but-never-fired site fails)
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Fired do
  @moduledoc false

  def new do
    {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
    pid
  end

  def arm(pid, site) do
    Agent.update(pid, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    pid
  end

  def fire(pid, site),
    do:
      Agent.update(pid, fn s ->
        %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
      end)

  def assert_all_fired!(pid) do
    %{armed: armed, fired: fired} = Agent.get(pid, & &1)
    dead = Enum.filter(armed, &(Map.get(fired, &1, 0) == 0))

    if dead != [] do
      raise ExUnit.AssertionError,
        message:
          "dead injector(s): armed site(s) never fired: #{inspect(dead)}; fired: #{inspect(fired)}"
    end

    fired
  end
end

# ===========================================================================
# THE REDS — against the real DoneGate gate. Formerly `:harness_red` (excluded
# in test_helper) and RED against the skeleton; U21 has landed, so the tag is
# removed and these run GREEN in CI.
# ===========================================================================
defmodule Raxol.Agent.Red.U21EvidenceDoneRedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # U21 has LANDED: `Raxol.Agent.DoneGate.gate/3` is implemented, so these reds
  # now pass GREEN and run in CI (the `:harness_red` moduletag that excluded
  # them was removed). The M2 CI tripwire that asserted "reds are 0-passing"
  # was deleted for the same reason — see the note in the ControlsTest.

  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.Red.U21.{Build, Contours, Gen, Oracle}

  # Route every gate call through apply/3 so the compiler keeps the return
  # type DYNAMIC: the suite must stay compilable against ANY gate
  # implementation (including a stub whose literal return type would
  # otherwise let the type system flag `{:ok, _}` matches as dead clauses
  # under --warnings-as-errors).
  defp gate(journal, turn, refs),
    do: apply(DoneGate, :gate, [journal, turn, refs])

  describe "positive contours — accepted claims hand back turn_completed{final: true}" do
    # :valid is the base postdating-evidence accept; :evidence_content_not_validated
    # (M1) is also accept-shaped — looped here rather than hand-duplicated so
    # every accept contour gets the identical assertion set.
    for name <- [:valid, :evidence_content_not_validated] do
      test "accept: #{name} — the gate hands back a turn_completed{final: true} carrying its evidence refs" do
        {_, journal, turn, refs, _} = Contours.by_name(unquote(name))

        assert {:ok, done} = gate(journal, turn, refs)
        assert done.type == :turn_completed
        assert done.payload.final == true
        assert done.payload.refs == refs
        assert done.turn_id == turn
      end
    end
  end

  describe "negative contours — claim-without-evidence never transitions to done" do
    # L2: filtered on the expected SHAPE (reject-tuples), not by excluding a
    # name — new accept-shaped contours (M1, L3) don't have to be remembered
    # here individually as the positive list above grows.
    for {name, _j, _t, _r, expected} <- Raxol.Agent.Red.U21.Contours.contours(),
        match?({:reject, _}, expected) do
      # L2: renamed from "...turn stays open" — DoneGate.gate/3 is a pure
      # function over a journal, not a stateful turn process, so this test
      # doesn't (and can't) observe turn state; what it actually asserts is
      # that no turn_completed{final: true} event is produced for a rejected
      # claim. The old `refute match?({:ok, _}, verdict)` line below was
      # dropped: `Contours.shape/1` has exactly two clauses ({:ok, _} -> :accept,
      # {:error, _} -> {:reject, _}), so asserting the shape equals a
      # {:reject, _} tuple already implies verdict does not match {:ok, _} —
      # the refute was a redundant restatement of the assert above it.
      test "reject: #{name} -> #{inspect(expected)}; no turn_completed{final: true} is produced" do
        {_, journal, turn, refs, _expected} = Contours.by_name(unquote(name))

        verdict = gate(journal, turn, refs)
        assert Contours.shape(verdict) == unquote(Macro.escape(expected))
      end
    end
  end

  describe "the fold property — every accepted done cites resolvable, evidence-class, postdating refs" do
    property "gate agrees with the evidence spec on every generated journal" do
      # The generator MUST include the stale-evidence ordering, or the property
      # is vacuous; the ControlsTest coverage guard enforces that separately.
      check all(
              {journal, turn, refs} <- Gen.journal_and_refs_gen(),
              max_runs: 200
            ) do
        assert Contours.shape(gate(journal, turn, refs)) ==
                 Contours.shape(Oracle.verdict(journal, turn, refs))
      end
    end
  end

  # ===========================================================================
  # U21-R2 review-fix regressions (PR #570). Each test pins exactly one fixed
  # arm from the review, against the real DoneGate.
  # ===========================================================================
  describe "U21-R2 #1 — a nil claiming turn is structurally rejected (:unturned_done)" do
    test "a nil-turn done citing nil-turn evidence is rejected (nil==nil must not satisfy same-turn)" do
      # Evidence journaled under a nil turn; the done also claims turn_id nil.
      # The old value-equality same-turn check (`nil == nil` is false for `!=`)
      # would let this pass, collapsing cross-turn isolation for any nil-turn
      # claim. It must reject structurally instead.
      journal = [
        Build.turn_started(1, turn_id: nil),
        Build.mutation(2, turn_id: nil),
        Build.evidence(3, turn_id: nil)
      ]

      assert gate(journal, nil, [3]) == {:error, :unturned_done}
    end

    test "a nil-turn done is :unturned_done even with no refs (checked before evidence)" do
      assert gate([Build.turn_started(1, turn_id: nil)], nil, []) ==
               {:error, :unturned_done}
    end
  end

  describe "U21-R2 #2 — mutating-ness is derived from type, never from stamped flags" do
    test "an effect-bearing tool_use with `mutating: false` still counts as a mutation" do
      # A state-affecting tool call whose producer self-reports `mutating:
      # false`. If the gate trusted the stamped flag, this would not count as
      # a mutation, `last_mutation` would be nil, and the pre-mutation
      # evidence at offset 2 would wrongly satisfy the done. Under the
      # fail-safe default (every tool_use is a mutation) offset 3 gates, so
      # the evidence that predates it is stale.
      spoofed_mutation =
        Build.ev(
          3,
          :item_completed,
          %{
            item_type: :tool_use,
            mutating: false,
            effect_class: :reversible_local,
            name: "fs_write"
          },
          turn_id: "t"
        )

      journal = [Build.turn_started(1), Build.evidence(2), spoofed_mutation]

      assert gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end

    test "an effect-bearing tool_use with NO `mutating` flag at all still counts as a mutation" do
      unflagged_mutation =
        Build.ev(
          3,
          :item_completed,
          %{
            item_type: :tool_use,
            effect_class: :reversible_local,
            name: "fs_write"
          },
          turn_id: "t"
        )

      journal = [Build.turn_started(1), Build.evidence(2), unflagged_mutation]

      assert gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end
  end

  describe "U21-R2 #3 — accessors tolerate JSON-replayed (string-keyed) journals" do
    test "every contour gates identically whether atom-keyed or JSON-replayed (string-keyed)" do
      # `FileStore.Reader` replays a journal as `Jason.decode`d string-keyed
      # maps (string keys AND string enum values). Round-trip each contour
      # journal through Jason exactly as the Reader would and assert the gate's
      # verdict is unchanged — the string-keyed form must not silently pass
      # (nil accessors) or diverge from the atom-keyed form on any branch.
      for {name, journal, turn, refs, _expected} <- Contours.contours() do
        replayed =
          Enum.map(journal, fn e -> e |> Jason.encode!() |> Jason.decode!() end)

        assert Contours.shape(gate(replayed, turn, refs)) ==
                 Contours.shape(gate(journal, turn, refs)),
               "string-keyed journal diverged from atom-keyed on the #{name} contour"
      end
    end
  end

  describe "U21-R2 #4 — the done's session_id derives from the claiming turn, not the journal head" do
    test "an accepted done carries the claiming turn's session, not List.first's" do
      # The journal head is a foreign turn under a DIFFERENT session_id (as an
      # interleaved concurrent turn or a GC-dropped prefix would leave it). The
      # Writer does not re-stamp session_id at append, so the emitted done must
      # already carry the CLAIMING turn's session — not the head's.
      head = %{
        Build.turn_started(1, turn_id: "other")
        | session_id: "sess-OTHER"
      }

      journal = [
        head,
        Build.turn_started(2, turn_id: "t"),
        Build.mutation(3, turn_id: "t"),
        Build.evidence(4, turn_id: "t")
      ]

      assert {:ok, done} = gate(journal, "t", [4])
      assert done.session_id == "sess-u21"
      refute done.session_id == "sess-OTHER"
    end
  end
end

# ===========================================================================
# NEGATIVE CONTROLS — run in CI (untagged). Prove the reds are non-vacuous:
# the correct reference passes every contour, and each dead injector fails
# exactly its targeted red. Plus generator coverage (meta-inv 5) and
# fired-counters (meta-inv 1).
# ===========================================================================
defmodule Raxol.Agent.Red.U21EvidenceDoneControlsTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.Red.U21.{Build, Contours, Gen, Injector, Oracle, Fired}

  # Route the real gate through apply/3 (same reason as the RedTest helper):
  # keep the return type dynamic so {:ok, _} matches never narrow to dead code.
  defp real_gate(journal, turn, refs),
    do: apply(DoneGate, :gate, [journal, turn, refs])

  describe "positive anchor — the contours are satisfiable" do
    test "a correct reference implementation satisfies every contour" do
      for {name, journal, turn, refs, expected} <- Contours.contours() do
        assert Contours.shape(Injector.Reference.gate(journal, turn, refs)) ==
                 expected,
               "reference failed the #{name} contour"
      end
    end
  end

  describe "dead injectors — each must fail its targeted red (meta-inv 4)" do
    test "every dead injector fails exactly its targeted contour, and every armed site fires (meta-inv 1)" do
      fired = Fired.new()

      for site <- [
            :accepts_without_refs,
            :existence_only,
            :text_as_evidence,
            :skips_turn_check
          ],
          do: Fired.arm(fired, site)

      # (a) accepts-without-refs must fail the evidence-required red.
      {_, j_a, t_a, r_a, exp_a} = Contours.by_name(:evidence_required)

      refute Contours.shape(Injector.AcceptsWithoutRefs.gate(j_a, t_a, r_a)) ==
               exp_a,
             "AcceptsWithoutRefs should NOT satisfy the evidence-required red"

      Fired.fire(fired, :accepts_without_refs)

      # (b) existence-only must fail the stale-evidence red.
      {_, j_b, t_b, r_b, exp_b} = Contours.by_name(:stale)

      refute Contours.shape(Injector.ExistenceOnly.gate(j_b, t_b, r_b)) == exp_b,
             "ExistenceOnly should NOT satisfy the stale-evidence red"

      Fired.fire(fired, :existence_only)

      # (c) text-as-evidence must fail the evidence-class red (self-report ref).
      {_, j_c, t_c, r_c, exp_c} = Contours.by_name(:not_evidence_self_report)

      refute Contours.shape(Injector.TextAsEvidence.gate(j_c, t_c, r_c)) ==
               exp_c,
             "TextAsEvidence should NOT satisfy the evidence-class red"

      Fired.fire(fired, :text_as_evidence)

      # (d) H2 — skips-turn-check must fail the new foreign-turn red.
      {_, j_d, t_d, r_d, exp_d} = Contours.by_name(:foreign_turn)

      refute Contours.shape(Injector.SkipsTurnCheck.gate(j_d, t_d, r_d)) ==
               exp_d,
             "SkipsTurnCheck should NOT satisfy the foreign-turn red"

      Fired.fire(fired, :skips_turn_check)

      Fired.assert_all_fired!(fired)
    end

    test "the fold property is non-vacuous: each dead injector disagrees with the spec on >= 1 generated journal" do
      for {name, mod} <- [
            {:accepts_without_refs, Injector.AcceptsWithoutRefs},
            {:existence_only, Injector.ExistenceOnly},
            {:text_as_evidence, Injector.TextAsEvidence},
            {:skips_turn_check, Injector.SkipsTurnCheck}
          ] do
        disagreements =
          Gen.sample(300)
          |> Enum.count(fn {j, t, r} ->
            Contours.shape(mod.gate(j, t, r)) !=
              Contours.shape(Oracle.verdict(j, t, r))
          end)

        assert disagreements > 0, "the fold property would never catch #{name}"
      end
    end
  end

  describe "generator coverage (meta-inv 5) — the reds are not vacuous" do
    test "the generator exercises every outcome class, INCLUDING cited stale AND foreign-turn evidence" do
      # H1: Gen.sample/1 is now REALLY seed-fixed (StreamData.seeded/2), so
      # this coverage set is identical every run — a class missing here is a
      # deterministic, reproducible failure, not a flaky one.
      classes =
        Gen.sample(400)
        |> Enum.map(fn {j, t, r} ->
          Contours.outcome_class(Oracle.verdict(j, t, r))
        end)
        |> Enum.frequencies()

      assert Map.get(classes, :accept, 0) > 0,
             "no accept case generated (#{inspect(classes)})"

      assert Map.get(classes, :evidence_required, 0) > 0,
             "no evidence-required case (#{inspect(classes)})"

      assert Map.get(classes, :stale_evidence, 0) > 0,
             "generator never cited stale evidence — the stale red is vacuous (#{inspect(classes)})"

      assert Map.get(classes, :not_evidence, 0) > 0,
             "no not-evidence case (#{inspect(classes)})"

      assert Map.get(classes, :missing_ref, 0) > 0,
             "no missing-ref case (#{inspect(classes)})"

      assert Map.get(classes, :foreign_turn, 0) > 0,
             "generator never cited foreign-turn evidence — the H2 cross-turn-spoof red is vacuous (#{inspect(classes)})"
    end
  end

  # ===========================================================================
  # U21-R2 #5 — mutation-classification boundary anchor (impl-independent).
  #
  # The fold property compares the gate against `Oracle.verdict/3`, but the
  # Oracle re-implements the gate's `mutating?`/`evidence_class?` predicates —
  # so a wrong-but-CONSISTENT change to the mutation boundary moves both sides
  # together and stays invisible to the fold property AND every injector. This
  # control pins the boundary against HAND-AUTHORED literal verdicts (derived
  # from neither predicate): if the gate's notion of "what is a mutation"
  # drifts, this fails even where the coupled fold property cannot see it.
  # ===========================================================================
  describe "U21-R2 #5 / U21-R3 — mutation-classification boundary (hand-authored literals)" do
    test "an effect-bearing tool_use with `mutating: false` counts as a mutation" do
      # Literal: evidence at offset 2 precedes an effect-bearing tool_use at
      # offset 3 whose producer stamped `mutating: false`. Independent of any
      # predicate, offset 3 IS a mutation, so citing the pre-mutation evidence
      # must yield exactly {:error, {:stale_evidence, 2}}.
      effect_bearing_write =
        Build.ev(
          3,
          :item_completed,
          %{
            item_type: :tool_use,
            mutating: false,
            effect_class: :reversible_local
          },
          turn_id: "t"
        )

      journal = [Build.turn_started(1), Build.evidence(2), effect_bearing_write]

      assert real_gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end

    test "a bare tool_use (no effect_class, no flag — the REAL producer shape) IS a mutation" do
      # Literal for the round-3 CRITICAL: `Contract.pump/3` emits tool_use as
      # %{item_type: :tool_use, name, arguments, call_id} — no effect_class,
      # no mutating flag. A gate that only recognizes stamped mutations sees
      # `last_mutation` nil on every real journal and its staleness check
      # never fires. Fail-safe: the bare call at offset 3 IS a mutation, so
      # the evidence at offset 2 that predates it is stale.
      journal = [
        Build.turn_started(1),
        Build.evidence(2),
        Build.tool_call(3, name: "fs_write")
      ]

      assert real_gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end

    test "a read-INTENDED tool_use self-reporting `mutating: false` still gates later evidence" do
      # Literal for the inverted L3: a real mutation at 2, evidence at 3, then
      # a tool_use at 4 stamped `mutating: false`. The stamp is a self-report
      # (the `destructiveHint`-is-a-lie class, §5.2) and may never remove the
      # call from the mutation set — so offset 4 gates, and the evidence at 3
      # goes stale.
      journal = [
        Build.turn_started(1),
        Build.mutation(2),
        Build.evidence(3),
        Build.read_action(4)
      ]

      assert real_gate(journal, "t", [3]) == {:error, {:stale_evidence, 3}}
    end

    test "the last mutation's own result echo is not evidence (mutation_echo)" do
      # Literal for the round-3 HIGH: every tool call emits a tool_result at a
      # later offset than its tool_use, so the echo of the last mutation
      # always class-passes and postdates it — citing it would let a done be
      # green-lit by the byproduct of the very action needing verification.
      journal = [
        Build.turn_started(1),
        Build.tool_call(2, name: "fs_write"),
        Build.evidence(3, name: "fs_write", result: "wrote 42 bytes")
      ]

      assert real_gate(journal, "t", [3]) == {:error, {:mutation_echo, 3}}
    end
  end
end

# ===========================================================================
# U21-R3 — regressions built from the REAL producer (`Contract.pump/3`), not
# the synthetic Build helpers. Round 3's CRITICAL finding was exactly that the
# suite was green only on synthetic journals whose payloads carried fields
# production never stamps — these tests journal a run through the real
# producer and gate THAT.
# ===========================================================================
defmodule Raxol.Agent.Red.U21RealProducerRegressionTest do
  # async: false — SessionStreamer is a named singleton.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.SessionStreamer

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  # Drew's round-3 failure scenario, produced for real: run tests (pass), THEN
  # edit code, then try to cite the pre-edit test run as evidence.
  #
  # Journal produced (all durable; every item carries its item_started
  # sibling): 1 turn_started, 2/3 tool_use(run_tests), 4/5
  # tool_result(run_tests), 6/7 tool_use(fs_write), 8/9
  # tool_result(fs_write), 10/11 message, 12 turn_completed{final: true}.
  defp real_journal do
    session_id = "u21-real-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    stream = [
      {:tool_use, %{name: "run_tests", id: "call-1", arguments: %{}}},
      {:tool_result, %{name: "run_tests", result: "tests: 12 passed, 0 failed"}},
      {:tool_use, %{name: "fs_write", id: "call-2", arguments: %{path: "lib/a.ex"}}},
      {:tool_result, %{name: "fs_write", result: "wrote 42 bytes"}},
      {:done, %{content: "All fixed.", usage: %{}}}
    ]

    {:ok, _} = Contract.pump(session_id, stream, prompt: "fix the bug")

    journal = drain_events(session_id)
    [%Event{turn_id: turn_id} | _] = journal
    {journal, turn_id}
  end

  test "the real producer stamps neither effect_class nor mutating on tool_use (regression premise)" do
    # If this ever fails, the producer grew effect stamping and the fail-safe
    # default below must be re-derived against the new shape.
    {journal, _turn} = real_journal()

    tool_uses = Enum.filter(journal, &(&1.payload[:item_type] == :tool_use))
    assert tool_uses != []

    for %Event{payload: payload} <- tool_uses do
      refute Map.has_key?(payload, :effect_class)
      refute Map.has_key?(payload, :mutating)
    end
  end

  test "stale evidence predating a real (unstamped) tool_use mutation is rejected" do
    # Pre-fix, `last_mutation` was nil on this journal (no stamped fields), so
    # the pre-edit test run at offset 5 wrongly satisfied the done.
    {journal, turn} = real_journal()

    assert DoneGate.gate(journal, turn, [5]) == {:error, {:stale_evidence, 5}}
  end

  test "the last mutation's own echo in a real journal cannot green-light the done" do
    # Offset 9 is fs_write's own tool_result — it postdates the mutation at 7
    # trivially and verifies nothing.
    {journal, turn} = real_journal()

    assert DoneGate.gate(journal, turn, [9]) == {:error, {:mutation_echo, 9}}
  end

  test "fail-closed: no offset in a real v0 journal is acceptable evidence" do
    # Intentional (see the DoneGate moduledoc "Wiring status"): with no
    # structural effect classification in the frozen producer shape, every
    # tool call gates and every result is some call's echo — the gate accepts
    # nothing until F2/U8 land a verification class. This pins that the gate
    # fails CLOSED on real journals rather than silently open (the round-3
    # CRITICAL failure mode).
    {journal, turn} = real_journal()

    for %Event{id: offset} <- journal do
      refute match?({:ok, _}, DoneGate.gate(journal, turn, [offset]))
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{tier: :durable} = event} ->
        drain_events(session_id, [event | acc])

      {:session_event, ^session_id, %Event{}} ->
        drain_events(session_id, acc)
    after
      100 -> Enum.reverse(acc)
    end
  end
end
