defmodule Raxol.Symphony.Surfaces.Watch.NotifierTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Surfaces.Watch.Notifier
  alias Raxol.Symphony.Trackers.Memory

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

  defp start_orchestrator(opts \\ []) do
    base = [
      config: config(),
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

  defp start_notifier(orch, capture_pid) do
    push_fn = fn notification ->
      send(capture_pid, {:pushed, notification})
      :ok
    end

    start_supervised!(
      {Notifier,
       orchestrator: orch,
       push_fn: push_fn,
       name: :"watch_notifier_#{System.unique_integer([:positive])}"},
      id: {Notifier, make_ref()}
    )
  end

  defp seed_running_issue(orch, id, identifier) do
    Memory.put_issue(%Issue{id: id, identifier: identifier, title: "T", state: "Todo"})
    Noop.Director.set(identifier, :stall)
    :ok = Orchestrator.tick_now(orch)
  end

  # -- subscription flow -----------------------------------------------------

  describe "event broadcast" do
    test "drops :tick_completed" do
      orch = start_orchestrator()
      _notif = start_notifier(orch, self())

      :ok = Orchestrator.tick_now(orch)
      refute_receive {:pushed, _}, 100
    end

    test "abnormal worker exit produces a normal-priority failure push" do
      orch = start_orchestrator()
      _notif = start_notifier(orch, self())

      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})
      Noop.Director.set("MT-1", {:fail_after, 1, :boom})
      :ok = Orchestrator.tick_now(orch)

      assert_receive {:pushed, n}, 1_000
      assert n.category == "symphony_failure"
      assert n.priority == :normal
    end

    test "manual stop produces a stopped push" do
      orch = start_orchestrator()
      _notif = start_notifier(orch, self())

      seed_running_issue(orch, "a", "MT-1")
      :ok = Orchestrator.stop_run(orch, "a")

      assert_receive {:pushed, n}, 500
      assert n.category == "symphony_stopped"
      assert n.priority == :silent
    end
  end

  # -- push_snapshot/1 -------------------------------------------------------

  describe "push_snapshot/1" do
    test "pushes the current snapshot summary" do
      orch = start_orchestrator()
      notif = start_notifier(orch, self())

      seed_running_issue(orch, "a", "MT-1")
      :ok = Notifier.push_snapshot(notif)

      assert_receive {:pushed, n}, 500
      assert n.category == "symphony_status"
      assert n.body =~ "running 1"
    end
  end

  # -- push_fn errors --------------------------------------------------------

  describe "push_fn errors" do
    test "a raising push_fn does not crash the notifier" do
      orch = start_orchestrator()

      raising_fn = fn _ -> raise "boom" end

      notif =
        start_supervised!(
          {Notifier,
           orchestrator: orch,
           push_fn: raising_fn,
           name: :"watch_notifier_raises_#{System.unique_integer([:positive])}"},
          id: {Notifier, make_ref()}
        )

      seed_running_issue(orch, "a", "MT-1")
      :ok = Orchestrator.stop_run(orch, "a")

      assert Process.alive?(notif)
    end
  end

  # -- handle_action/2 -------------------------------------------------------

  describe "handle_action/2" do
    test "sym:refresh triggers Orchestrator.refresh and reports :refresh" do
      orch = start_orchestrator()
      assert {:ok, :refresh} = Notifier.handle_action("sym:refresh", orchestrator: orch)
    end

    test "sym:stop:<id> stops a running issue" do
      orch = start_orchestrator()
      seed_running_issue(orch, "a", "MT-1")

      assert {:ok, :stopped} =
               Notifier.handle_action("sym:stop:a", orchestrator: orch)

      assert Orchestrator.snapshot(orch).counts.running == 0
    end

    test "sym:stop:<id> on inactive issue surfaces :not_running error" do
      orch = start_orchestrator()

      assert {:error, :not_running} =
               Notifier.handle_action("sym:stop:ghost", orchestrator: orch)
    end

    test "sym:approve:<id> reports :approve_acknowledged" do
      orch = start_orchestrator()

      assert {:ok, :approve_acknowledged} =
               Notifier.handle_action("sym:approve:any_id", orchestrator: orch)
    end

    test "sym:dismiss is a noop" do
      assert :noop = Notifier.handle_action("sym:dismiss", orchestrator: :foo)
    end

    test "unknown ids are noops" do
      assert :noop = Notifier.handle_action("sym:weird", orchestrator: :foo)
      assert :noop = Notifier.handle_action("not-a-symphony-action", orchestrator: :foo)
    end

    test "unreachable orchestrator surfaces :orchestrator_unavailable" do
      assert {:error, :orchestrator_unavailable} =
               Notifier.handle_action("sym:stop:any", orchestrator: :nonexistent)
    end

    test "sym:list maps to refresh (snapshot trigger)" do
      orch = start_orchestrator()
      assert {:ok, :refresh} = Notifier.handle_action("sym:list", orchestrator: orch)
    end

    test "sym:run:<id> is a noop (no detail surface in Watch yet)" do
      assert :noop = Notifier.handle_action("sym:run:iss-1", orchestrator: :foo)
    end

    test "sym:resume:<id>:<decision> calls Orchestrator.resume_run/3" do
      orch = start_orchestrator()

      # Park a paused run via the Noop director so resume_run/3 has
      # something to drive.
      Memory.put_issue(%Issue{id: "a", identifier: "MT-1", title: "T", state: "Todo"})

      Noop.Director.set(
        "MT-1",
        {:pause_then, :awaiting_review, %{seq: 1}, {:succeed_after, 0}}
      )

      :ok = Orchestrator.tick_now(orch)
      wait_paused(orch, "a")

      assert {:ok, {:resumed, "approved"}} =
               Notifier.handle_action("sym:resume:a:approved", orchestrator: orch)

      wait_unparked(orch, "a")
      snap = Orchestrator.snapshot(orch)
      assert snap.counts.paused == 0
    end

    test "sym:resume on an unknown issue surfaces :not_paused" do
      orch = start_orchestrator()

      assert {:error, :not_paused} =
               Notifier.handle_action("sym:resume:ghost:approved", orchestrator: orch)
    end
  end

  defp wait_paused(orch, issue_id, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait(deadline, fn ->
      Map.has_key?(Orchestrator.paused(orch), issue_id)
    end)
  end

  defp wait_unparked(orch, issue_id, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms

    do_wait(deadline, fn ->
      not Map.has_key?(Orchestrator.paused(orch), issue_id)
    end)
  end

  defp do_wait(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait timed out")
      else
        Process.sleep(20)
        do_wait(deadline, fun)
      end
    end
  end
end
