defmodule Raxol.Security.UserContextTest do
  # The context server is a singleton registered under a global name.
  use ExUnit.Case, async: false

  alias Raxol.Security.UserContext
  alias Raxol.Security.UserContext.ContextServer

  # A server left running by an earlier test would hide an unnamed start.
  setup do
    if pid = Process.whereis(ContextServer), do: GenServer.stop(pid)
    :ok
  end

  describe "server naming" do
    test "the public API starts and reaches the server on first use" do
      assert :ok = UserContext.set_current_user("alice")
      assert UserContext.get_current_user() == "alice"

      GenServer.stop(ContextServer)
    end
  end

  describe "caller cleanup" do
    # Monitors are keyed by pid, so the `:DOWN` handler has to drop them by
    # pid too; dropping by monitor ref leaves one entry per caller forever.
    test "forgets a dead caller's context and monitor" do
      start_supervised!(ContextServer)
      parent = self()

      caller =
        spawn(fn ->
          :ok = UserContext.set_current_user("bob")
          send(parent, :user_set)
          receive(do: (:stop -> :ok))
        end)

      assert_receive :user_set
      ref = Process.monitor(caller)
      send(caller, :stop)
      assert_receive {:DOWN, ^ref, :process, ^caller, :normal}

      state = :sys.get_state(ContextServer)
      assert state.contexts == %{}
      assert state.monitors == %{}
    end
  end
end
