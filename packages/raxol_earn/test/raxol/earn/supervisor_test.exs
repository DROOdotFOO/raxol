defmodule Raxol.Earn.SupervisorTest do
  use ExUnit.Case, async: false

  setup do
    # Other test files may leave global state -- leftover JobSession
    # children, an incremented NonceServer counter -- behind. Reset the
    # bits this file's "initially" asserts touch so the asserts hold
    # regardless of test ordering.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Raxol.Earn.JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Raxol.Earn.JobSession.Supervisor, pid)
    end

    Raxol.Earn.Wallet.NonceServer.reset(0)

    :ok
  end

  test "supervisor is alive" do
    pid = Process.whereis(Raxol.Earn.Supervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "JobSession.Registry is reachable and empty" do
    assert Raxol.Earn.JobSession.Registry.whereis({8453, "nonexistent-job"}) == :undefined
  end

  test "JobSession.Registry.via/1 builds a usable :via tuple" do
    key = {8453, "smoketest-#{System.unique_integer([:positive])}"}
    via = Raxol.Earn.JobSession.Registry.via(key)
    assert match?({:via, Registry, {Raxol.Earn.JobSession.Registry, ^key}}, via)
  end

  test "registering a process via JobSession.Registry resolves with whereis/1" do
    key = {8453, "resolves-#{System.unique_integer([:positive])}"}

    {:ok, pid} =
      Agent.start_link(fn -> :ok end, name: Raxol.Earn.JobSession.Registry.via(key))

    assert Raxol.Earn.JobSession.Registry.whereis(key) == pid

    Agent.stop(pid)
  end

  test "default Wallet.NonceServer is running and at nonce 0" do
    assert is_pid(Process.whereis(Raxol.Earn.Wallet.NonceServer))
    assert Raxol.Earn.Wallet.NonceServer.peek() == 0
  end

  test "JobSession.Supervisor is running with zero active sessions initially" do
    assert is_pid(Process.whereis(Raxol.Earn.JobSession.Supervisor))
    assert DynamicSupervisor.count_children(Raxol.Earn.JobSession.Supervisor).active == 0
  end

  test "Offering.Registry is running and starts empty" do
    assert is_pid(Process.whereis(Raxol.Earn.Offering.Registry))
    Raxol.Earn.Offering.Registry.clear()
    assert Raxol.Earn.Offering.Registry.list_all() == []
  end
end
