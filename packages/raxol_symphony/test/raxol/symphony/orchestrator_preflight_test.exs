defmodule Raxol.Symphony.OrchestratorPreflightTest do
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

  defp valid_config do
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "memory", active_states: ["Todo"], terminal_states: ["Done"]},
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 1, max_retry_backoff_ms: 60_000},
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  defp invalid_config do
    # Missing tracker.api_key for the linear kind -> Schema.validate rejects.
    Config.from_workflow(%{
      config: %{
        tracker: %{kind: "linear", api_key: nil, project_slug: "demo"},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  defp start_orchestrator(opts) do
    base = [
      runner_module: Noop,
      auto_start_tick: false,
      name: nil
    ]

    {:ok, pid} =
      start_supervised(
        {Orchestrator, Keyword.merge(base, opts)},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  describe "preflight (without WorkflowStore)" do
    test "skips dispatch and emits :preflight_failed when validation fails" do
      pid = start_orchestrator(config: invalid_config())

      :ok = Orchestrator.subscribe(pid)

      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", :succeed)

      :ok = Orchestrator.tick_now(pid)

      assert_receive {:symphony_event, {:preflight_failed, :missing_tracker_api_key}, _snap}, 500
      assert Orchestrator.snapshot(pid).counts.running == 0
    end

    test "passes through to dispatch when validation succeeds" do
      pid = start_orchestrator(config: valid_config())

      :ok = Orchestrator.subscribe(pid)

      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:hold, 200})

      :ok = Orchestrator.tick_now(pid)

      assert_receive {:symphony_event, :tick_completed, snap}, 500
      assert snap.counts.running == 1
    end
  end

  describe "preflight (with WorkflowStore)" do
    setup do
      store_name = :"#{__MODULE__}_#{System.unique_integer([:positive])}"
      pid = start_supervised!({WorkflowStore, config: valid_config(), name: store_name})
      %{store: pid, store_name: store_name}
    end

    test "pulls fresh config from the store on every tick", %{store: store} do
      orch =
        start_orchestrator(workflow_store: store)

      :ok = Orchestrator.subscribe(orch)

      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:hold, 200})

      :ok = Orchestrator.tick_now(orch)
      assert_receive {:symphony_event, :tick_completed, snap}, 500
      assert snap.counts.running == 1

      # No dispatch on second tick because issue is already running -- but
      # the test exercises the path where preflight reads from the store.
      :ok = Orchestrator.tick_now(orch)
      assert_receive {:symphony_event, :tick_completed, _snap}, 500
    end

    test "skips dispatch when store has no config (loaded with bad initial state)" do
      bad_store_name = :"#{__MODULE__}_bad_#{System.unique_integer([:positive])}"

      bad_store =
        start_supervised!(
          {WorkflowStore, name: bad_store_name},
          id: {:bad_store, make_ref()}
        )

      orch = start_orchestrator(config: valid_config(), workflow_store: bad_store)
      :ok = Orchestrator.subscribe(orch)

      :ok = Orchestrator.tick_now(orch)

      assert_receive {:symphony_event, {:preflight_failed, :no_workflow_config}, _snap}, 500
    end
  end

  describe "init wiring" do
    test "init pulls config from the store when :config opt is omitted" do
      store_name = :"#{__MODULE__}_init_#{System.unique_integer([:positive])}"
      store = start_supervised!({WorkflowStore, config: valid_config(), name: store_name})

      orch = start_orchestrator(workflow_store: store)
      snap = Orchestrator.snapshot(orch)

      assert snap.counts.running == 0
    end

    test "init exits with ArgumentError when neither :config nor :workflow_store is given" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{message: msg}, _stacktrace}} =
               Orchestrator.start_link(
                 runner_module: Noop,
                 auto_start_tick: false,
                 name: nil
               )

      assert msg == ":config or :workflow_store is required"
    end
  end
end
