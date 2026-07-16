defmodule Raxol.Agent.Red.U11HardeningTest do
  @moduledoc """
  Regression suite for the adversarial-review findings on the U11 SUBSTRATE
  (`Raxol.Agent.Meta` / `Raxol.Agent.Fingerprint`). Each describe block proves
  the FIXED arm of one finding — the fail-closed (🔴) arms are mandatory:
  they must reject / taint / preserve, never fail open.

  These run in regular CI alongside the frozen U11 red suite + controls; they
  pin the security-critical seams the YOLO-safe soundness theorem depends on.
  """
  use ExUnit.Case, async: true

  @moduletag :capture_log

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.Fingerprint
  alias Raxol.Agent.Meta
  alias Raxol.Agent.Red.MetaJournalGen, as: Gen

  # ===========================================================================
  # Finding 2 (🔴) — taint fails CLOSED on unknown/garbage trust
  # ===========================================================================

  describe "taint fails CLOSED on unknown trust (§2.1 pt.1)" do
    test "(a) a record with provenance.trust \"poisoned\" decodes to :tainted, never :trusted" do
      poisoned =
        Gen.rec(1, :meta, :extract, Gen.meta_payload(:extract, []), trust: "poisoned")

      assert {:ok, %Event{provenance: %{trust: :tainted}}} = Meta.decode(poisoned),
             "a present-but-unrecognized trust token must fail closed to :tainted"
    end

    test "(b) a tool_result leaf with unknown trust taints its dependents" do
      # The entry point stores an unrecognized trust token; the meta event that
      # refs it stores :trusted but MUST derive :tainted (leaves anchor the fold
      # via stored_trust, so a laundered entry point can no longer read trusted).
      entry =
        Gen.rec(1, :loop, :tool_result, %{name: "fetch", result: "x", refs: []},
          trust: "garbage-token"
        )

      dependent =
        Gen.rec(2, :meta, :extract, Gen.meta_payload(:extract, [1]), trust: "trusted")

      derived = Meta.derive_taint([entry, dependent])

      assert derived[2] == :tainted,
             "an unknown-trust entry point must taint everything that derives from it"
    end

    test "(c) absent provenance still reads :trusted (grandfather rule preserved)" do
      bare = %{
        "id" => 1,
        "family" => "loop",
        "type" => "tool_result",
        "payload" => %{"refs" => []}
      }

      assert {:ok, %Event{provenance: %{source: :primary, trust: :trusted}}} =
               Meta.decode(bare),
             "absent provenance must default to the frozen grandfather value"

      dependent =
        Gen.rec(2, :meta, :extract, Gen.meta_payload(:extract, [1]), trust: "trusted")

      # A meta event whose only ref is a grandfathered (absent-provenance) leaf
      # stays trusted — the grandfather path is NOT the same as fail-closed.
      assert Meta.derive_taint([bare, dependent])[2] == :trusted
    end
  end

  # ===========================================================================
  # Finding 4 (🔴) — branch_id round-trips off disk (read side)
  # ===========================================================================

  describe "branch_id read-side round-trip (§1.1)" do
    test "a record written with a non-default branch_id decodes back with it" do
      rec =
        Gen.rec(1, :loop, :item_completed, %{item_type: "message", refs: []})
        |> Map.put("branch_id", "feature-x")

      assert {:ok, %Event{branch_id: "feature-x"}} = Meta.decode(rec),
             "a non-default branch_id on disk must round-trip onto the Event"
    end

    test "a record without branch_id decodes to the default \"main\" (grandfather)" do
      rec = Gen.rec(1, :loop, :item_completed, %{item_type: "message", refs: []})
      refute Map.has_key?(rec, "branch_id")

      assert {:ok, %Event{branch_id: "main"}} = Meta.decode(rec),
             "absent branch_id must default to \"main\""
    end
  end

  # ===========================================================================
  # Finding 3 (🟡→red) — reader-tolerant decode never exhausts the atom table
  # ===========================================================================

  describe "decode preserves unknown tokens raw, never materializing atoms (§0.2)" do
    test "decoding many distinct unknown type/source strings creates no atoms" do
      before = :erlang.system_info(:atom_count)

      records =
        for i <- 1..2000 do
          # A guaranteed-fresh token never compiled as an atom anywhere.
          tok = "u11_unknown_#{System.unique_integer([:positive])}_#{i}"

          %{
            "id" => i,
            "family" => "meta",
            "type" => tok,
            "payload" => %{"refs" => []},
            "provenance" => %{"source" => tok <> "_src", "trust" => "trusted"}
          }
        end

      decoded =
        Enum.map(records, fn r ->
          {:ok, ev} = Meta.decode(r)
          ev
        end)

      after_count = :erlang.system_info(:atom_count)

      # Unknown tokens are preserved RAW as binaries (contract §0.2), never
      # turned into fresh atoms — so type + source stay binary...
      assert Enum.all?(decoded, fn ev -> is_binary(ev.type) end),
             "an unknown type must be preserved as a raw binary"

      assert Enum.all?(decoded, fn ev -> is_binary(ev.provenance.source) end),
             "an unknown source must be preserved as a raw binary"

      # ...and the atom table did NOT grow (2000 unknowns would add ~4000 atoms
      # under the old String.to_atom path — a VM-crashing DoS).
      assert after_count - before < 100,
             "decode leaked #{after_count - before} atoms from unknown journal tokens"
    end
  end

  # ===========================================================================
  # Finding 5 (🟡) — canonical_json recurses the key-sort into nested objects
  # ===========================================================================

  describe "canonical_json is deterministic through nested objects (I2)" do
    test "nested object keys are sorted at EVERY level, not just the top" do
      params = %{z_top: 1, a_top: %{y: 1, b: 2, m: %{q: 1, a: 2}}}

      # Sorted at the top, at a_top, AND at the doubly-nested m — the property
      # the old top-level-only sort (nested via Jason term order) did not give.
      assert Fingerprint.canonical_json(params) ==
               ~s({"a_top":{"b":2,"m":{"a":2,"q":1},"y":1},"z_top":1})
    end

    test "a nested object hashes identically regardless of how it was built" do
      built_a = %{model: "m", opts: Enum.into([b: 2, a: 1, deep: %{y: 2, x: 1}], %{})}

      built_b = %{}
      built_b = Map.put(built_b, :opts, Map.new([{:deep, Map.new(x: 1, y: 2)}, {:a, 1}, {:b, 2}]))
      built_b = Map.put(built_b, :model, "m")

      assert Fingerprint.canonical_json(built_a) == Fingerprint.canonical_json(built_b)
      assert Fingerprint.params_hash(built_a) == Fingerprint.params_hash(built_b)
    end
  end

  # ===========================================================================
  # Finding 6 (🟡) — what_produced precedence walk
  # ===========================================================================

  describe "what_produced follows the precedence law (§2.1)" do
    test "an item_completed offset resolves to its OWN fingerprint (highest precedence)" do
      %{records: records, item_offset: item_off, z: z} =
        Gen.fingerprint_precedence(0)

      assert Meta.what_produced(records, item_off) == z,
             "the item_completed fingerprint wins 'what produced this content'"
    end

    test "a turn_started offset resolves to the head default, NOT its 'what-was-asked' override" do
      %{records: records, x: x, y: y} = Gen.fingerprint_precedence(0)

      # offset 2 is the turn_started carrying override Y ("what was asked").
      produced = Meta.what_produced(records, 2)

      assert produced == x,
             "a turn_started must resolve to the head default (the effective " <>
               "producing fp), never the override"

      refute produced == y,
             "the turn_started override is 'what was asked', not 'what produced'"
    end
  end

  # ===========================================================================
  # Finding 7 (🟡) — validate enforces promote ⇒ :global
  # ===========================================================================

  describe "validate enforces promote ⇒ :global (§2.1)" do
    test "a session-scoped promote is rejected at validate" do
      event = %{
        family: :meta,
        type: :promote,
        payload: Gen.meta_payload(:promote, [1]),
        scope: :session
      }

      assert Meta.validate(event) == {:error, {:scope_violation, :promote}},
             "promote is the only commit type — a session-scoped promote is a " <>
               "mis-scoped commit and must be rejected"
    end

    test "a global-scoped promote with refs still passes (regression guard)" do
      event = %{
        family: :meta,
        type: :promote,
        payload: Gen.meta_payload(:promote, [1]),
        scope: :global
      }

      assert Meta.validate(event) == :ok
    end
  end
end
