defmodule Raxol.Swarm.DiscoveryTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log

  alias Raxol.Swarm.Discovery

  describe "start_link/1 with no strategy" do
    test "starts successfully with no config" do
      name = :"discovery_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = Discovery.start_link(name: name)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with gossip preset" do
    test "starts with gossip strategy" do
      name = :"discovery_gossip_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = Discovery.start_link(name: name, strategy: :gossip)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with epmd preset" do
    test "starts with epmd strategy and hosts" do
      name = :"discovery_epmd_#{System.unique_integer([:positive])}"

      assert {:ok, pid} =
               Discovery.start_link(
                 name: name,
                 strategy: :epmd,
                 hosts: [:"test@127.0.0.1"]
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts without error when hosts is empty" do
      name = :"discovery_epmd_empty_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = Discovery.start_link(name: name, strategy: :epmd, hosts: [])
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with dns preset" do
    test "starts with dns strategy" do
      name = :"discovery_dns_#{System.unique_integer([:positive])}"

      assert {:ok, pid} =
               Discovery.start_link(
                 name: name,
                 strategy: :dns,
                 query: "raxol.internal",
                 node_basename: "raxol"
               )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "starts without error when query is missing" do
      name = :"discovery_dns_noquery_#{System.unique_integer([:positive])}"
      assert {:ok, pid} = Discovery.start_link(name: name, strategy: :dns)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "start_link/1 with custom topologies" do
    test "passes raw topologies through" do
      name = :"discovery_custom_#{System.unique_integer([:positive])}"

      topologies = [
        test_cluster: [
          strategy: Cluster.Strategy.Epmd,
          config: [hosts: [:"x@127.0.0.1"]]
        ]
      ]

      assert {:ok, pid} = Discovery.start_link(name: name, topologies: topologies)
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "available?/0" do
    test "returns true when libcluster is installed" do
      assert Discovery.available?() == true
    end
  end
end
