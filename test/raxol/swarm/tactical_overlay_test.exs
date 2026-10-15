defmodule Raxol.Swarm.TacticalOverlayTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Swarm.TacticalOverlay

  setup do
    name = :"overlay_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      TacticalOverlay.start_link(
        name: name,
        node_id: :test@host,
        sync_interval_ms: 60_000,
        anti_entropy_interval_ms: 60_000,
        peers: []
      )

    %{overlay: name, pid: pid}
  end

  describe "entities" do
    test "starts with no entities", %{overlay: overlay} do
      assert [] = TacticalOverlay.get_all_entities(overlay)
    end

    test "update_entity adds an entity", %{overlay: overlay} do
      TacticalOverlay.update_entity(overlay, :ship_1, %{
        position: {0.5, 0.5, 0.0},
        heading: 90.0,
        status: :active,
        metadata: %{}
      })

      Process.sleep(10)

      entities = TacticalOverlay.get_all_entities(overlay)
      assert length(entities) == 1
      [entity] = entities
      assert entity.id == :ship_1
      assert entity.node == :test@host
      assert entity.status == :active
    end

    test "update_entity overwrites existing", %{overlay: overlay} do
      TacticalOverlay.update_entity(overlay, :ship_1, %{
        position: {0.1, 0.1, 0.0},
        status: :active
      })

      Process.sleep(10)

      TacticalOverlay.update_entity(overlay, :ship_1, %{
        position: {0.9, 0.9, 0.0},
        status: :damaged
      })

      Process.sleep(10)

      entities = TacticalOverlay.get_all_entities(overlay)
      assert length(entities) == 1
      [entity] = entities
      assert entity.status == :damaged
    end
  end

  describe "waypoints" do
    test "starts with no waypoints", %{overlay: overlay} do
      assert [] = TacticalOverlay.get_all_waypoints(overlay)
    end

    test "add_waypoint adds to set", %{overlay: overlay} do
      wp = %{
        id: "wp_1",
        position: {0.5, 0.5, 0.0},
        label: "Rally Point",
        created_by: :test@host,
        created_at: System.monotonic_time(:millisecond)
      }

      TacticalOverlay.add_waypoint(overlay, wp)
      Process.sleep(10)

      waypoints = TacticalOverlay.get_all_waypoints(overlay)
      assert length(waypoints) == 1
      assert hd(waypoints).label == "Rally Point"
    end

    test "remove_waypoint removes from set", %{overlay: overlay} do
      wp = %{
        id: "wp_1",
        position: {0.5, 0.5, 0.0},
        label: "Rally Point",
        created_by: :test@host,
        created_at: System.monotonic_time(:millisecond)
      }

      TacticalOverlay.add_waypoint(overlay, wp)
      Process.sleep(10)
      assert length(TacticalOverlay.get_all_waypoints(overlay)) == 1

      TacticalOverlay.remove_waypoint(overlay, "wp_1")
      Process.sleep(10)
      assert TacticalOverlay.get_all_waypoints(overlay) == []
    end
  end

  describe "annotations" do
    test "add_annotation stores data", %{overlay: overlay} do
      TacticalOverlay.add_annotation(overlay, "note_1", %{text: "Enemy spotted"})
      Process.sleep(10)

      state = TacticalOverlay.get_overlay_state(overlay)
      assert Map.has_key?(state.annotations, "note_1")
      assert state.annotations["note_1"].text == "Enemy spotted"
    end
  end

  describe "overlay_state" do
    test "returns complete state", %{overlay: overlay} do
      TacticalOverlay.update_entity(overlay, :ship_1, %{status: :active})
      Process.sleep(10)

      state = TacticalOverlay.get_overlay_state(overlay)
      assert is_map(state.entities)
      assert is_list(state.waypoints)
      assert is_map(state.annotations)
      assert state.node_id == :test@host
      assert state.peers == []
    end
  end

  describe "subscribe" do
    test "receives entity update events", %{overlay: overlay} do
      TacticalOverlay.subscribe(overlay)

      TacticalOverlay.update_entity(overlay, :ship_1, %{status: :active})
      assert_receive {:overlay_event, {:entity_updated, :ship_1, _data}}, 1_000
    end

    test "receives waypoint events", %{overlay: overlay} do
      TacticalOverlay.subscribe(overlay)

      wp = %{
        id: "wp_1",
        position: {0.5, 0.5, 0.0},
        label: "Point A",
        created_by: :test@host,
        created_at: System.monotonic_time(:millisecond)
      }

      TacticalOverlay.add_waypoint(overlay, wp)
      assert_receive {:overlay_event, {:waypoint_added, ^wp}}, 1_000
    end
  end

  describe "auto-discovery via NodeMonitor events" do
    test "adds peer on :node_up swarm event", %{overlay: overlay, pid: pid} do
      send(pid, {:swarm_event, {:node_up, :new_peer@host}})
      Process.sleep(10)

      state = TacticalOverlay.get_overlay_state(overlay)
      assert :new_peer@host in state.peers
    end

    test "removes peer on :node_down swarm event", %{overlay: overlay, pid: pid} do
      send(pid, {:swarm_event, {:node_up, :temp_peer@host}})
      Process.sleep(10)

      send(pid, {:swarm_event, {:node_down, :temp_peer@host}})
      Process.sleep(10)

      state = TacticalOverlay.get_overlay_state(overlay)
      refute :temp_peer@host in state.peers
    end

    test "duplicate node_up does not create duplicate peer", %{pid: pid, overlay: overlay} do
      send(pid, {:swarm_event, {:node_up, :dup_peer@host}})
      send(pid, {:swarm_event, {:node_up, :dup_peer@host}})
      Process.sleep(10)

      state = TacticalOverlay.get_overlay_state(overlay)
      assert Enum.count(state.peers, &(&1 == :dup_peer@host)) == 1
    end

    test "ignores unrelated swarm events", %{pid: pid, overlay: overlay} do
      send(pid, {:swarm_event, {:status_change, :x@host, :healthy, :suspect}})
      Process.sleep(10)

      state = TacticalOverlay.get_overlay_state(overlay)
      assert state.peers == []
    end
  end

  describe "delta receive" do
    test "merges remote entity updates", %{overlay: overlay} do
      alias Raxol.Swarm.CRDT.LWWRegister

      remote_entity = %{id: :remote_ship, status: :active, position: {0.3, 0.3, 0.0}}
      remote_reg = LWWRegister.new(remote_entity, :remote@host)

      TacticalOverlay.receive_delta(overlay, :remote@host, [
        {:update_entity, :remote_ship, remote_reg}
      ])

      Process.sleep(10)

      entities = TacticalOverlay.get_all_entities(overlay)
      assert length(entities) == 1
      assert hd(entities).id == :remote_ship
    end
  end

  describe "full state merge" do
    test "merges remote full state", %{overlay: overlay} do
      alias Raxol.Swarm.CRDT.{LWWRegister, ORSet}

      # Add local entity
      TacticalOverlay.update_entity(overlay, :local_ship, %{status: :active})
      Process.sleep(10)

      # Create remote state
      remote_entity = %{id: :remote_ship, status: :active}
      remote_reg = LWWRegister.new(remote_entity, :remote@host)

      remote_wp = %{id: "rwp", label: "Remote WP", position: {0.1, 0.1, 0.0}}
      remote_waypoints = ORSet.new() |> ORSet.add(remote_wp, :remote@host)

      remote_state = %{
        entities: %{remote_ship: remote_reg},
        waypoints: remote_waypoints,
        annotations: %{}
      }

      TacticalOverlay.receive_full_state(overlay, :remote@host, remote_state)
      Process.sleep(10)

      # Both entities should exist
      entities = TacticalOverlay.get_all_entities(overlay)
      assert length(entities) == 2

      # Remote waypoint should exist
      waypoints = TacticalOverlay.get_all_waypoints(overlay)
      assert length(waypoints) == 1
    end
  end
end
