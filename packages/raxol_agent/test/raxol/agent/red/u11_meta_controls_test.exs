defmodule Raxol.Agent.Red.U11MetaControlsTest do
  @moduledoc """
  U11-R negative controls + corpus tests — these run in **regular CI** (no
  `:harness_red` tag) alongside the excluded red suite in
  `u11_meta_family_red_test.exs`.

  ## Negative controls (meta-invariant m4 — dead injectors)

  Every negative contour of the U11 red suite names a *dead injector*: the
  exact broken implementation that would make its red green-on-broken.
  Each control here runs that injector (a broken oracle
  variant in `Raxol.Agent.Red.MetaOracle`) against the SAME generated journals
  the red suite uses and asserts the breakage is **detectable** — the broken
  answer must disagree with the correct oracle exactly where the red asserts.
  A control failing means the red has lost its teeth.

  Fired-counters (meta-invariant m1): every injector keeps a fire count; the
  final assertion fails if any armed injector never fired. Schedules are
  seed-reproducible (m2): every generator takes the seed, and every failure
  message dumps it.

  ## Corpus tests (P-U11.2 class — not reds)

  The grandfather clause is a pure-decode corpus check: it must be green TODAY
  against the enabler (frozen struct defaults), and stay green forever.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Meta.Registry
  alias Raxol.Agent.Red.MetaJournalGen, as: Gen
  alias Raxol.Agent.Red.MetaOracle, as: Oracle

  # ===========================================================================
  # Dead-injector controls (N-U11.1 … N-U11.10) with fired-counters
  # ===========================================================================

  # Each injector: {name, fn seed -> :caught | {:missed, info} end}. An injector
  # FIRES by running its broken variant; it is CAUGHT when the broken answer
  # disagrees with the correct oracle where the red suite asserts.
  defp injectors do
    [
      {:n_u11_1_pass_through_emit_seam,
       fn seed ->
         event = %{family: :meta, type: :totally_bogus, payload: %{refs: []}}
         correct = Oracle.validate_correct(event)
         broken = Oracle.validate_pass_through(event)

         if correct == {:error, {:unknown_meta_type, :totally_bogus}} and
              broken == :ok,
            do: :caught,
            else: {:missed, %{seed: seed, correct: correct, broken: broken}}
       end},
      {:n_u11_2_emptied_required_keys,
       fn seed ->
         payload = Gen.meta_payload(:gate_decision, [1]) |> Map.delete(:seed)
         event = %{family: :meta, type: :gate_decision, payload: payload}
         correct = Oracle.validate_correct(event)
         broken = Oracle.validate_empty_required(event)

         case {correct, broken} do
           {{:error, {:invalid_meta_payload, :gate_decision, missing}}, :ok} ->
             if :seed in missing,
               do: :caught,
               else: {:missed, %{seed: seed, missing: missing}}

           other ->
             {:missed, %{seed: seed, got: other}}
         end
       end},
      {:n_u11_3_hardcode_trusted,
       fn seed ->
         %{records: records, tainted_offsets: tainted} =
           Gen.tainted_chain(seed, depth: 4)

         correct = Oracle.derive_taint_correct(records)
         broken = Oracle.derive_taint_hardcode_trusted(records)

         # The red names the offending {meta_id, tainted_ref_id} pair — here the
         # detectability check: the broken fold disagrees on every tainted meta.
         disagreements =
           Enum.filter(tainted, fn off -> broken[off] != correct[off] end)

         if disagreements == tainted and
              Enum.all?(tainted, &(correct[&1] == :tainted)),
            do: :caught,
            else:
              {:missed,
               %{seed: seed, disagreements: disagreements, tainted: tainted}}
       end},
      {:n_u11_4_scope_check_deleted,
       fn seed ->
         event = %{
           family: :meta,
           type: :extract,
           payload: Gen.meta_payload(:extract, [1]),
           scope: :global
         }

         correct = Oracle.validate_correct(event)
         broken = Oracle.validate_no_scope_check(event)

         if correct == {:error, {:scope_violation, :extract}} and broken == :ok,
           do: :caught,
           else: {:missed, %{seed: seed, correct: correct, broken: broken}}
       end},
      {:n_u11_5_launder_branch,
       fn seed ->
         # The generated chain routes taint through a :promote link — the launder
         # injector upgrades exactly that link, which the no-laundering red catches.
         %{records: records} = Gen.tainted_chain(seed, depth: 4)
         correct = Oracle.derive_taint_correct(records)
         broken = Oracle.derive_taint_launder(records)

         promote_offsets =
           for r <- records,
               Oracle.family(r) == :meta,
               Oracle.type(r) == :promote,
               do: Oracle.offset(r)

         laundered =
           Enum.filter(promote_offsets, fn off ->
             correct[off] == :tainted and broken[off] == :trusted
           end)

         if promote_offsets != [] and laundered == promote_offsets,
           do: :caught,
           else:
             {:missed,
              %{seed: seed, promotes: promote_offsets, laundered: laundered}}
       end},
      {:n_u11_6_strict_reader_seam,
       fn seed ->
         unknown =
           Gen.rec(1, :meta, :from_the_future_v9, %{refs: []},
             source: "probe_x"
           )

         correct = Oracle.decode_correct(unknown)
         broken = Oracle.decode_strict(unknown)

         case {correct, broken} do
           {{:ok, _}, {:error, {:unknown_meta_type, :from_the_future_v9}}} ->
             :caught

           other ->
             {:missed, %{seed: seed, got: other}}
         end
       end},
      {:n_u11_7_unfiltered_fold,
       fn seed ->
         %{records: records, stripped: stripped} = Gen.interleaved(seed)
         correct = Oracle.loop_projection_correct(records)
         also_correct = Oracle.loop_projection_correct(stripped)
         broken = Oracle.loop_projection_unfiltered(records)

         # Fold independence holds for the correct fold and BREAKS for the
         # unfiltered one (the interleaved journal always contains ≥1 meta).
         if correct == also_correct and broken != correct,
           do: :caught,
           else: {:missed, %{seed: seed, correct: correct, broken: broken}}
       end},
      {:n_u11_8_actor_stamping,
       fn seed ->
         %{records: records, expected_actors: expected} =
           Gen.actor_generations(seed)

         # Reader half: inferring :agent from absence disagrees with the
         # absent-=-system fold rule.
         broken_reader = Oracle.fold_actors_infer(records)
         reader_caught? = broken_reader != expected

         # Producer half: module-local stamping makes two records in ONE write
         # generation disagree — recomputing from the generation context
         # (the independent oracle) detects the divergence.
         [first | rest] = records
         local_stamp = %{"kind" => "human", "id" => "module-local-invention"}
         mutated = [Map.put(first, "actor", local_stamp) | rest]
         producer_caught? = Oracle.fold_actors_correct(mutated) != expected

         if reader_caught? and producer_caught?,
           do: :caught,
           else:
             {:missed,
              %{seed: seed, reader: reader_caught?, producer: producer_caught?}}
       end},
      {:n_u11_9_head_wins_precedence,
       fn seed ->
         %{records: records, item_offset: off, x: x, z: z} =
           Gen.fingerprint_precedence(seed)

         correct = Oracle.what_produced_correct(records, off)
         broken = Oracle.what_produced_head(records, off)

         if correct == z and broken == x and broken != correct,
           do: :caught,
           else: {:missed, %{seed: seed, correct: correct, broken: broken}}
       end},
      {:n_u11_10_singular_refs,
       fn seed ->
         %{event: event, parents: parents} =
           Gen.speculation_plural(seed, parents: 3)

         correct = Oracle.validate_correct(event)
         broken = Oracle.validate_singular_refs(event)

         if length(parents) >= 2 and correct == :ok and
              match?({:error, _}, broken),
            do: :caught,
            else: {:missed, %{seed: seed, correct: correct, broken: broken}}
       end}
    ]
  end

  test "every §2.3 dead injector fires and is caught (m1 fired-counters, m2 seed dump)" do
    seed = Gen.fresh_seed()

    {fired, missed} =
      Enum.reduce(injectors(), {%{}, []}, fn {name, run}, {fired, missed} ->
        fired = Map.update(fired, name, 1, &(&1 + 1))

        case run.(seed) do
          :caught -> {fired, missed}
          {:missed, info} -> {fired, [{name, info} | missed]}
        end
      end)

    assert missed == [],
           "dead injector(s) NOT caught — the red suite has lost its teeth: " <>
             "#{inspect(missed, pretty: true)}\nseed=#{seed}"

    dead = for {name, _} <- injectors(), Map.get(fired, name, 0) == 0, do: name

    assert dead == [],
           "dead injector(s): armed but never fired: #{inspect(dead)}\n" <>
             "fired counts: #{inspect(fired)}\nseed=#{seed}"

    # All ten §2.3 contours are armed — a control silently dropped from the
    # table is itself a dead injector.
    assert map_size(fired) == 10,
           "expected 10 armed injectors, got #{map_size(fired)}. seed=#{seed}"
  end

  # ===========================================================================
  # Generator non-vacuity (meta-invariant m5 — required patterns)
  # ===========================================================================

  describe "generator non-vacuity (m5)" do
    test "tainted chains are ≥3 deep, with a trusted sibling chain" do
      seed = Gen.fresh_seed()

      %{tainted_offsets: tainted, trusted_offsets: trusted, depth: depth} =
        Gen.tainted_chain(seed)

      assert depth >= 3, "seed=#{seed}"
      assert length(tainted) >= 2, "chain must have ≥2 meta links. seed=#{seed}"
      assert trusted != [], "not-all-tainted guard missing. seed=#{seed}"
    end

    test "interleaved journals always contain both families" do
      seed = Gen.fresh_seed()

      for s <- seed..(seed + 20) do
        %{records: records} = Gen.interleaved(s)
        families = records |> Enum.map(& &1["family"]) |> MapSet.new()

        assert MapSet.equal?(families, MapSet.new(["loop", "meta"])),
               "seed=#{s}"
      end
    end

    test "speculation generator refuses < 2 parents" do
      seed = Gen.fresh_seed()
      %{parents: parents} = Gen.speculation_plural(seed, parents: 1)

      assert length(parents) >= 2,
             "plural-refs red would be vacuous. seed=#{seed}"
    end

    test "actor generations include an absent-actor (system-by-rule) generation" do
      seed = Gen.fresh_seed()

      %{records: records, expected_actors: expected} =
        Gen.actor_generations(seed)

      assert Enum.any?(records, &is_nil(&1["actor"])), "seed=#{seed}"

      assert Enum.any?(expected, fn {_, a} -> a == %{kind: :system} end),
             "seed=#{seed}"
    end

    test "fingerprint journals carry three DISTINCT fingerprints (head ≠ turn ≠ item)" do
      seed = Gen.fresh_seed()
      %{x: x, y: y, z: z} = Gen.fingerprint_precedence(seed)
      assert x != y and y != z and x != z, "seed=#{seed}"
    end
  end

  # ===========================================================================
  # Registry freeze — the enabler's type table matches §2.1 exactly
  # ===========================================================================

  describe "registry freeze (§2.1 meta type table as data)" do
    test "all twelve v1 types are registered with their frozen required keys" do
      frozen = %{
        gate_decision: [:gate, :score, :threshold, :choice, :seed, :refs],
        extract: [:class, :op, :item, :refs],
        residual: [:description, :refs],
        calibrate: [:gate, :observed_score, :quantile, :new_threshold, :refs],
        verdict: [:family, :drift_score, :advice, :refs],
        research: [:conclusion, :refs],
        promote: [:item, :justification, :refs],
        probe_run: [:probe, :run_id, :status, :charge, :refs],
        attach: [:from_offset, :history_policy, :surface, :refs],
        speculation: [:phase, :branch_ref, :outcome, :refs],
        approval_decided: [:request_ref, :decision, :refs],
        policy_amended: [:scope, :rule_id, :before, :after, :source, :refs]
      }

      assert MapSet.new(Registry.type_names()) == MapSet.new(Map.keys(frozen)),
             "the registry may only GROW — a missing v1 type is a freeze violation"

      for {type, keys} <- frozen do
        assert Enum.sort(Registry.required_keys(type)) == Enum.sort(keys),
               "#{type} required-key set drifted from the freeze"

        assert :refs in Registry.required_keys(type),
               "refs is the uniform annotation key on EVERY meta type"
      end
    end

    test "promote is the ONLY :global type" do
      globals =
        for t <- Registry.type_names(), Registry.scope(t) == :global, do: t

      assert globals == [:promote]
    end

    test "the fingerprint exclusion list is exhaustive and seed is INCLUDED" do
      assert Enum.sort(Raxol.Agent.Fingerprint.excluded_keys()) ==
               Enum.sort([
                 :request_id,
                 :idempotency_key,
                 :trace_id,
                 :timestamp,
                 :ts
               ])

      refute :seed in Raxol.Agent.Fingerprint.excluded_keys(),
             "seed is a sampling parameter — replay identity needs it"
    end
  end

  # ===========================================================================
  # Grandfather corpus (P-U11.2 class — pure decode, green today and forever)
  # ===========================================================================

  describe "grandfather corpus (P-U11.2 — corpus test, not a red)" do
    test "the grown Event struct defaults ARE the frozen grandfather values" do
      e = %Event{}
      assert e.scope == :session
      assert e.provenance == %{source: :primary, trust: :trusted}
      assert e.actor == nil
    end

    test "a v0 event (no scope/provenance/actor keys) builds to the frozen defaults" do
      # struct/2 over a v0 field set — exactly what a pre-U11 decoder produces.
      v0_fields = %{
        v: 0,
        id: 7,
        session_id: "s",
        turn_id: "t",
        ts: 123,
        family: :loop,
        type: :item_completed,
        tier: :durable,
        payload: %{item_type: :message, content: "x"}
      }

      e = struct(Event, v0_fields)
      assert e.scope == :session
      assert e.provenance == %{source: :primary, trust: :trusted}
      assert e.actor == nil
    end

    test "encode_line carries the grown envelope fields without breaking v0 JSON shape" do
      line = Contract.encode_line(%Event{type: :turn_started, session_id: "s"})

      decoded =
        line
        |> IO.iodata_to_binary()
        |> String.trim_trailing("\n")
        |> Jason.decode!()

      # v0 keys all still present (the contract only grows)...
      for key <- ~w(v id session_id turn_id ts family type tier payload) do
        assert Map.has_key?(decoded, key), "encode_line lost v0 key #{key}"
      end

      # ...and the U11 growth is on the wire with the frozen defaults.
      assert decoded["scope"] == "session"

      assert decoded["provenance"] == %{
               "source" => "primary",
               "trust" => "trusted"
             }

      assert decoded["actor"] == nil
    end
  end
end
