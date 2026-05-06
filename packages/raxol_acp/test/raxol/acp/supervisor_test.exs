defmodule Raxol.ACP.SupervisorTest do
  use ExUnit.Case, async: false

  test "supervisor is alive" do
    pid = Process.whereis(Raxol.ACP.Supervisor)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "Job.Registry is reachable and empty" do
    assert Raxol.ACP.Job.Registry.whereis("nonexistent-job") == :undefined
  end

  test "Job.Registry.via/1 builds a usable :via tuple" do
    job_id = "smoketest-#{System.unique_integer([:positive])}"
    via = Raxol.ACP.Job.Registry.via(job_id)
    assert match?({:via, Registry, {Raxol.ACP.Job.Registry, ^job_id}}, via)
  end

  test "registering a process via Job.Registry resolves with whereis/1" do
    job_id = "resolves-#{System.unique_integer([:positive])}"

    {:ok, pid} =
      Agent.start_link(fn -> :ok end, name: Raxol.ACP.Job.Registry.via(job_id))

    assert Raxol.ACP.Job.Registry.whereis(job_id) == pid

    Agent.stop(pid)
  end

  test "default Wallet.NonceServer is running and at nonce 0" do
    assert is_pid(Process.whereis(Raxol.ACP.Wallet.NonceServer))
    assert Raxol.ACP.Wallet.NonceServer.peek() == 0
  end

  test "Job.Supervisor is running with zero active jobs initially" do
    assert is_pid(Process.whereis(Raxol.ACP.Job.Supervisor))
    assert Raxol.ACP.Job.Supervisor.active_count() == 0
  end

  test "Offering.Registry is running and starts empty" do
    assert is_pid(Process.whereis(Raxol.ACP.Offering.Registry))
    Raxol.ACP.Offering.Registry.clear()
    assert Raxol.ACP.Offering.Registry.list_all() == []
  end
end
