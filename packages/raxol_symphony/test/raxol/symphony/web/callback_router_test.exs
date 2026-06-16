defmodule Raxol.Symphony.Web.CallbackRouterTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory
  alias Raxol.Symphony.Web.CallbackRouter

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    :ok
  end

  defp config do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory", active_states: ["Todo"], terminal_states: ["Done"]},
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  defp start_orchestrator do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         [config: config(), runner_module: Noop, auto_start_tick: false, name: nil]},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp seed_running(orch, id, identifier) do
    Memory.put_issue(%Issue{id: id, identifier: identifier, title: "T", state: "Todo"})
    Noop.Director.set(identifier, :stall)
    :ok = Orchestrator.tick_now(orch)
  end

  defp wait_paused(orch, id, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(deadline, fn -> Map.has_key?(Orchestrator.paused(orch), id) end)
  end

  defp do_wait(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: flunk("wait timed out"),
        else: (Process.sleep(20); do_wait(deadline, fun))
    end
  end

  describe "nullary actions" do
    test "sym:refresh -> {:ok, :refresh}" do
      orch = start_orchestrator()

      assert {:ok, :refresh} =
               CallbackRouter.handle_callback("sym:refresh", orchestrator: orch)
    end

    test "sym:list -> {:ok, :listed}" do
      orch = start_orchestrator()

      assert {:ok, :listed} =
               CallbackRouter.handle_callback("sym:list", orchestrator: orch)
    end

    test "sym:dismiss -> :noop" do
      assert :noop = CallbackRouter.handle_callback("sym:dismiss")
    end
  end

  describe "actions on an issue_id" do
    test "sym:stop:<id> stops a running issue" do
      orch = start_orchestrator()
      seed_running(orch, "a", "MT-1")

      assert {:ok, :stopped} =
               CallbackRouter.handle_callback("sym:stop:a", orchestrator: orch)
    end

    test "sym:stop:<id> on unknown issue returns :not_running" do
      orch = start_orchestrator()

      assert {:error, :not_running} =
               CallbackRouter.handle_callback("sym:stop:ghost", orchestrator: orch)
    end

    test "sym:run:<id> returns {:ok, {:run_detail, id}} for the LV to consume" do
      assert {:ok, {:run_detail, "a"}} =
               CallbackRouter.handle_callback("sym:run:a")
    end

    test "sym:approve:<id> is a :noop (legacy)" do
      assert :noop = CallbackRouter.handle_callback("sym:approve:any")
    end
  end

  describe "resume" do
    test "sym:resume:<id>:<decision> calls Orchestrator.resume_run/3" do
      orch = start_orchestrator()

      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})

      Noop.Director.set(
        "MT-1",
        {:pause_then, :awaiting_review, %{seq: 1}, {:succeed_after, 0}}
      )

      :ok = Orchestrator.tick_now(orch)
      wait_paused(orch, "a")

      assert {:ok, {:resumed, "approved"}} =
               CallbackRouter.handle_callback("sym:resume:a:approved", orchestrator: orch)
    end

    test "sym:resume on an unknown issue returns :not_paused" do
      orch = start_orchestrator()

      assert {:error, :not_paused} =
               CallbackRouter.handle_callback("sym:resume:ghost:approved",
                 orchestrator: orch
               )
    end
  end

  describe "unknown shapes" do
    test "non-sym prefix is :noop" do
      assert :noop = CallbackRouter.handle_callback("not-a-sym")
    end

    test "malformed sym action is :noop" do
      assert :noop = CallbackRouter.handle_callback("sym:weird")
    end
  end

  describe "unreachable orchestrator" do
    test "surfaces :orchestrator_unavailable" do
      assert {:error, :orchestrator_unavailable} =
               CallbackRouter.handle_callback("sym:stop:any", orchestrator: :nonexistent)
    end
  end
end
