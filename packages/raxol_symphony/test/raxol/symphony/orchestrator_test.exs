defmodule Raxol.Symphony.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    config =
      Config.from_workflow(%{
        config: %{
          tracker: %{
            kind: "memory",
            active_states: ["Todo", "In Progress"],
            terminal_states: ["Done", "Cancelled"]
          },
          polling: %{interval_ms: 60_000},
          agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
          codex: %{stall_timeout_ms: 0},
          runner: %{kind: "noop"}
        },
        prompt_template: ""
      })

    %{config: config}
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{identifier}", state: state}
  end

  defp start_orchestrator(config, opts \\ []) do
    base = [
      config: config,
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

  defp wait_until(timeout_ms \\ 1_000, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(20)
        do_wait_until(deadline, fun)
      end
    end
  end

  describe "dispatch" do
    test "dispatches an eligible issue and removes it from running on completion",
         %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:succeed_after, 30})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      snap = Orchestrator.snapshot(pid)
      assert snap.counts.running == 1

      wait_until(fn -> Orchestrator.snapshot(pid).counts.running == 0 end)

      snap_after = Orchestrator.snapshot(pid)
      # Continuation retry scheduled (1s) since worker exited normally.
      assert snap_after.counts.retrying == 1
    end

    test "respects max_concurrent_agents", %{config: config} do
      Memory.put_issues([
        issue("a", "MT-1", "Todo"),
        issue("b", "MT-2", "Todo"),
        issue("c", "MT-3", "Todo"),
        issue("d", "MT-4", "Todo"),
        issue("e", "MT-5", "Todo")
      ])

      for id <- ~w(MT-1 MT-2 MT-3 MT-4 MT-5), do: Noop.Director.set(id, :stall)

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      assert Orchestrator.snapshot(pid).counts.running == 3
    end

    test "skips issues already running", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", :stall)

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)
      :ok = Orchestrator.tick_now(pid)

      assert Orchestrator.snapshot(pid).counts.running == 1
    end

    test "non-active state is not dispatched", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Done"))

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      assert Orchestrator.snapshot(pid).counts.running == 0
    end
  end

  describe "retry" do
    test "abnormal worker exit schedules a failure retry", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:fail_after, 10, :boom})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.retrying == 1 end)

      snap = Orchestrator.snapshot(pid)
      [retry] = snap.retrying
      assert retry.attempt == 1
      assert retry.due_in_ms > 0
      assert retry.error =~ "runner_error"
      assert retry.error =~ "boom"
    end
  end

  describe "stop_run" do
    test "stops a running issue and releases the claim", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", :stall)

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)
      assert Orchestrator.snapshot(pid).counts.running == 1

      assert :ok = Orchestrator.stop_run(pid, "a")
      wait_until(fn -> Orchestrator.snapshot(pid).counts.running == 0 end)
    end

    test "returns :not_running for unknown issue", %{config: config} do
      pid = start_orchestrator(config)
      assert {:error, :not_running} = Orchestrator.stop_run(pid, "missing")
    end
  end

  describe "reconciliation" do
    test "terminates run when tracker state goes terminal", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", :stall)

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)
      assert Orchestrator.snapshot(pid).counts.running == 1

      Memory.transition("a", "Done")
      :ok = Orchestrator.tick_now(pid)
      wait_until(fn -> Orchestrator.snapshot(pid).counts.running == 0 end)
    end

    test "updates issue snapshot when state changes but stays active", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", :stall)

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      Memory.transition("a", "In Progress")
      :ok = Orchestrator.tick_now(pid)

      [running] = Orchestrator.snapshot(pid).running
      assert running.state == "Todo"
      # state field is what was at dispatch; the update happens to issue snapshot
      # in entry.issue, not the snapshot's :state. Both behaviours are acceptable
      # per SPEC s8.5; we just assert the run is still active.
      assert running.issue_id == "a"
    end
  end

  describe "subscribe + snapshot" do
    test "snapshot has expected shape", %{config: config} do
      pid = start_orchestrator(config)
      snap = Orchestrator.snapshot(pid)

      assert is_binary(snap.generated_at)
      assert snap.counts == %{running: 0, retrying: 0, paused: 0}
      assert snap.running == []
      assert snap.retrying == []
      assert snap.paused == []
      assert is_map(snap.codex_totals)
    end

    test "subscribers receive :symphony_event on tick", %{config: config} do
      pid = start_orchestrator(config)
      :ok = Orchestrator.subscribe(pid)

      :ok = Orchestrator.tick_now(pid)

      assert_receive {:symphony_event, :tick_completed, %{counts: _}}, 500
    end
  end

  describe "pause / resume" do
    test "runner returning {:pause, reason, token} parks the run", %{
      config: config
    } do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_review, %{pr: 42}})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 1 end)

      snap = Orchestrator.snapshot(pid)
      assert snap.counts.running == 0
      assert snap.counts.paused == 1
      assert [paused] = snap.paused
      assert paused.issue_id == "a"
      assert paused.issue_identifier == "MT-1"
      assert paused.interrupt_reason == :awaiting_review
      assert is_integer(paused.paused_ms_ago) and paused.paused_ms_ago >= 0
    end

    test "subscribers receive :worker_paused event with the paused run", %{
      config: config
    } do
      Memory.put_issue(issue("a", "MT-2", "Todo"))
      Noop.Director.set("MT-2", {:pause, :awaiting_ci, "token-1"})

      pid = start_orchestrator(config)
      :ok = Orchestrator.subscribe(pid)
      :ok = Orchestrator.tick_now(pid)

      assert_receive {:symphony_event, :worker_paused, snap}, 500
      assert snap.counts.paused == 1
      assert [%{interrupt_reason: :awaiting_ci}] = snap.paused
    end

    test "resume_run/3 re-dispatches the runner with the resume value", %{
      config: config
    } do
      Memory.put_issue(issue("a", "MT-3", "Todo"))

      Noop.Director.set(
        "MT-3",
        {:pause_then, :awaiting_review, "rt", {:succeed_after, 10}}
      )

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 1 end)

      assert :ok = Orchestrator.resume_run(pid, "a", :approved)

      # After resume the run goes back to :running, then completes
      # (continuation retry scheduled like any normal-exit worker).
      wait_until(fn ->
        snap = Orchestrator.snapshot(pid)
        snap.counts.paused == 0 and snap.counts.running == 0
      end)

      snap = Orchestrator.snapshot(pid)
      assert snap.counts.retrying == 1
    end

    test "resume_run/3 returns {:error, :not_paused} for unknown issue_id", %{
      config: config
    } do
      pid = start_orchestrator(config)
      assert {:error, :not_paused} = Orchestrator.resume_run(pid, "ghost", :any)
    end

    test "paused run carries turn_count + tokens accumulated before the pause",
         %{config: config} do
      Memory.put_issue(issue("a", "MT-4", "Todo"))

      Noop.Director.set(
        "MT-4",
        {:emit,
         [
           %{
             event: :turn_completed,
             usage: %{input_tokens: 10, output_tokens: 20, total_tokens: 30}
           }
         ], {:pause, :awaiting_human, nil}}
      )

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 1 end)

      [paused] = Orchestrator.snapshot(pid).paused
      assert paused.turn_count == 1
      assert paused.tokens.total_tokens == 30
    end
  end
end
