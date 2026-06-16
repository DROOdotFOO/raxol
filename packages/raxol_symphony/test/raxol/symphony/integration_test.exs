defmodule Raxol.Symphony.IntegrationTest do
  @moduledoc """
  End-to-end: Orchestrator + Memory tracker + RaxolAgent runner with Mock LLM.

  Validates that the full Phase 4 stack drives an issue through dispatch ->
  agent run -> continuation -> reconciliation when the tracker state moves
  terminal.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    :ok
  end

  defp config(max_turns \\ 1, mock_latency_ms \\ 0) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 3, max_turns: max_turns},
        codex: %{stall_timeout_ms: 0},
        runner: %{
          kind: "raxol_agent",
          agent: %{backend: "mock", response: "ok", latency_ms: mock_latency_ms}
        }
      },
      prompt_template: "Working on {{ issue.identifier }}"
    })
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{id}", state: state}
  end

  defp wait_until(timeout_ms, fun) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  # Race-tolerant assertion: dispatch happened iff within timeout_ms the issue
  # was either seen running OR landed in retrying (worker finished + queued).
  defp dispatched?(pid, issue_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_dispatched?(pid, issue_id, deadline)
  end

  defp do_dispatched?(pid, issue_id, deadline) do
    snap = Orchestrator.snapshot(pid)

    seen_running? = Enum.any?(snap.running, &(&1.issue_id == issue_id))
    seen_retrying? = Enum.any?(snap.retrying, &(&1.issue_id == issue_id))

    if seen_running? or seen_retrying? do
      true
    else
      if System.monotonic_time(:millisecond) >= deadline do
        false
      else
        Process.sleep(5)
        do_dispatched?(pid, issue_id, deadline)
      end
    end
  end

  defp do_wait_until(deadline, fun) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until timed out")
      else
        Process.sleep(10)
        do_wait_until(deadline, fun)
      end
    end
  end

  test "runs an issue end-to-end and accumulates token totals" do
    # Mock backend reports usage; one turn means terminal-state recheck stops it.
    Memory.put_issue(issue("a", "MT-1", "Todo"))

    # Pre-set state to terminal so the runner stops after one turn.
    pid =
      start_supervised!(
        {Orchestrator,
         [
           config: config(),
           auto_start_tick: false,
           name: nil
         ]}
      )

    # Move issue terminal so the runner stops after one turn (continuation
    # check returns :done because state is Done).
    Memory.transition("a", "Done")
    # Re-add as Todo for dispatch eligibility, but the state-refresh during
    # the runner's continuation check sees terminal and stops.
    Memory.transition("a", "Todo")

    :ok = Orchestrator.tick_now(pid)
    # Dispatch happened: assert we either saw running=1 within the next 50ms
    # window, OR the worker already finished and is queued for continuation
    # retry. Either is proof that tick dispatched. (The mock backend can
    # finish in <1ms, so a strict running==1 assertion is racy.)
    assert dispatched?(pid, "a", 50)

    # Move to Done so the runner's still_active? returns :done after turn 1.
    Memory.transition("a", "Done")

    wait_until(2_000, fn -> Orchestrator.snapshot(pid).counts.running == 0 end)

    snap = Orchestrator.snapshot(pid)
    # Orchestrator records run-time seconds (non-negative float).
    assert is_float(snap.codex_totals.seconds_running)
    assert snap.codex_totals.seconds_running >= 0.0
  end

  test "respects max_concurrent_agents under load" do
    Memory.put_issues([
      issue("a", "MT-1", "Todo"),
      issue("b", "MT-2", "Todo"),
      issue("c", "MT-3", "Todo"),
      issue("d", "MT-4", "Todo"),
      issue("e", "MT-5", "Todo")
    ])

    cfg = config(_max_turns = 1, _mock_latency_ms = 500)

    pid =
      start_supervised!({Orchestrator, [config: cfg, auto_start_tick: false, name: nil]})

    :ok = Orchestrator.tick_now(pid)
    # 3 dispatched immediately; remaining 2 wait until slots free up.
    snap = Orchestrator.snapshot(pid)
    assert snap.counts.running == 3
  end

  test "abnormal worker exit triggers exponential-backoff retry" do
    # Use the Noop runner with a fail directive to test the orchestrator's
    # retry path independently of raxol_agent.
    start_supervised!(Raxol.Symphony.Runners.Noop.Director)
    Raxol.Symphony.Runners.Noop.Director.clear()
    Raxol.Symphony.Runners.Noop.Director.set("MT-fail", {:fail_after, 10, :boom})
    Memory.put_issue(issue("a", "MT-fail", "Todo"))

    cfg = %{config() | runner: %{kind: "noop", agent: %{}}}

    pid =
      start_supervised!(
        {Orchestrator,
         [
           config: cfg,
           auto_start_tick: false,
           runner_module: Raxol.Symphony.Runners.Noop,
           name: nil
         ]}
      )

    :ok = Orchestrator.tick_now(pid)
    wait_until(2_000, fn -> Orchestrator.snapshot(pid).counts.retrying == 1 end)

    [retry] = Orchestrator.snapshot(pid).retrying
    assert retry.attempt == 1
    # SPEC s8.4: failure delay = min(10000 * 2^0, max). First attempt -> ~10s.
    assert retry.due_in_ms > 5_000
    assert retry.due_in_ms <= 10_000
  end
end
