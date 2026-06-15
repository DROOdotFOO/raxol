defmodule Raxol.Core.Events.CloudEventTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Events.CloudEvent
  alias Raxol.Core.Events.Event

  describe "new/3" do
    test "sets required fields with defaults" do
      ce = CloudEvent.new("raxol.key", "raxol://node-1")

      assert ce.specversion == "1.0"
      assert ce.type == "raxol.key"
      assert ce.source == "raxol://node-1"
      assert is_binary(ce.id) and byte_size(ce.id) == 16
      assert %DateTime{} = ce.time
      assert ce.data == nil
    end

    test "carries optional fields" do
      time = ~U[2026-06-14 12:00:00Z]

      ce =
        CloudEvent.new("raxol.timer", "raxol://node-1",
          id: "fixed",
          time: time,
          data: %{tick: 1},
          datacontenttype: "application/json",
          subject: "ticker"
        )

      assert ce.id == "fixed"
      assert ce.time == time
      assert ce.data == %{tick: 1}
      assert ce.datacontenttype == "application/json"
      assert ce.subject == "ticker"
    end

    test "ids are unique across calls" do
      ids = for _ <- 1..20, do: CloudEvent.new("raxol.x", "raxol://x").id
      assert Enum.uniq(ids) == ids
    end
  end

  describe "to_map/1" do
    test "includes required fields and drops nil optionals" do
      ce = CloudEvent.new("raxol.key", "raxol://node-1", time: nil)
      map = CloudEvent.to_map(ce)

      assert Map.has_key?(map, :specversion)
      assert Map.has_key?(map, :id)
      assert Map.has_key?(map, :source)
      assert Map.has_key?(map, :type)
      refute Map.has_key?(map, :time)
      refute Map.has_key?(map, :data)
      refute Map.has_key?(map, :datacontenttype)
      refute Map.has_key?(map, :subject)
    end

    test "includes present optional fields" do
      ce =
        CloudEvent.new("raxol.timer", "raxol://node-1",
          data: %{tick: 1},
          subject: "ticker"
        )

      map = CloudEvent.to_map(ce)

      assert map.data == %{tick: 1}
      assert map.subject == "ticker"
    end
  end

  describe "from_map/1" do
    test "rebuilds from atom-keyed map" do
      original = CloudEvent.new("raxol.key", "raxol://node-1", data: :payload)
      {:ok, ce} = original |> CloudEvent.to_map() |> CloudEvent.from_map()

      assert ce.id == original.id
      assert ce.source == original.source
      assert ce.type == original.type
      assert ce.data == :payload
    end

    test "rebuilds from string-keyed map" do
      map = %{
        "specversion" => "1.0",
        "id" => "abc123",
        "source" => "external://producer",
        "type" => "com.example.thing",
        "data" => %{"k" => "v"}
      }

      assert {:ok, ce} = CloudEvent.from_map(map)
      assert ce.id == "abc123"
      assert ce.source == "external://producer"
      assert ce.type == "com.example.thing"
      assert ce.data == %{"k" => "v"}
    end

    test "rejects missing id" do
      map = %{source: "x", type: "y"}
      assert CloudEvent.from_map(map) == {:error, :missing_required_field}
    end

    test "rejects missing source" do
      map = %{id: "1", type: "y"}
      assert CloudEvent.from_map(map) == {:error, :missing_required_field}
    end

    test "rejects missing type" do
      map = %{id: "1", source: "x"}
      assert CloudEvent.from_map(map) == {:error, :missing_required_field}
    end

    test "rejects empty required field" do
      map = %{id: "", source: "x", type: "y"}
      assert CloudEvent.from_map(map) == {:error, :missing_required_field}
    end
  end

  describe "Event.to_cloud_event/2" do
    test "prefixes type with 'raxol.' and carries data and timestamp" do
      time = ~U[2026-06-14 12:00:00Z]
      event = Event.new(:key, %{key: :enter}, time)

      ce = Event.to_cloud_event(event, source: "raxol://node-7")

      assert ce.type == "raxol.key"
      assert ce.source == "raxol://node-7"
      assert ce.data == %{key: :enter}
      assert ce.time == time
    end

    test "falls back to app env source then default" do
      Application.delete_env(:raxol_core, :event_source)
      event = Event.new(:timer, :tick)
      ce = Event.to_cloud_event(event)
      assert ce.source == "raxol://localhost"

      Application.put_env(:raxol_core, :event_source, "raxol://configured")
      ce2 = Event.to_cloud_event(event)
      assert ce2.source == "raxol://configured"
    after
      Application.delete_env(:raxol_core, :event_source)
    end
  end

  describe "Event.from_cloud_event/1" do
    test "round-trips a raxol event" do
      original = Event.new(:key, %{key: :enter})
      ce = Event.to_cloud_event(original, source: "raxol://x")
      assert {:ok, event} = Event.from_cloud_event(ce)

      assert event.type == :key
      assert event.data == %{key: :enter}
      assert event.timestamp == original.timestamp
    end

    test "handles foreign type without 'raxol.' prefix when atom exists" do
      _ = :timer
      ce = CloudEvent.new("timer", "external://x", data: :payload)
      assert {:ok, event} = Event.from_cloud_event(ce)
      assert event.type == :timer
      assert event.data == :payload
    end

    test "returns error for unknown atom type" do
      ce =
        CloudEvent.new(
          "raxol.never_loaded_as_atom_qwertyuiop_xyz_123",
          "raxol://x"
        )

      assert Event.from_cloud_event(ce) == {:error, :unknown_event_type}
    end

    test "uses now() when CloudEvent.time is nil" do
      ce = CloudEvent.new("raxol.timer", "raxol://x", time: nil)
      {:ok, event} = Event.from_cloud_event(ce)
      assert %DateTime{} = event.timestamp
    end
  end
end
