defmodule Raxol.UI.State.StoreTest do
  # The store server is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.UI.State.Management.StateManagementServer, as: Server
  alias Raxol.UI.State.Store

  # A server left running by an earlier test would hide an unnamed start.
  # The public API starts the server unlinked, so it outlives each test
  # unless stopped here.
  setup do
    stop_server()
    on_exit(&stop_server/0)
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

    test "the server outlives the process that first called the API" do
      parent = self()

      starter =
        spawn(fn ->
          :ok = Store.update_state([:count], 3)
          send(parent, {:started, Process.whereis(Server)})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, pid}, 500
      assert is_pid(pid)
      ref = Process.monitor(pid)

      Process.exit(starter, :kill)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert Process.whereis(Server) == pid
      assert Store.get_state([:count]) == 3
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

  defp stop_server do
    case Process.whereis(Server) do
      nil ->
        :ok

      pid ->
        try do
          GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
