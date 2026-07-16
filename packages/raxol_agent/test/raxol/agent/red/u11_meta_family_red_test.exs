defmodule Raxol.Agent.Red.U11MetaFamilyRedTest do
  @moduledoc """
  U11-R — permanent **failing-first** red suite for the meta event family +
  provenance/taint contract (FI-5), authored BEFORE `Raxol.Agent.Meta` is
  implemented. See `docs/proposals/in-flight/harness-freeze-contracts.md` §2 and
  docs PR #569.

  Every test here pins one frozen contour of §2 against the REAL seam
  (`Raxol.Agent.Meta` / `Raxol.Agent.Fingerprint`), which returns
  `:not_implemented` until U11-I lands — so the suite is RED by construction and
  goes green only when the real algebra is implemented. Each assertion asserts a
  POSITIVE concrete shape (`== {:error, …}`, `{:ok, %Event{}}`, `== oracle`,
  `is_binary/1`) so `:not_implemented` can never satisfy it vacuously.

  The independent oracle (`Raxol.Agent.Red.MetaOracle`, meta-invariant m6) supplies
  every "expected" value; the negative CONTROLS proving each red has teeth live
  in `u11_meta_controls_test.exs` and run in CI.

  U11-I has landed (`Raxol.Agent.Meta` / `Raxol.Agent.Fingerprint`), so this
  suite now runs GREEN in every regular run — the `:harness_red` exclusion was
  lifted the day the implementation made every contour pass. The negative
  controls stay in CI to guarantee the reds keep their teeth.

  Contour map (freeze §2.2/§2.3):
    producer-strict seam ....... N-U11.1, N-U11.2, N-U11.4, N-U11.10
    reader-tolerant seam ....... N-U11.6, P-JS6-class tolerance
    taint algebra .............. P-U11.3, N-U11.3, N-U11.5, OQ-U11.3
    scope discipline ........... P-U11.4
    fold independence .......... P-U11.5, N-U11.7
    actor producer seam ........ P-U11.6, N-U11.8
    fingerprint precedence ..... P-U11.7, N-U11.9
    speculation plural refs .... P-U11.8, N-U11.10
    codec round-trip ........... P-U11.1
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Fingerprint
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Meta
  alias Raxol.Agent.Red.MetaJournalGen, as: Gen
  alias Raxol.Agent.Red.MetaOracle, as: Oracle

  setup do
    base =
      Path.join(
        System.tmp_dir!(),
        "red_u11_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    {:ok, base: base, seed: Gen.fresh_seed()}
  end

  defp dump(seed), do: "seed=#{seed}"

  # Seed a REAL journal (single Writer, tolerant Reader) from generated records,
  # letting the Writer stamp offsets, and read it back. Exercises the production
  # storage path, not a mock. Returns `{readback_records, session_id}`.
  defp seed_journal!(base, records) do
    session = "red-#{System.unique_integer([:positive])}"
    {:ok, j} = FileStore.open(session, base_dir: base)

    for r <- records do
      appendable = Map.drop(r, ["id", "schema_version"])
      {:ok, _off} = FileStore.append(j, appendable)
    end

    {:ok, readback} = FileStore.read(j)
    :ok = FileStore.close(j)
    {readback, session}
  end

  # ===========================================================================
  # Producer-strict seam (§2.1 decode/validation seam; N-U11.1/2/4/10)
  # ===========================================================================

  describe "producer-strict seam — validate/1" do
    test "N-U11.1 — an unregistered meta type is a loud typed reject", %{
      seed: seed
    } do
      event = %{family: :meta, type: :totally_bogus, payload: %{refs: []}}

      assert Meta.validate(event) ==
               {:error, {:unknown_meta_type, :totally_bogus}},
             "unregistered meta type must reject at the emit seam. " <>
               dump(seed)
    end

    test "N-U11.2 — a missing required payload key is a loud typed reject", %{
      seed: seed
    } do
      # gate_decision requires :seed among others.
      payload = Gen.meta_payload(:gate_decision, [1]) |> Map.delete(:seed)
      event = %{family: :meta, type: :gate_decision, payload: payload}

      assert {:error, {:invalid_meta_payload, :gate_decision, missing}} =
               Meta.validate(event),
             "missing required key must reject. " <> dump(seed)

      assert :seed in missing
    end

    test "N-U11.2 — refs is required on EVERY meta type", %{seed: seed} do
      payload = Gen.meta_payload(:extract, [1]) |> Map.delete(:refs)
      event = %{family: :meta, type: :extract, payload: payload}

      assert {:error, {:invalid_meta_payload, :extract, missing}} =
               Meta.validate(event),
             "refs is the uniform required annotation key. " <> dump(seed)

      assert :refs in missing
    end

    test "N-U11.4 — promote with refs: [] is provenance-mandatory reject", %{
      seed: seed
    } do
      payload = %{item: %{k: "v"}, justification: "j", refs: []}
      event = %{family: :meta, type: :promote, payload: payload, scope: :global}

      assert Meta.validate(event) == {:error, :provenance_required},
             "promote requires refs != []. " <> dump(seed)
    end

    test "N-U11.4 — scope :global on a non-promote type is a scope violation",
         %{seed: seed} do
      event = %{
        family: :meta,
        type: :extract,
        payload: Gen.meta_payload(:extract, [1]),
        scope: :global
      }

      assert Meta.validate(event) == {:error, {:scope_violation, :extract}},
             ":global is legal only on promote. " <> dump(seed)
    end

    test "N-U11.10 — speculation :begin ACCEPTS ≥2 in-session parent refs", %{
      seed: seed
    } do
      %{event: event, parents: parents} =
        Gen.speculation_plural(seed, parents: 3)

      assert length(parents) >= 2

      assert Meta.validate(event) == :ok,
             "plural parents at speculation begin must be legal (not len==1). " <>
               dump(seed)
    end
  end

  # ===========================================================================
  # Reader-tolerant seam (§2.1; N-U11.6)
  # ===========================================================================

  describe "reader-tolerant seam — decode/1 + typed-fold skipping" do
    test "N-U11.6 — an unknown meta type from a future journal decodes {:ok,_}, preserved",
         %{
           base: base,
           seed: seed
         } do
      unknown =
        Gen.rec(1, :meta, :from_the_future_v9, %{refs: [], note: "later"},
          source: "probe_x"
        )

      {[readback], _session} = seed_journal!(base, [unknown])

      # The tolerant Reader itself never damages on an unknown type (precondition).
      assert readback["type"] == "from_the_future_v9"

      # The decode seam preserves it rather than erroring (the frozen tolerance).
      assert {:ok, %Event{type: :from_the_future_v9}} = Meta.decode(readback),
             "unknown meta type must be preserved, never errored, at the reader seam. " <>
               dump(seed)
    end

    test "an unknown meta type is SKIPPED by a typed loop fold (not perturbing it)",
         %{seed: seed} do
      %{records: records, stripped: stripped} = Gen.interleaved(seed)
      future = Gen.rec(99, :meta, :unknown_meta_kind, %{refs: []})
      with_future = records ++ [future]

      expected = Oracle.loop_projection_correct(stripped)

      assert Meta.loop_projection(with_future) == expected,
             "unknown meta types must be skipped by typed folds. " <> dump(seed)
    end

    test "grandfather — a v0 record with no scope/provenance/actor decodes to frozen defaults",
         %{
           seed: seed
         } do
      v0 = %{
        "id" => 1,
        "schema_version" => "1.0.0",
        "kind" => "event",
        "v" => 0,
        "session_id" => "s",
        "turn_id" => nil,
        "ts" => 1,
        "family" => "loop",
        "type" => "item_completed",
        "tier" => "durable",
        "payload" => %{"item_type" => "message", "content" => "x"}
      }

      assert {:ok,
              %Event{
                scope: :session,
                provenance: %{source: :primary, trust: :trusted},
                actor: nil
              }} =
               Meta.decode(v0),
             "a v0 record must decode to the grandfather defaults. " <>
               dump(seed)
    end
  end

  # ===========================================================================
  # Taint algebra — P-U11.3, N-U11.3/5, OQ-U11.3
  # ===========================================================================

  describe "taint algebra (FI-5)" do
    test "P-U11.3 — taint monotonicity over a chain ≥3 deep equals the algebra's answer",
         %{
           seed: seed
         } do
      %{records: records, tainted_offsets: tainted, depth: depth} =
        Gen.tainted_chain(seed, depth: 4)

      assert depth >= 3 and length(tainted) >= 2,
             "generator must produce a chain ≥3 deep. " <> dump(seed)

      expected = Oracle.derive_taint_correct(records)

      assert Meta.derive_taint(records) == expected,
             "every meta event's derived trust must equal the taint algebra. " <>
               dump(seed)

      # And concretely: the whole tainted chain is tainted (absorption held).
      for off <- tainted do
        assert expected[off] == :tainted
        assert Meta.derive_taint(records)[off] == :tainted, dump(seed)
      end
    end

    test "no laundering — derive_taint never upgrades a tainted ref to :trusted",
         %{seed: seed} do
      %{records: records} = Gen.tainted_chain(seed, depth: 3)
      derived = Meta.derive_taint(records)

      # Every meta whose refs reach a tainted record stays tainted.
      for r <- records, Oracle.family(r) == :meta do
        oracle = Oracle.derive_taint_correct(records)[Oracle.offset(r)]

        assert Map.get(derived, Oracle.offset(r)) == oracle,
               "no :tainted→:trusted laundering path exists in v1. " <>
                 dump(seed)
      end
    end

    test "OQ-U11.3 — a hand-crafted taint violation surfaces a marker, replay stays {:ok,_}",
         %{
           base: base,
           seed: seed
         } do
      %{records: records, violated_offset: off} = Gen.violated_journal(seed)
      {readback, session} = seed_journal!(base, records)

      # NEVER damaged, NEVER hard-rejected — replay tolerance of the violated
      # journal itself is intact (re-open the SAME session and re-read).
      {:ok, j} = FileStore.open(session, base_dir: base)
      assert {:ok, reread} = FileStore.read(j)
      assert length(reread) == length(records)
      :ok = FileStore.close(j)

      # The violation surfaces ONLY as an observable fold marker.
      assert [%{offset: ^off, stored: :trusted, derived: :tainted}] =
               Meta.taint_violations(readback),
             "a taint violation is an alarm + :taint_violation marker, never damage. " <>
               dump(seed)
    end
  end

  # ===========================================================================
  # Scope discipline — P-U11.4
  # ===========================================================================

  describe "scope discipline (P-U11.4)" do
    test "a valid journal passes check_scope (:global only on promote, promote refs != [])",
         %{
           seed: seed
         } do
      records = for %{record: r} <- Gen.one_per_type(seed), do: r

      assert Meta.check_scope(records) == :ok,
             ":global appears only on promote and every promote has refs != []. " <>
               dump(seed)
    end
  end

  # ===========================================================================
  # Fold independence — P-U11.5
  # ===========================================================================

  describe "two-populations fold independence (P-U11.5)" do
    test "a loop-only projection over an interleaved journal equals the fold over the stripped one",
         %{seed: seed} do
      %{records: interleaved, stripped: stripped} = Gen.interleaved(seed)

      assert Enum.any?(interleaved, &(&1["family"] == "meta")),
             "generator must interleave meta. " <> dump(seed)

      expected = Oracle.loop_projection_correct(stripped)

      assert Meta.loop_projection(interleaved) == expected,
             "meta events must never perturb the loop-only fold. " <> dump(seed)
    end
  end

  # ===========================================================================
  # Actor producer seam — P-U11.6
  # ===========================================================================

  describe "actor producer-seam consistency (P-U11.6)" do
    test "every event's actor equals its write-generation actor; absent folds to system",
         %{
           seed: seed
         } do
      %{records: records, expected_actors: expected} =
        Gen.actor_generations(seed)

      assert Enum.any?(expected, fn {_, a} -> a == %{kind: :system} end),
             "generator must include an absent-actor generation. " <> dump(seed)

      assert Meta.fold_actors(records) == expected,
             "actor is producer-seam stamped; absent = system by rule. " <>
               dump(seed)
    end
  end

  # ===========================================================================
  # Fingerprint precedence — P-U11.7 + canonical_json (P-U11.1)
  # ===========================================================================

  describe "fingerprint precedence + canonical_json (P-U11.7)" do
    test "what_produced returns the item_completed fingerprint Z, not head X or override Y",
         %{
           seed: seed
         } do
      %{records: records, item_offset: off, x: x, y: y, z: z} =
        Gen.fingerprint_precedence(seed)

      assert x != y and y != z and x != z,
             "generator must make X≠Y≠Z. " <> dump(seed)

      assert Meta.what_produced(records, off) == z,
             "the item_completed fingerprint wins 'what produced this content'. " <>
               dump(seed)
    end

    test "canonical_json is a byte-stable, key-order-independent serialization with seed INCLUDED",
         %{seed: seed} do
      params = %{
        model: "m",
        temperature: 0.7,
        seed: 11,
        top_p: 1.0,
        request_id: "REQ-ephemeral"
      }

      shuffled = %{
        top_p: 1.0,
        seed: 11,
        temperature: 0.7,
        request_id: "OTHER-ephemeral",
        model: "m"
      }

      canon = Fingerprint.canonical_json(params)

      assert is_binary(canon),
             "canonical_json must produce a binary. " <> dump(seed)

      assert canon == Fingerprint.canonical_json(shuffled),
             "key order + ephemeral keys must not matter. " <> dump(seed)

      assert canon == Oracle.canonical_json_correct(params),
             "must match the normative serializer. " <> dump(seed)

      # seed is part of replay identity — changing it MUST change the hash input.
      with_other_seed = %{params | seed: 999}
      assert is_binary(Fingerprint.canonical_json(with_other_seed))

      refute canon == Fingerprint.canonical_json(with_other_seed),
             "seed is INCLUDED in the hash. " <> dump(seed)
    end
  end

  # ===========================================================================
  # Speculation plural refs round-trip — P-U11.8
  # ===========================================================================

  describe "speculation refs are plural-capable (P-U11.8)" do
    test "a speculation{:begin} with ≥2 in-session parents round-trips without a singular assumption",
         %{seed: seed} do
      %{record: record, parents: parents} =
        Gen.speculation_plural(seed, parents: 3)

      assert length(parents) >= 2

      assert {:ok, %Event{} = ev} = Meta.decode(record),
             "speculation record must decode. " <> dump(seed)

      assert ev.payload["refs"] == parents or ev.payload[:refs] == parents,
             "≥2 parents must survive decode unchanged. " <> dump(seed)

      # And re-encode is byte-stable (no truncation to one parent).
      assert is_binary(Meta.encode(ev)), dump(seed)
    end
  end

  # ===========================================================================
  # Codec round-trip — P-U11.1
  # ===========================================================================

  describe "codec round-trip (P-U11.1)" do
    test "every registry meta type round-trips encode |> decode byte-stable (post-sanitize)",
         %{
           seed: seed
         } do
      for %{type: type, record: record} <- Gen.one_per_type(seed) do
        {:ok, event} =
          case Meta.decode(record) do
            {:ok, ev} ->
              {:ok, ev}

            other ->
              flunk(
                "decode(#{type}) returned #{inspect(other)} — expected {:ok, _}. " <>
                  dump(seed)
              )
          end

        encoded = Meta.encode(event)

        assert is_binary(encoded),
               "encode(#{type}) must be a binary. " <> dump(seed)

        assert {:ok, event2} = Meta.decode(decode_json!(encoded)),
               "re-decode of #{type} must succeed. " <> dump(seed)

        assert Meta.encode(event2) == encoded,
               "#{type} must be byte-stable across a second round-trip. " <>
                 dump(seed)
      end
    end
  end

  defp decode_json!(binary) when is_binary(binary), do: Jason.decode!(binary)
end
