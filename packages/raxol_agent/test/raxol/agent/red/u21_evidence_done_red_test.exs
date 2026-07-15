# U21-R — permanent failing-first suite for "Evidence-gated done" (FI-6).
#
# Authored BEFORE the implementation exists, against the roadmap disposition
# (docs/proposals/in-flight/harness-roadmap.md §U21 + FI-6) and the freeze
# contracts' Event vocabulary. The gate under test is the
# `Raxol.Agent.DoneGate` skeleton (`:not_implemented`); every red here fails
# until U21 lands, so the reds pin the contract instead of being fitted to it.
#
# Part of the red-first fan-out authored against docs PR #569.
#
# ## What U21 gates
#
# An agent may not declare a turn done on its own say-so. The done transition
# (`turn_completed{final: true}`) is gated on journaled evidence — tool results
# / verification outputs — named by `refs` (journal offsets). Each ref must
# (1) exist, (2) be evidence-class (a tool result, never a `:message`
# self-report or an internal `:state_change`), and (3) postdate the turn's last
# mutating action. Stale evidence (predating a later mutation) does not count.
# A done with no refs is `{:error, :evidence_required}`; every reject leaves the
# turn open.
#
# ## Layout
#
#   * support modules (Build / Oracle / Injector.* / Contours / Gen / Fired) —
#     plain modules, compiled with the file, no elixirc_paths wiring;
#   * `...RedTest` (`@moduletag :harness_red`, EXCLUDED in test_helper) — the
#     permanent reds against the real `DoneGate` skeleton; RED until U21;
#   * `...ControlsTest` (UNtagged, runs in CI) — negative controls: each dead
#     injector must fail its targeted red, plus generator-coverage (meta-inv 5)
#     and fired-counters (meta-inv 1).

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

  @doc "A read-only tool_use — NOT a mutation (must not gate the evidence window)."
  def read_action(id, opts \\ []),
    do: ev(id, :item_completed, %{item_type: :tool_use, mutating: false, name: "fs_read"}, opts)

  @doc "Evidence: a tool result / verification output (test run, file check)."
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
    do: ev(id, :item_completed, %{item_type: :message, content: "All done — everything works."}, opts)

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

  @doc "Mutation predicate: a state-changing tool_use (write/shell)."
  def mutating?(%{type: :item_completed, payload: p}),
    do: Map.get(p, :item_type) == :tool_use and Map.get(p, :mutating) == true

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
  The specification verdict a correct `DoneGate` must return. Reject reasons are
  checked existence -> class -> ordering, first violation wins.
  """
  def verdict(_journal, _turn_id, []), do: {:error, :evidence_required}

  def verdict(journal, turn_id, refs) do
    last_mut = last_mutation(journal, turn_id)

    Enum.reduce_while(refs, {:ok, refs}, fn ref, acc ->
      case classify_ref(journal, last_mut, ref) do
        :ok -> {:cont, acc}
        err -> {:halt, err}
      end
    end)
  end

  def classify_ref(journal, last_mut, ref) do
    case Build.resolve(journal, ref) do
      nil ->
        {:error, {:missing_ref, ref}}

      ev ->
        cond do
          not evidence_class?(ev) -> {:error, {:not_evidence, ref}}
          last_mut != nil and ev.id <= last_mut -> {:error, {:stale_evidence, ref}}
          true -> :ok
        end
    end
  end
end

# ---------------------------------------------------------------------------
# Support — the correct reference + the three dead injectors
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Injector do
  @moduledoc false

  # A correct implementation — proves every contour is satisfiable and gives
  # the reds a target. NOT the production gate (which stays :not_implemented).
  defmodule Reference do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Red.U21.{Build, Oracle}

    @impl true
    def gate(journal, turn_id, refs) do
      case Oracle.verdict(journal, turn_id, refs) do
        {:ok, _} -> {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs, usage: %{}}, turn_id: turn_id)}
        err -> err
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
            nil -> {:halt, {:error, {:missing_ref, ref}}}
            ev -> if Oracle.evidence_class?(ev), do: {:cont, acc}, else: {:halt, {:error, {:not_evidence, ref}}}
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
                not lenient_evidence?(ev) -> {:halt, {:error, {:not_evidence, ref}}}
                last_mut != nil and ev.id <= last_mut -> {:halt, {:error, {:stale_evidence, ref}}}
                true -> {:cont, acc}
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
      {:evidence_required, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [], {:reject, :evidence_required}},
      # evidence PREDATES a later mutation -> stale
      {:stale, [Build.turn_started(1), Build.evidence(2), Build.mutation(3)], t, [2], {:reject, {:stale_evidence, 2}}},
      # ref points at an internal state_change -> not evidence-class
      {:not_evidence_state_change, [Build.turn_started(1), Build.mutation(2), Build.state_change(3)], t, [3], {:reject, {:not_evidence, 3}}},
      # ref points at the agent's own message text -> not evidence-class
      {:not_evidence_self_report, [Build.turn_started(1), Build.mutation(2), Build.self_report(3)], t, [3], {:reject, {:not_evidence, 3}}},
      # ref names an offset that does not exist
      {:missing_ref, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [99], {:reject, {:missing_ref, 99}}}
    ]
  end

  def by_name(name), do: Enum.find(contours(), fn {n, _, _, _, _} -> n == name end)

  @doc "Collapse a verdict to its accept/reject shape for equality across impls."
  def shape({:ok, _}), do: :accept
  def shape({:error, reason}), do: {:reject, reason}

  @doc "Collapse a verdict to its outcome CLASS (for generator-coverage assertions)."
  def outcome_class({:ok, _}), do: :accept
  def outcome_class({:error, :evidence_required}), do: :evidence_required
  def outcome_class({:error, {:stale_evidence, _}}), do: :stale_evidence
  def outcome_class({:error, {:not_evidence, _}}), do: :not_evidence
  def outcome_class({:error, {:missing_ref, _}}), do: :missing_ref
end

# ---------------------------------------------------------------------------
# Support — seed-reproducible journal generator (StreamData)
# ---------------------------------------------------------------------------
defmodule Raxol.Agent.Red.U21.Gen do
  @moduledoc false
  alias Raxol.Agent.Red.U21.Build

  # Fixed seed so sampled schedules reproduce (meta-inv 2).
  @seed {0x51, 0x21, 0x2026}

  def steps_gen do
    StreamData.list_of(
      StreamData.member_of([:mutation, :read, :evidence, :self_report, :state_change]),
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
      evidence_offsets = journal |> Enum.filter(&(&1.payload[:item_type] == :tool_result)) |> Enum.map(& &1.id)

      refs_gen =
        StreamData.one_of([
          StreamData.constant([]),
          StreamData.list_of(StreamData.member_of(candidates), max_length: 4),
          # cite every evidence offset — the branch that RELIABLY surfaces the
          # stale-evidence ordering (an evidence offset before a later mutation),
          # keeping the stale red non-vacuous (meta-inv 5).
          StreamData.constant(evidence_offsets)
        ])

      StreamData.bind(refs_gen, fn refs -> StreamData.constant({journal, "t", refs}) end)
    end)
  end

  @doc "Deterministic sample of `n` triples (seed-fixed)."
  def sample(n) do
    :rand.seed(:exsss, @seed)
    journal_and_refs_gen() |> Enum.take(n)
  end

  defp build_journal(steps) do
    first = Build.turn_started(1)
    rest = steps |> Enum.with_index(2) |> Enum.map(fn {step, off} -> build_step(step, off) end)
    [first | rest]
  end

  defp build_step(:mutation, off), do: Build.mutation(off)
  defp build_step(:read, off), do: Build.read_action(off)
  defp build_step(:evidence, off), do: Build.evidence(off)
  defp build_step(:self_report, off), do: Build.self_report(off)
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
    do: Agent.update(pid, fn s -> %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))} end)

  def assert_all_fired!(pid) do
    %{armed: armed, fired: fired} = Agent.get(pid, & &1)
    dead = Enum.filter(armed, &(Map.get(fired, &1, 0) == 0))

    if dead != [] do
      raise ExUnit.AssertionError,
        message: "dead injector(s): armed site(s) never fired: #{inspect(dead)}; fired: #{inspect(fired)}"
    end

    fired
  end
end

# ===========================================================================
# THE REDS — against the real DoneGate skeleton. `:harness_red`, excluded in
# test_helper. RED (failing) until U21 lands.
# ===========================================================================
defmodule Raxol.Agent.Red.U21EvidenceDoneRedTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :harness_red

  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.Red.U21.{Contours, Gen, Oracle}

  # Route every gate call through apply/3 so the compiler keeps the return type
  # DYNAMIC. The skeleton returns a literal {:error, :not_implemented}; a direct
  # `DoneGate.gate/3` call would let the type system flag every `{:ok, _}` match
  # as a dead clause (breaking --warnings-as-errors) — the exact narrowing this
  # red suite must survive until the real gate ships the full verdict union.
  defp gate(journal, turn, refs), do: apply(DoneGate, :gate, [journal, turn, refs])

  describe "positive contour — done with valid postdating evidence is accepted" do
    test "accept: the gate hands back a turn_completed{final: true} carrying its evidence refs" do
      {_, journal, turn, refs, _} = Contours.by_name(:valid)

      assert {:ok, done} = gate(journal, turn, refs)
      assert done.type == :turn_completed
      assert done.payload.final == true
      assert done.payload.refs == refs
      assert done.turn_id == turn
    end
  end

  describe "negative contours — claim-without-evidence never transitions to done" do
    for {name, _j, _t, _r, expected} <- Raxol.Agent.Red.U21.Contours.contours(), name != :valid do
      test "reject: #{name} -> #{inspect(expected)}, turn stays open" do
        {_, journal, turn, refs, _expected} = Contours.by_name(unquote(name))

        verdict = gate(journal, turn, refs)
        assert Contours.shape(verdict) == unquote(Macro.escape(expected))
        # a rejected claim yields no done event to journal
        refute match?({:ok, _}, verdict)
      end
    end
  end

  describe "the fold property — every accepted done cites resolvable, evidence-class, postdating refs" do
    property "gate agrees with the evidence spec on every generated journal" do
      # The generator MUST include the stale-evidence ordering, or the property
      # is vacuous; the ControlsTest coverage guard enforces that separately.
      check all({journal, turn, refs} <- Gen.journal_and_refs_gen(), max_runs: 200) do
        assert Contours.shape(gate(journal, turn, refs)) ==
                 Contours.shape(Oracle.verdict(journal, turn, refs))
      end
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

  alias Raxol.Agent.Red.U21.{Contours, Gen, Injector, Oracle, Fired}

  describe "positive anchor — the contours are satisfiable" do
    test "a correct reference implementation satisfies every contour" do
      for {name, journal, turn, refs, expected} <- Contours.contours() do
        assert Contours.shape(Injector.Reference.gate(journal, turn, refs)) == expected,
               "reference failed the #{name} contour"
      end
    end
  end

  describe "dead injectors — each must fail its targeted red (meta-inv 4)" do
    test "every dead injector fails exactly its targeted contour, and every armed site fires (meta-inv 1)" do
      fired = Fired.new()
      for site <- [:accepts_without_refs, :existence_only, :text_as_evidence], do: Fired.arm(fired, site)

      # (a) accepts-without-refs must fail the evidence-required red.
      {_, j_a, t_a, r_a, exp_a} = Contours.by_name(:evidence_required)

      refute Contours.shape(Injector.AcceptsWithoutRefs.gate(j_a, t_a, r_a)) == exp_a,
             "AcceptsWithoutRefs should NOT satisfy the evidence-required red"

      Fired.fire(fired, :accepts_without_refs)

      # (b) existence-only must fail the stale-evidence red.
      {_, j_b, t_b, r_b, exp_b} = Contours.by_name(:stale)

      refute Contours.shape(Injector.ExistenceOnly.gate(j_b, t_b, r_b)) == exp_b,
             "ExistenceOnly should NOT satisfy the stale-evidence red"

      Fired.fire(fired, :existence_only)

      # (c) text-as-evidence must fail the evidence-class red (self-report ref).
      {_, j_c, t_c, r_c, exp_c} = Contours.by_name(:not_evidence_self_report)

      refute Contours.shape(Injector.TextAsEvidence.gate(j_c, t_c, r_c)) == exp_c,
             "TextAsEvidence should NOT satisfy the evidence-class red"

      Fired.fire(fired, :text_as_evidence)

      Fired.assert_all_fired!(fired)
    end

    test "the fold property is non-vacuous: each dead injector disagrees with the spec on >= 1 generated journal" do
      for {name, mod} <- [
            {:accepts_without_refs, Injector.AcceptsWithoutRefs},
            {:existence_only, Injector.ExistenceOnly},
            {:text_as_evidence, Injector.TextAsEvidence}
          ] do
        disagreements =
          Gen.sample(300)
          |> Enum.count(fn {j, t, r} ->
            Contours.shape(mod.gate(j, t, r)) != Contours.shape(Oracle.verdict(j, t, r))
          end)

        assert disagreements > 0, "the fold property would never catch #{name}"
      end
    end
  end

  describe "generator coverage (meta-inv 5) — the reds are not vacuous" do
    test "the generator exercises every outcome class, INCLUDING cited stale evidence" do
      classes =
        Gen.sample(400)
        |> Enum.map(fn {j, t, r} -> Contours.outcome_class(Oracle.verdict(j, t, r)) end)
        |> Enum.frequencies()

      assert Map.get(classes, :accept, 0) > 0, "no accept case generated (#{inspect(classes)})"
      assert Map.get(classes, :evidence_required, 0) > 0, "no evidence-required case (#{inspect(classes)})"

      assert Map.get(classes, :stale_evidence, 0) > 0,
             "generator never cited stale evidence — the stale red is vacuous (#{inspect(classes)})"

      assert Map.get(classes, :not_evidence, 0) > 0, "no not-evidence case (#{inspect(classes)})"
      assert Map.get(classes, :missing_ref, 0) > 0, "no missing-ref case (#{inspect(classes)})"
    end
  end
end
