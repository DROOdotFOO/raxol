defmodule Raxol.RBACTest do
  # The RBAC agent is a VM-wide singleton registered under its module name.
  use ExUnit.Case, async: false

  alias Raxol.RBAC

  setup do
    stop_rbac()
    on_exit(&stop_rbac/0)
  end

  describe "lazy start" do
    test "roles outlive the process that first called the API" do
      parent = self()

      starter =
        spawn(fn ->
          :ok = RBAC.define_role(:admin, [:read, :write])
          :ok = RBAC.assign_role("alice", :admin)
          send(parent, {:started, Process.whereis(RBAC)})
          Process.sleep(:infinity)
        end)

      assert_receive {:started, pid}, 500
      assert is_pid(pid)
      ref = Process.monitor(pid)

      Process.exit(starter, :kill)

      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 100
      assert Process.whereis(RBAC) == pid
      assert RBAC.can?("alice", :write)
      assert Enum.sort(RBAC.get_permissions("alice")) == [:read, :write]
    end
  end

  defp stop_rbac do
    case Process.whereis(RBAC) do
      nil ->
        :ok

      pid ->
        try do
          Agent.stop(pid)
        catch
          :exit, _ -> :ok
        end
    end
  end
end
