defmodule Raxol.ACP.SupervisorTest do
  use ExUnit.Case, async: false

  setup do
    # Other test files may leave global state -- leftover JobSession
    # children, an incremented NonceServer counter -- behind. Reset the
    # bits this file's "initially" asserts touch so the asserts hold
    # regardless of test ordering.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Raxol.ACP.JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Raxol.ACP.JobSession.Supervisor, pid)
    end

    Raxol.ACP.Wallet.NonceServer.reset(0)

    :ok
  end

  test "supervisor is alive" do
    pid = Process.whereis(Raxol.ACP.Supervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "JobSession.Registry is reachable and empty" do
    assert Raxol.ACP.JobSession.Registry.whereis({8453, "nonexistent-job"}) == :undefined
  end

  test "JobSession.Registry.via/1 builds a usable :via tuple" do
    key = {8453, "smoketest-#{System.unique_integer([:positive])}"}
    via = Raxol.ACP.JobSession.Registry.via(key)
    assert match?({:via, Registry, {Raxol.ACP.JobSession.Registry, ^key}}, via)
  end

  test "registering a process via JobSession.Registry resolves with whereis/1" do
    key = {8453, "resolves-#{System.unique_integer([:positive])}"}

    {:ok, pid} =
      Agent.start_link(fn -> :ok end, name: Raxol.ACP.JobSession.Registry.via(key))

    assert Raxol.ACP.JobSession.Registry.whereis(key) == pid

    Agent.stop(pid)
  end

  test "default Wallet.NonceServer is running and at nonce 0" do
    assert is_pid(Process.whereis(Raxol.ACP.Wallet.NonceServer))
    assert Raxol.ACP.Wallet.NonceServer.peek() == 0
  end

  test "JobSession.Supervisor is running with zero active sessions initially" do
    assert is_pid(Process.whereis(Raxol.ACP.JobSession.Supervisor))
    assert DynamicSupervisor.count_children(Raxol.ACP.JobSession.Supervisor).active == 0
  end

  test "Offering.Registry is running and starts empty" do
    assert is_pid(Process.whereis(Raxol.ACP.Offering.Registry))
    Raxol.ACP.Offering.Registry.clear()
    assert Raxol.ACP.Offering.Registry.list_all() == []
  end
end
