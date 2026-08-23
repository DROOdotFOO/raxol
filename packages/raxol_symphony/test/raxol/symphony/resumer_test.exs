defmodule Raxol.Symphony.ResumerTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator, Resumer}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  @telemetry_event [:raxol, :earn, :job, :transition]

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

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         [
           config: config,
           runner_module: Noop,
           auto_start_tick: false,
           name: nil
         ]},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp start_resumer(orchestrator) do
    {:ok, pid} =
      start_supervised(
        {Resumer,
         [
           orchestrator: orchestrator,
           telemetry_event: @telemetry_event,
           name: nil
         ]},
        id: {Resumer, make_ref()}
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

  describe "telemetry -> resume_run/3 bridge" do
    test "matching event resumes a paused run", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))

      Noop.Director.set(
        "MT-1",
        {:pause_then, :awaiting_buyer_payment,
         %{
           resume_on: %{
             telemetry: @telemetry_event,
             match: %{job_id: "j-1", to: :transaction}
           }
         }, {:succeed_after, 0}}
      )

      orch = start_orchestrator(config)
      _resumer = start_resumer(orch)

      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      # Fire a NON-matching event first; the run must stay paused.
      :telemetry.execute(@telemetry_event, %{}, %{
        job_id: "different-job",
        from: :request,
        to: :transaction
      })

      Process.sleep(60)
      assert Orchestrator.snapshot(orch).counts.paused == 1

      # Now fire the matching event.
      :telemetry.execute(@telemetry_event, %{}, %{
        job_id: "j-1",
        from: :negotiation,
        to: :transaction,
        memo_type: :txhash
      })

      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 0 end)

      # Resumed run completed normally -> continuation retry scheduled.
      wait_until(fn -> Orchestrator.snapshot(orch).counts.running == 0 end)
      snap = Orchestrator.snapshot(orch)
      assert snap.counts.paused == 0
      assert snap.counts.retrying == 1
    end

    test "events with no matching paused run are no-ops", %{config: config} do
      orch = start_orchestrator(config)
      _resumer = start_resumer(orch)

      # No paused runs; firing telemetry should not raise.
      :telemetry.execute(@telemetry_event, %{}, %{
        job_id: "j-99",
        to: :transaction
      })

      Process.sleep(40)
      snap = Orchestrator.snapshot(orch)
      assert snap.counts.paused == 0
      assert snap.counts.running == 0
    end

    test "paused run without :resume_on never auto-resumes", %{config: config} do
      Memory.put_issue(issue("a", "MT-2", "Todo"))
      Noop.Director.set("MT-2", {:pause, :awaiting_delivery, :tok})

      orch = start_orchestrator(config)
      _resumer = start_resumer(orch)

      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      # Any telemetry event; token has no resume_on so no match possible.
      :telemetry.execute(@telemetry_event, %{}, %{job_id: "j-1", to: :transaction})

      Process.sleep(60)
      assert Orchestrator.snapshot(orch).counts.paused == 1
    end

    test "Resumer detaches its telemetry handler on terminate", %{config: config} do
      orch = start_orchestrator(config)

      {:ok, resumer} =
        Resumer.start_link(
          orchestrator: orch,
          telemetry_event: @telemetry_event,
          name: nil
        )

      handlers_before =
        @telemetry_event
        |> :telemetry.list_handlers()
        |> Enum.filter(&String.starts_with?(to_string(&1.id), "raxol-symphony-resumer-"))
        |> length()

      assert handlers_before == 1

      GenServer.stop(resumer, :normal)

      handlers_after =
        @telemetry_event
        |> :telemetry.list_handlers()
        |> Enum.filter(&String.starts_with?(to_string(&1.id), "raxol-symphony-resumer-"))
        |> length()

      assert handlers_after == 0
    end
  end

  describe "Orchestrator.paused/1" do
    test "exposes full paused entries including resume_token", %{config: config} do
      Memory.put_issue(issue("a", "MT-1", "Todo"))

      token = %{resume_on: %{telemetry: @telemetry_event, match: %{job_id: "j-1"}}}
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, token})

      orch = start_orchestrator(config)
      :ok = Orchestrator.tick_now(orch)

      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      paused = Orchestrator.paused(orch)
      assert map_size(paused) == 1
      assert [{"a", entry}] = Map.to_list(paused)
      assert entry.interrupt_reason == :awaiting_buyer_payment
      assert entry.resume_token == token
    end
  end
end
