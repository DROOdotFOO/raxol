defmodule Raxol.Symphony.OrchestratorRemoteDispatchTest do
  @moduledoc """
  Gate activation (issue #743): the host claimed by the #742 pool is threaded
  through dispatch into the runner's `opts[:host]`, so a runner (Codex) can
  route its work to that host over SSH. With no hosts configured, the runner
  receives `host: nil` and runs locally.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Test.FakeSsh
  alias Raxol.Symphony.Trackers.Memory
  alias Raxol.Symphony.Worker.HostSpec

  # A runner that reports the `:host` it was dispatched with back to the test
  # pid stashed in the (passthrough) `runner.agent` config.
  defmodule HostReportingRunner do
    @behaviour Raxol.Symphony.Runner

    @impl true
    def run(_issue, %Config{runner: %{agent: agent}}, opts) do
      case Map.get(agent, :report_to) do
        pid when is_pid(pid) -> send(pid, {:runner_host, Keyword.get(opts, :host)})
        _ -> :ok
      end

      :ok
    end
  end

  # A runner that pauses on its first turn and reports the `:host` it saw on
  # BOTH the initial dispatch and the resume, so a test can prove the resumed
  # worker runs on its original host rather than locally (host: nil).
  defmodule PauseResumeHostRunner do
    @behaviour Raxol.Symphony.Runner

    @impl true
    def run(_issue, %Config{runner: %{agent: agent}}, opts) do
      pid = Map.get(agent, :report_to)
      host = Keyword.get(opts, :host)

      case Keyword.get(opts, :resume_token) do
        nil ->
          if is_pid(pid), do: send(pid, {:runner_host, :initial, host})
          {:pause, :awaiting_review, "rt"}

        _token ->
          if is_pid(pid), do: send(pid, {:runner_host, :resumed, host})
          :ok
      end
    end
  end

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    Memory.put_issue(%Issue{id: "a", identifier: "RD-1", title: "T", state: "Todo"})

    workspace_root =
      Path.join(System.tmp_dir!(), "sym_rd_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    %{workspace_root: workspace_root}
  end

  defp config(ssh_hosts, extra \\ %{}) do
    base = %{
      tracker: %{
        kind: "memory",
        active_states: ["Todo"],
        terminal_states: ["Done"]
      },
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 10, max_retry_backoff_ms: 60_000},
      runner: %{kind: "noop", agent: %{report_to: self()}},
      worker: %{ssh_hosts: ssh_hosts}
    }

    Config.from_workflow(%{config: Map.merge(base, extra), prompt_template: ""})
  end

  defp wait_until(pid, fun, timeout_ms \\ 2_000) do
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

  defp start_orchestrator(config, runner_module \\ HostReportingRunner) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         config: config,
         runner_module: runner_module,
         auto_start_tick: false,
         name: nil,
         ssh: FakeSsh.opts()},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  test "a claimed host is passed to the runner as opts[:host]" do
    pid = start_orchestrator(config([%{host: "build-1", user: "ci"}]))
    :ok = Orchestrator.tick_now(pid)

    assert_receive {:runner_host, %HostSpec{host: "build-1", user: "ci"}}, 2_000
  end

  test "with no hosts the runner receives host: nil (local dispatch)" do
    pid = start_orchestrator(config([]))
    :ok = Orchestrator.tick_now(pid)

    assert_receive {:runner_host, nil}, 2_000
  end

  test "a resumed run runs on its ORIGINAL host, not locally (host: nil)", %{
    workspace_root: root
  } do
    pid =
      start_orchestrator(
        config([%{host: "build-1", user: "ci"}], %{workspace: %{root: root}}),
        PauseResumeHostRunner
      )

    :ok = Orchestrator.tick_now(pid)

    # Initial dispatch reserved and used build-1.
    assert_receive {:runner_host, :initial, %HostSpec{host: "build-1", user: "ci"}}, 2_000

    # Wait for the pause to be parked (the :run_paused message + :normal exit
    # are async relative to the runner reply above).
    wait_until(pid, fn s -> s.counts.paused == 1 end)

    :ok = Orchestrator.resume_run(pid, "a", :approved)

    # The resumed worker must receive the SAME host, not nil. Before the fix
    # spawn_resume_worker_task dropped :host and this arrived as nil.
    assert_receive {:runner_host, :resumed, %HostSpec{host: "build-1", user: "ci"}}, 2_000
  end
end
