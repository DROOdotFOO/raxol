defmodule Raxol.UI.State.StoreTest do
  # The store server is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.UI.State.Management.StateManagementServer, as: Server
  alias Raxol.UI.State.Store

  # A server left running by an earlier test would hide an unnamed start.
  setup do
    if pid = Process.whereis(Server), do: GenServer.stop(pid)
    :ok
  end

  describe "server naming" do
    test "the public API starts and reaches the server on first use" do
      assert Store.get_state([]) == %{}
      assert :ok = Store.update_state([:count], 1)
      assert Store.get_state([:count]) == 1

      GenServer.stop(Server)
    end

    test "the public API uses a supervised server instead of starting another" do
      pid = start_supervised!({Server, initial_state: %{count: 7}})

      assert Store.get_state([:count]) == 7
      assert Process.whereis(Server) == pid
    end
  end

  describe "component cleanup" do
    test "drops a dead component's hook state" do
      start_supervised!(Server)
      component = spawn(fn -> receive(do: (:stop -> :ok)) end)

      :ok = Server.set_component_id(:counter, component)
      :ok = Server.set_hook_state(:counter, :use_state_0, 42)
      assert Server.get_hook_state(:counter, :use_state_0) == 42

      ref = Process.monitor(component)
      send(component, :stop)
      assert_receive {:DOWN, ^ref, :process, ^component, :normal}

      assert Server.get_hook_state(:counter, :use_state_0) == nil
    end
  end
end
