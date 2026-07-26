defmodule Raxol.Symphony.OrchestratorPauseHostReconcileTest do
  @moduledoc """
  T2 reconciliation (#749): the host-slot pause/resume machinery (#746) and the
  parallel per-branch pause + TTL GC (#738) must coexist. These tests prove the
  unified invariants that neither branch covered alone:

    * an abandoned parked run past its TTL releases its reserved HOST slot (not
      just its workspace + claim + durable row), so #746's reservation cannot
      leak exactly when #738's GC fires;
    * a BATCH-origin paused branch keeps its host reserved, resumes on that same
      host, and -- if abandoned past the TTL -- has its host slot reclaimed by
      the GC.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Orchestrator.PausedSaver.Memory, as: MemorySaver
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory, as: MemoryTracker
  alias Raxol.Symphony.Worker.HostSpec

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({MemoryTracker, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    workspace_root =
      Path.join(System.tmp_dir!(), "sym_phr_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    table = :"sym_phr_paused_#{:erlang.unique_integer([:positive])}"
    saver = {MemorySaver, %{table: table}}
    MemorySaver.ensure_table(%{table: table})
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)

    %{workspace_root: workspace_root, saver: saver}
  end

  defp config(workspace_root, ssh_hosts, extra) do
    base = %{
      tracker: %{
        kind: "memory",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done", "Cancelled"]
      },
      workspace: %{root: workspace_root},
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 10, max_retry_backoff_ms: 60_000},
      codex: %{stall_timeout_ms: 0},
      runner: %{kind: "noop"},
      worker: %{ssh_hosts: ssh_hosts}
    }

    Config.from_workflow(%{config: Map.merge(base, extra), prompt_template: ""})
  end

  defp issue(id, identifier),
    do: %Issue{id: id, identifier: identifier, title: "T", state: "Todo"}

  # A paused-saver row shaped like a real parked entry, carrying the reserved
  # host so boot rehold has something to reserve.
  defp paused_entry(id, identifier, %HostSpec{} = host) do
    %{
      issue: issue(id, identifier),
      attempt: 0,
      workspace_path: "/tmp/#{identifier}",
      host: host,
      interrupt_reason: :awaiting_review,
      resume_token: "rt-#{id}",
      paused_at: System.monotonic_time(:millisecond),
      paused_at_system: System.system_time(:millisecond),
      last_event: nil,
      last_message: nil,
      turn_count: 0,
      tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
    }
  end

  defp start_orchestrator(config, saver, opts) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         [
           config: config,
           runner_module: Noop,
           auto_start_tick: false,
           name: nil,
           paused_saver: saver
         ] ++ opts},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp wait_until(pid, fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(pid, fun, deadline)
  end

  defp do_wait_until(pid, fun, deadline) do
    cond do
      fun.(Orchestrator.snapshot(pid)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("condition not met before timeout")

      true ->
        Process.sleep(10)
        do_wait_until(pid, fun, deadline)
    end
  end

  describe "boot rehold reserves a slot per paused entry (duplicated host)" do
    test "two paused entries on a duplicated host rehold two slots at boot", %{
      workspace_root: root,
      saver: {MemorySaver, saver_cfg} = saver
    } do
      # Preload two paused runs, both parked on the SAME physical host that the
      # config lists TWICE (two slots). At boot the orchestrator must rehold
      # BOTH slots -- the idempotent hold/2 short-circuit would rehold only one,
      # leaving the second free for a fresh worker to steal.
      {:ok, host} = HostSpec.normalize("ci@build-1")
      MemorySaver.put(saver_cfg, "a", paused_entry("a", "DUP-1", host))
      MemorySaver.put(saver_cfg, "b", paused_entry("b", "DUP-2", host))

      pid =
        start_orchestrator(
          config(root, ["ci@build-1", "ci@build-1"], %{}),
          saver,
          []
        )

      snap = Orchestrator.snapshot(pid)
      assert snap.counts.paused == 2
      assert snap.hosts == %{total: 2, free: 0, busy: 2}
    end
  end

  describe "sequential pause TTL GC releases the host slot" do
    test "an abandoned parked run past its TTL frees its reserved host slot", %{
      workspace_root: root,
      saver: saver
    } do
      MemoryTracker.put_issue(issue("a", "HP-1"))
      Noop.Director.set("HP-1", {:pause, :awaiting_review, "rt"})

      pid = start_orchestrator(config(root, ["ci@build-1"], %{}), saver, paused_max_age_ms: 1)
      :ok = Orchestrator.subscribe(pid)
      :ok = Orchestrator.tick_now(pid)
      wait_until(pid, fn s -> s.counts.paused == 1 end)

      # The parked run holds its single host slot.
      assert Orchestrator.snapshot(pid).hosts == %{total: 1, free: 0, busy: 1}

      # Re-dispatch after the GC must not re-pause, so the freed slot is
      # observable: make the issue stall on its next run.
      Noop.Director.set("HP-1", :stall)
      Process.sleep(5)
      :ok = Orchestrator.tick_now(pid)

      # The GC snapshot (emitted before same-tick re-dispatch) shows the host
      # slot released -- had the reservation leaked it would still read busy: 1.
      assert_receive {:symphony_event, :paused_gc, snap}, 2_000
      assert snap.counts.paused == 0
      assert snap.hosts.free == 1
    end
  end

  describe "batch-origin pause keeps and reclaims its host slot" do
    defp parallel_config(root, ssh_hosts),
      do:
        config(root, ssh_hosts, %{
          workflow_mode: :graph_parallel,
          workflow_parallelism: 3
        })

    test "a batch-paused branch keeps its host reserved and resumes on it", %{
      workspace_root: root,
      saver: saver
    } do
      MemoryTracker.put_issues([issue("a", "MP-1"), issue("b", "MP-2"), issue("c", "MP-3")])
      Noop.Director.set("MP-1", {:succeed_after, 5})
      Noop.Director.set("MP-2", {:pause, :awaiting_review, %{token: 7}})
      Noop.Director.set("MP-3", {:succeed_after, 5})

      pid =
        start_orchestrator(
          parallel_config(root, ["ci@build-1", "ci@build-2", "ci@build-3"]),
          saver,
          []
        )

      :ok = Orchestrator.tick_now(pid)
      wait_until(pid, fn s -> s.counts.paused == 1 end)

      # Only MP-2's slot stays reserved; the two completed siblings released
      # their reserved hosts on batch exit.
      assert Orchestrator.snapshot(pid).hosts == %{total: 3, free: 2, busy: 1}

      # The batch-origin paused entry carries its reserved host, so the resume
      # re-holds and runs on it; on completion it frees that slot (had it run
      # with host: nil the reserved slot would leak busy).
      :ok = Orchestrator.resume_run(pid, "b", :approved)
      wait_until(pid, fn s -> s.counts.paused == 0 and s.counts.running == 0 end)
      assert Orchestrator.snapshot(pid).hosts == %{total: 3, free: 3, busy: 0}
    end

    test "an abandoned batch-paused branch past its TTL has its host reclaimed", %{
      workspace_root: root,
      saver: saver
    } do
      MemoryTracker.put_issue(issue("b", "MP-2"))
      Noop.Director.set("MP-2", {:pause, :awaiting_review, %{token: 7}})

      pid =
        start_orchestrator(
          parallel_config(root, ["ci@build-1"]),
          saver,
          paused_max_age_ms: 1
        )

      :ok = Orchestrator.subscribe(pid)
      :ok = Orchestrator.tick_now(pid)
      wait_until(pid, fn s -> s.counts.paused == 1 end)
      assert Orchestrator.snapshot(pid).hosts == %{total: 1, free: 0, busy: 1}

      # Stall the re-dispatch so the GC-freed slot is observable rather than
      # immediately re-batched into a fresh pause.
      Noop.Director.set("MP-2", :stall)
      Process.sleep(5)
      :ok = Orchestrator.tick_now(pid)

      assert_receive {:symphony_event, :paused_gc, snap}, 2_000
      assert snap.counts.paused == 0
      assert snap.hosts.free == 1
    end
  end
end
