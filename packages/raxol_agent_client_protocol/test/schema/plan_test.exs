# Ported from the MIT `f1729/agent_client_protocol` test suite
# (`test/acp/plan_test.exs`, c) 2025 f1729; see NOTICE.md. Adapted to
# `Raxol.AgentClientProtocol.Schema.{Plan,PlanEntry}`, and extended with
# total-decode / forward-compat coverage for this port's defect fixes.
defmodule Raxol.AgentClientProtocol.Schema.PlanTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.Plan
  alias Raxol.AgentClientProtocol.Schema.PlanEntry

  describe "PlanEntry" do
    test "to_json/from_json round trip" do
      entry = PlanEntry.new("Write code", :high, :pending)
      json = PlanEntry.to_json(entry)
      assert json == %{"content" => "Write code", "priority" => "high", "status" => "pending"}

      assert {:ok, decoded} = PlanEntry.from_json(json)
      assert decoded.content == "Write code"
      assert decoded.priority == :high
      assert decoded.status == :pending
      assert decoded._meta == %{}
    end

    test "all priority/status wire values round-trip" do
      for priority <- [:high, :medium, :low], status <- [:pending, :in_progress, :completed] do
        entry = PlanEntry.new("x", priority, status)
        assert {:ok, decoded} = entry |> PlanEntry.to_json() |> PlanEntry.from_json()
        assert decoded.priority == priority
        assert decoded.status == status
      end
    end

    test "with _meta round-trips under the wire \"_meta\" key" do
      entry = %PlanEntry{content: "x", priority: :low, status: :pending, _meta: %{"k" => "v"}}
      json = PlanEntry.to_json(entry)
      assert json["_meta"] == %{"k" => "v"}
      assert {:ok, decoded} = PlanEntry.from_json(json)
      assert decoded._meta == %{"k" => "v"}
    end

    test "empty _meta is omitted from the wire, never emitted as an empty object" do
      entry = PlanEntry.new("x", :low, :pending)
      refute Map.has_key?(PlanEntry.to_json(entry), "_meta")
    end

    # --- Total decode: never raises ---

    test "from_json/1 is total: missing required field never raises" do
      assert {:error, {:missing_field, "content"}} =
               PlanEntry.from_json(%{"priority" => "high", "status" => "pending"})

      assert {:error, {:missing_field, "priority"}} =
               PlanEntry.from_json(%{"content" => "x", "status" => "pending"})

      assert {:error, {:missing_field, "status"}} =
               PlanEntry.from_json(%{"content" => "x", "priority" => "high"})

      assert {:error, _} = PlanEntry.from_json(%{})
      assert {:error, _} = PlanEntry.from_json("not a map")
      assert {:error, _} = PlanEntry.from_json(nil)
      assert {:error, _} = PlanEntry.from_json(42)
    end

    test "from_json/1 is total: unrecognized priority/status fails the whole entry (required, no default)" do
      assert {:error, {:invalid_priority, "urgent"}} =
               PlanEntry.from_json(%{
                 "content" => "x",
                 "priority" => "urgent",
                 "status" => "pending"
               })

      assert {:error, {:invalid_status, "done"}} =
               PlanEntry.from_json(%{"content" => "x", "priority" => "high", "status" => "done"})
    end

    test "from_json/1 folds unknown wire fields into _meta, merged with an explicit _meta object" do
      assert {:ok, %PlanEntry{_meta: meta}} =
               PlanEntry.from_json(%{
                 "content" => "x",
                 "priority" => "high",
                 "status" => "pending",
                 "_meta" => %{"a" => 1},
                 "extra" => true
               })

      assert meta == %{"a" => 1, "extra" => true}
    end

    test "never invokes String.to_atom on wire-derived data (atom-DoS safety)" do
      for i <- 1..50 do
        assert {:ok, _} =
                 PlanEntry.from_json(%{
                   "content" => "x#{i}",
                   "priority" => "high",
                   "status" => "pending",
                   "field_#{i}" => i
                 })
      end
    end

    test "Jason.Encoder round-trips through real JSON" do
      entry = PlanEntry.new("Ship it", :medium, :in_progress)
      encoded = Jason.encode!(entry)
      assert {:ok, decoded_json} = Jason.decode(encoded)
      assert {:ok, decoded} = PlanEntry.from_json(decoded_json)
      assert decoded.content == "Ship it"
      assert decoded.priority == :medium
      assert decoded.status == :in_progress
    end
  end

  describe "Plan" do
    test "to_json/from_json round trip" do
      plan =
        Plan.new([
          PlanEntry.new("Step 1", :high, :completed),
          PlanEntry.new("Step 2", :medium, :in_progress)
        ])

      json = Plan.to_json(plan)
      assert length(json["entries"]) == 2

      assert {:ok, decoded} = Plan.from_json(json)
      assert length(decoded.entries) == 2
      assert hd(decoded.entries).status == :completed
    end

    test "with _meta round-trips under the wire \"_meta\" key" do
      plan = %Plan{entries: [], _meta: %{"key" => "value"}}
      json = Plan.to_json(plan)
      assert json["_meta"] == %{"key" => "value"}
      assert {:ok, decoded} = Plan.from_json(json)
      assert decoded._meta == %{"key" => "value"}
    end

    # --- Total decode + lenient leniency per the schema oracle
    #     (x-deserialize-default-on-error + x-deserialize-skip-invalid-items
    #     on Plan.entries) ---

    test "from_json/1 is total: never raises, even on non-map input" do
      assert {:ok, %Plan{entries: []}} = Plan.from_json(nil)
      assert {:ok, %Plan{entries: []}} = Plan.from_json("not a map")
      assert {:ok, %Plan{entries: []}} = Plan.from_json(42)
    end

    test "from_json/1 defaults a missing/wrong-typed entries field to [] rather than failing" do
      assert {:ok, %Plan{entries: []}} = Plan.from_json(%{})
      assert {:ok, %Plan{entries: []}} = Plan.from_json(%{"entries" => "not a list"})
      assert {:ok, %Plan{entries: []}} = Plan.from_json(%{"entries" => nil})
    end

    test "from_json/1 skips entries that individually fail to decode, keeping the valid ones" do
      raw = %{
        "entries" => [
          %{"content" => "ok", "priority" => "high", "status" => "pending"},
          %{"content" => "bad priority", "priority" => "urgent", "status" => "pending"},
          %{"content" => "missing status", "priority" => "low"},
          %{"content" => "ok2", "priority" => "low", "status" => "completed"}
        ]
      }

      assert {:ok, %Plan{entries: entries}} = Plan.from_json(raw)
      assert length(entries) == 2
      assert Enum.map(entries, & &1.content) == ["ok", "ok2"]
    end

    test "Jason.Encoder round-trips through real JSON" do
      plan = Plan.new([PlanEntry.new("x", :high, :pending)])
      encoded = Jason.encode!(plan)
      assert {:ok, decoded_json} = Jason.decode(encoded)
      assert {:ok, decoded} = Plan.from_json(decoded_json)
      assert length(decoded.entries) == 1
    end
  end
end
