defmodule Raxol.Symphony.OrchestratorRemoteDispatchTest do
  @moduledoc """
  Gate activation (issue #743): the host claimed by the #742 pool is threaded
  through dispatch into the runner's `opts[:host]`, so a runner (Codex) can
  route its work to that host over SSH. With no hosts configured, the runner
  receives `host: nil` and runs locally.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
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

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    Memory.put_issue(%Issue{id: "a", identifier: "RD-1", title: "T", state: "Todo"})
    :ok
  end

  defp config(ssh_hosts) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo"],
          terminal_states: ["Done"]
        },
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 10, max_retry_backoff_ms: 60_000},
        runner: %{kind: "noop", agent: %{report_to: self()}},
        worker: %{ssh_hosts: ssh_hosts}
      },
      prompt_template: ""
    })
  end

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         config: config, runner_module: HostReportingRunner, auto_start_tick: false, name: nil},
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
end
