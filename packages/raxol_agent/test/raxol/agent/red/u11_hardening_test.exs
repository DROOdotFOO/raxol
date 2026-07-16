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
  alias Raxol.Agent.Meta
  alias Raxol.Agent.Red.MetaJournalGen, as: Gen

  # ===========================================================================
  # Finding 2 (🔴) — taint fails CLOSED on unknown/garbage trust
  # ===========================================================================

  describe "taint fails CLOSED on unknown trust (§2.1 pt.1)" do
    test "(a) a record with provenance.trust \"poisoned\" decodes to :tainted, never :trusted" do
      poisoned =
        Gen.rec(1, :meta, :extract, Gen.meta_payload(:extract, []),
          trust: "poisoned"
        )

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
        Gen.rec(2, :meta, :extract, Gen.meta_payload(:extract, [1]),
          trust: "trusted"
        )

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
        Gen.rec(2, :meta, :extract, Gen.meta_payload(:extract, [1]),
          trust: "trusted"
        )

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
end
