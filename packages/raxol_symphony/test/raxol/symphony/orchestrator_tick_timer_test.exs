defmodule Raxol.Symphony.OrchestratorTickTimerTest do
  @moduledoc """
  One poll timer chain, always.

  `Process.cancel_timer/1` does not unsend a message that has already been
  delivered, so a `run_tick` that outlives the poll interval leaves a tick
  queued behind the reschedule that follows it. Treating that stale tick as
  the live one arms a second timer and orphans the first, and every recurrence
  adds another chain -- permanently multiplying tracker polling with no way
  back short of restarting the orchestrator.

  The ordering is produced deterministically with `:sys.suspend/1`: the refresh
  cast is queued first, the poll timer expires behind it, and both are handled
  on resume.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    :ok
  end

  @interval_ms 200

  defp config do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        polling: %{interval_ms: @interval_ms},
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
        {Orchestrator, config: config(), runner_module: Noop, auto_start_tick: false, name: nil},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp queue_len(pid) do
    {:message_queue_len, len} = Process.info(pid, :message_queue_len)
    len
  end

  defp wait_until(fun, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("wait_until timed out")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end

  test "a tick delivered before its own reschedule does not start a second timer chain" do
    pid = start_orchestrator()
    :ok = Orchestrator.subscribe(pid)

    # Arm the poll timer and consume the event the arming tick emitted.
    Orchestrator.refresh(pid)
    assert_receive {:symphony_event, :tick_completed, _}, 1_000
    timer_ref = :sys.get_state(pid).tick_timer_ref
    assert is_reference(timer_ref)

    :sys.suspend(pid)
    Orchestrator.refresh(pid)
    wait_until(fn -> Process.read_timer(timer_ref) == false end)
    wait_until(fn -> queue_len(pid) >= 2 end)
    :sys.resume(pid)

    # The refresh runs its own poll cycle and reschedules.
    assert_receive {:symphony_event, :tick_completed, _}, 1_000

    # The superseded tick must be dropped. Running it would poll the tracker a
    # second time and leave two live timers behind. The window is half the poll
    # interval, so the legitimate next tick cannot account for the event.
    refute_receive {:symphony_event, :tick_completed, _}, div(@interval_ms, 2)
  end
end
