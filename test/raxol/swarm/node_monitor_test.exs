defmodule Raxol.Swarm.NodeMonitorTest do
  use ExUnit.Case, async: false
  @moduletag :capture_log

  alias Raxol.Swarm.NodeMonitor

  setup do
    # Use a unique name to avoid conflicts
    name = :"node_monitor_#{System.unique_integer([:positive])}"
    {:ok, pid} = NodeMonitor.start_link(name: name, ping_interval_ms: 60_000)
    %{monitor: name, pid: pid}
  end

  describe "start_link/1" do
    test "starts with empty node list", %{monitor: monitor} do
      assert NodeMonitor.list_healthy(monitor) == []
      assert NodeMonitor.list_suspect(monitor) == []
      assert NodeMonitor.list_all(monitor) == []
    end
  end

  describe "get_health/2" do
    test "returns error for unknown node", %{monitor: monitor} do
      assert {:error, :unknown} = NodeMonitor.get_health(monitor, :unknown@host)
    end
  end

  describe "subscribe/1" do
    test "receives node_up events", %{monitor: monitor} do
      NodeMonitor.subscribe(monitor)
      # Simulate a nodeup message
      send(Process.whereis(monitor) || GenServer.whereis(monitor), {:nodeup, :test@host})

      assert_receive {:swarm_event, {:node_up, :test@host}}, 1_000
    end

    test "receives node_down events", %{monitor: monitor} do
      NodeMonitor.subscribe(monitor)
      # First add the node
      send(GenServer.whereis(monitor), {:nodeup, :test@host})
      assert_receive {:swarm_event, {:node_up, :test@host}}, 1_000

      # Then take it down
      send(GenServer.whereis(monitor), {:nodedown, :test@host})
      assert_receive {:swarm_event, {:node_down, :test@host}}, 1_000
    end
  end

  describe "unsubscribe/1" do
    test "stops receiving events after unsubscribe", %{monitor: monitor} do
      NodeMonitor.subscribe(monitor)
      NodeMonitor.unsubscribe(monitor)

      send(GenServer.whereis(monitor), {:nodeup, :test@host})
      refute_receive {:swarm_event, _}, 100
    end
  end

  describe "nodeup handling" do
    test "adds node to healthy list", %{monitor: monitor} do
      send(GenServer.whereis(monitor), {:nodeup, :new@host})
      # Give it a moment to process
      Process.sleep(10)

      assert {:ok, record} = NodeMonitor.get_health(monitor, :new@host)
      assert record.status == :healthy
      assert record.node == :new@host
    end
  end

  describe "nodedown handling" do
    test "marks node as down", %{monitor: monitor} do
      send(GenServer.whereis(monitor), {:nodeup, :new@host})
      Process.sleep(10)

      send(GenServer.whereis(monitor), {:nodedown, :new@host})
      Process.sleep(10)

      assert {:ok, record} = NodeMonitor.get_health(monitor, :new@host)
      assert record.status == :down
    end
  end
end
