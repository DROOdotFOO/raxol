defmodule Raxol.Symphony.OrchestratorWorkflowModeTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    :ok
  end

  defp issue(id, identifier, state) do
    %Issue{
      id: id,
      identifier: identifier,
      title: "T-#{identifier}",
      state: state
    }
  end

  defp build_config(workflow_mode) do
    raw = %{
      tracker: %{
        kind: "memory",
        active_states: ["Todo", "In Progress"],
        terminal_states: ["Done", "Cancelled"]
      },
      polling: %{interval_ms: 60_000},
      agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
      codex: %{stall_timeout_ms: 0},
      runner: %{kind: "noop"}
    }

    raw =
      case workflow_mode do
        nil -> raw
        mode -> Map.put(raw, :workflow_mode, mode)
      end

    Config.from_workflow(%{config: raw, prompt_template: ""})
  end

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         config: config, runner_module: Noop, auto_start_tick: false, name: nil},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp wait_until(timeout_ms \\ 1_000, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(20)
        do_wait_until(deadline, fun)
    end
  end

  describe "config.workflow_mode" do
    test "defaults to :default when absent" do
      config = build_config(nil)
      assert config.workflow_mode == :default
    end

    test "string \"graph\" coerces to :graph" do
      config = build_config("graph")
      assert config.workflow_mode == :graph
    end

    test "atom :graph stays :graph" do
      config = build_config(:graph)
      assert config.workflow_mode == :graph
    end

    test "unknown values fall back to :default" do
      config = build_config("nonsense")
      assert config.workflow_mode == :default
    end
  end

  describe "orchestrator dispatch with workflow_mode :graph" do
    test "dispatches an eligible issue through the graph runtime" do
      config = build_config(:graph)
      Memory.put_issue(issue("g1", "GT-1", "Todo"))
      Noop.Director.set("GT-1", {:succeed_after, 30})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn ->
        Orchestrator.snapshot(pid).counts.running == 0 and
          MapSet.member?(:sys.get_state(pid).completed, "g1")
      end)
    end

    test "runner failure under :graph mode schedules a retry like :default mode" do
      config = build_config(:graph)
      Memory.put_issue(issue("g2", "GT-2", "Todo"))
      Noop.Director.set("GT-2", {:fail_after, 10, :simulated})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(2_000, fn ->
        Orchestrator.snapshot(pid).counts.retrying >= 1
      end)
    end

    test ":default mode still dispatches without invoking the graph runtime" do
      # Sanity: the default path is unaffected. Distinguishing path is
      # implicit (same outcome shape); this just guards the regression.
      config = build_config(:default)
      Memory.put_issue(issue("d1", "DT-1", "Todo"))
      Noop.Director.set("DT-1", {:succeed_after, 30})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn ->
        Orchestrator.snapshot(pid).counts.running == 0 and
          MapSet.member?(:sys.get_state(pid).completed, "d1")
      end)
    end
  end
end
