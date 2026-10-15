defmodule Raxol.Swarm.TopologyTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Swarm.Topology

  setup do
    name = :"topology_#{System.unique_integer([:positive])}"
    {:ok, pid} = Topology.start_link(name: name, node_id: :self@host)
    %{topo: name, pid: pid}
  end

  describe "initial state" do
    test "self is commander when alone", %{topo: topo} do
      assert :commander = Topology.get_role(topo)
      assert {:ok, :self@host} = Topology.get_commander(topo)
    end

    test "node count starts at 1", %{topo: topo} do
      assert 1 = Topology.node_count(topo)
    end

    test "lists self", %{topo: topo} do
      nodes = Topology.list_nodes(topo)
      assert {:self@host, :commander} in nodes
    end
  end

  describe "node_joined/2" do
    test "adds node as wingmate", %{topo: topo} do
      Topology.node_joined(topo, :wing@host)
      Process.sleep(10)

      assert 2 = Topology.node_count(topo)
      nodes = Topology.list_nodes(topo)
      assert {:wing@host, :wingmate} in nodes
    end

    test "duplicate join is a no-op", %{topo: topo} do
      Topology.node_joined(topo, :wing@host)
      Topology.node_joined(topo, :wing@host)
      Process.sleep(10)

      assert 2 = Topology.node_count(topo)
    end
  end

  describe "node_left/2" do
    test "removes node", %{topo: topo} do
      Topology.node_joined(topo, :wing@host)
      Process.sleep(10)
      assert 2 = Topology.node_count(topo)

      Topology.node_left(topo, :wing@host)
      Process.sleep(10)
      assert 1 = Topology.node_count(topo)
    end

    test "re-elects when commander leaves", %{topo: topo} do
      # Add a wingmate then promote it
      Topology.node_joined(topo, :wing@host)
      Process.sleep(10)

      # Promote wing to commander (simulating external election)
      Topology.promote(topo, :wing@host, :commander)

      # Now remove the commander
      Topology.node_left(topo, :wing@host)
      Process.sleep(10)

      # Self should become commander again
      assert {:ok, :self@host} = Topology.get_commander(topo)
    end
  end

  describe "promote/3" do
    test "promotes a known node", %{topo: topo} do
      Topology.node_joined(topo, :wing@host)
      Process.sleep(10)

      assert :ok = Topology.promote(topo, :wing@host, :observer)
      nodes = Topology.list_nodes(topo)
      assert {:wing@host, :observer} in nodes
    end

    test "errors on unknown node", %{topo: topo} do
      assert {:error, :unknown_node} = Topology.promote(topo, :ghost@host, :observer)
    end
  end

  describe "request_role/2" do
    test "changes own role", %{topo: topo} do
      assert :ok = Topology.request_role(topo, :relay)
      assert :relay = Topology.get_role(topo)
    end
  end

  describe "auto-discovery via NodeMonitor events" do
    test "adds node on :node_up swarm event", %{topo: topo, pid: pid} do
      send(pid, {:swarm_event, {:node_up, :discovered@host}})
      Process.sleep(10)

      assert 2 = Topology.node_count(topo)
      nodes = Topology.list_nodes(topo)
      assert {:discovered@host, :wingmate} in nodes
    end

    test "removes node on :node_down swarm event", %{topo: topo, pid: pid} do
      send(pid, {:swarm_event, {:node_up, :discovered@host}})
      Process.sleep(10)
      assert 2 = Topology.node_count(topo)

      send(pid, {:swarm_event, {:node_down, :discovered@host}})
      Process.sleep(10)
      assert 1 = Topology.node_count(topo)
    end

    test "re-elects commander when discovered node leaves", %{topo: topo, pid: pid} do
      # Add via discovery and promote to commander
      send(pid, {:swarm_event, {:node_up, :leader@host}})
      Process.sleep(10)
      Topology.promote(topo, :leader@host, :commander)

      # Remove the commander via discovery event
      send(pid, {:swarm_event, {:node_down, :leader@host}})
      Process.sleep(10)

      # Self should become commander again
      assert {:ok, :self@host} = Topology.get_commander(topo)
    end

    test "duplicate node_up is a no-op", %{topo: topo, pid: pid} do
      send(pid, {:swarm_event, {:node_up, :dup@host}})
      send(pid, {:swarm_event, {:node_up, :dup@host}})
      Process.sleep(10)

      assert 2 = Topology.node_count(topo)
    end

    test "ignores unrelated swarm events", %{topo: topo, pid: pid} do
      send(pid, {:swarm_event, {:status_change, :x@host, :healthy, :suspect}})
      Process.sleep(10)
      assert 1 = Topology.node_count(topo)
    end
  end

  describe "quorum" do
    test "no commander without quorum" do
      name = :"topo_quorum_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Topology.start_link(name: name, node_id: :alone@host, quorum_size: 3)

      assert {:error, :no_commander} = Topology.get_commander(name)
    end
  end
end
