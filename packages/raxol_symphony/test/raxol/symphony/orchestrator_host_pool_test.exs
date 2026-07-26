defmodule Raxol.Symphony.OrchestratorHostPoolTest do
  @moduledoc """
  The `worker.ssh_hosts` gate (issue #742): sequential dispatch claims one
  host per worker (one-worker-lifetime-per-host) and defers issues when every
  host is busy; a freed host is re-filled on the next tick. With no hosts
  configured, dispatch is unchanged (no gating).

  Workers still run locally here — this slice ships the scheduling contract;
  the actual SSH transport lands in #743. `max_concurrent_agents` is set high
  so the host gate, not the concurrency cap, is what limits `running`.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator, WorkflowStore}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    :ok
  end

  defp config(ssh_hosts) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 10, max_retry_backoff_ms: 60_000},
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"},
        worker: %{ssh_hosts: ssh_hosts}
      },
      prompt_template: ""
    })
  end

  defp issue(id, identifier),
    do: %Issue{id: id, identifier: identifier, title: "T", state: "Todo"}

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator, config: config, runner_module: Noop, auto_start_tick: false, name: nil},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp put_three_stalled do
    Memory.put_issues([issue("a", "HP-1"), issue("b", "HP-2"), issue("c", "HP-3")])
    for id <- ~w(HP-1 HP-2 HP-3), do: Noop.Director.set(id, :stall)
  end

  test "no ssh_hosts: all eligible issues run, snapshot reports no host pool" do
    put_three_stalled()

    pid = start_orchestrator(config([]))
    :ok = Orchestrator.tick_now(pid)

    snap = Orchestrator.snapshot(pid)
    assert snap.counts.running == 3
    assert snap.hosts == nil
  end

  test "two hosts gate three issues to two concurrent workers" do
    put_three_stalled()

    pid = start_orchestrator(config(["ci@build-1", "ci@build-2"]))
    :ok = Orchestrator.tick_now(pid)

    snap = Orchestrator.snapshot(pid)
    assert snap.counts.running == 2
    assert snap.hosts == %{total: 2, free: 0, busy: 2}
  end

  test "stopping a worker frees its host, and the next tick re-fills the slot" do
    put_three_stalled()

    pid = start_orchestrator(config(["ci@build-1", "ci@build-2"]))
    :ok = Orchestrator.subscribe(pid)
    :ok = Orchestrator.tick_now(pid)

    snap = Orchestrator.snapshot(pid)
    assert snap.counts.running == 2
    [%{issue_id: stopped_id} | _] = snap.running

    # Stopping the worker releases its host slot.
    :ok = Orchestrator.stop_run(pid, stopped_id)
    assert_receive {:symphony_event, :worker_stopped, freed}, 2_000
    assert freed.counts.running == 1
    assert freed.hosts.free == 1

    # The freed host is claimed by a still-pending issue on the next tick.
    :ok = Orchestrator.tick_now(pid)
    refilled = Orchestrator.snapshot(pid)
    assert refilled.counts.running == 2
    assert refilled.hosts == %{total: 2, free: 0, busy: 2}
  end

  test "a host added by config hot-reload becomes an available slot on the next tick" do
    put_three_stalled()

    dir = Path.join(System.tmp_dir!(), "sym_hp_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    path = Path.join(dir, "WORKFLOW.md")
    on_exit(fn -> File.rm_rf!(dir) end)

    File.write!(path, workflow_md(["ci@build-1"]))
    store = start_supervised!({WorkflowStore, path: path, watch?: false})

    pid = start_orchestrator_with_store(store)
    :ok = Orchestrator.tick_now(pid)

    # One host gates the three issues to a single worker.
    assert Orchestrator.snapshot(pid).hosts == %{total: 1, free: 0, busy: 1}

    # Add a second host and reload the store; the next tick reconciles the
    # pool to two slots and fills the newly-added one.
    File.write!(path, workflow_md(["ci@build-1", "ci@build-2"]))
    {:ok, _config} = WorkflowStore.reload(store)

    :ok = Orchestrator.tick_now(pid)
    snap = Orchestrator.snapshot(pid)
    assert snap.hosts == %{total: 2, free: 0, busy: 2}
    assert snap.counts.running == 2
  end

  defp start_orchestrator_with_store(store) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         workflow_store: store, runner_module: Noop, auto_start_tick: false, name: nil},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp workflow_md(ssh_hosts) do
    hosts_yaml = Enum.map_join(ssh_hosts, "\n", &"    - #{&1}")

    """
    ---
    tracker:
      kind: memory
      active_states:
        - Todo
        - In Progress
      terminal_states:
        - Done
        - Cancelled
    polling:
      interval_ms: 60000
    agent:
      max_concurrent_agents: 10
      max_retry_backoff_ms: 60000
    codex:
      stall_timeout_ms: 0
    runner:
      kind: raxol_agent
    worker:
      ssh_hosts:
    #{hosts_yaml}
    ---
    prompt
    """
  end
end
