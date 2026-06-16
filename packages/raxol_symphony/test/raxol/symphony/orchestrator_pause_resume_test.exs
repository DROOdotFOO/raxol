defmodule Raxol.Symphony.OrchestratorPauseResumeTest do
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

  describe "pause" do
    test "runner returning {:pause, reason, token} parks the run in :paused",
         %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, %{seq: 1}})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 1 end)

      snap = Orchestrator.snapshot(pid)
      assert snap.counts.running == 0
      assert snap.counts.paused == 1
      # No failure retry scheduled.
      assert snap.counts.retrying == 0

      [paused] = snap.paused
      assert paused.issue_identifier == "MT-1"
      assert paused.interrupt_reason == :awaiting_buyer_payment
      assert paused.paused_ms_ago >= 0
    end

    test "paused entries do not auto-retry", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_evaluator_approval, :tok})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 1 end)

      # Give any spurious retry time to fire (continuation_delay_ms is ~1s,
      # so a short sleep here proves the pause path skipped retry scheduling).
      Process.sleep(100)
      snap = Orchestrator.snapshot(pid)
      assert snap.counts.retrying == 0
    end
  end

  describe "resume_run/3" do
    test "re-dispatches the runner with :resume_token + :resume_value",
         %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))

      # Pause, then on resume succeed.
      Noop.Director.set(
        "MT-1",
        {:pause_then, :awaiting_buyer_payment, %{checkpoint: "step-2"},
         {:succeed_after, 0}}
      )

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 1 end)

      assert :ok = Orchestrator.resume_run(pid, "a", %{tx_hash: "0xabc"})

      # Resumed run moves back to running, then finishes normal -> retrying.
      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 0 end)
      wait_until(fn -> Orchestrator.snapshot(pid).counts.running == 0 end)

      snap = Orchestrator.snapshot(pid)
      assert snap.counts.paused == 0
      assert snap.counts.running == 0
      # Worker exited normal -> continuation retry queued.
      assert snap.counts.retrying == 1
    end

    test "returns {:error, :not_paused} for an unknown issue id", %{config: config} do
      pid = start_orchestrator(config)
      assert {:error, :not_paused} = Orchestrator.resume_run(pid, "ghost", %{})
    end
  end

  describe "snapshot" do
    test "paused count + entries surface in build_snapshot", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_delivery, :tok})

      pid = start_orchestrator(config)
      :ok = Orchestrator.tick_now(pid)

      wait_until(fn -> Orchestrator.snapshot(pid).counts.paused == 1 end)

      snap = Orchestrator.snapshot(pid)
      assert match?(%{paused: 1}, snap.counts)
      assert [%{issue_identifier: "MT-1", interrupt_reason: :awaiting_delivery}] = snap.paused
    end
  end
end
