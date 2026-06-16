defmodule Raxol.Symphony.OrchestratorPausedSaverIntegrationTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Orchestrator.PausedSaver.Memory, as: MemorySaver
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory, as: MemoryTracker

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({MemoryTracker, []})
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

    table = :"symphony_test_paused_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)

    %{config: config, saver: {MemorySaver, %{table: table}}}
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{identifier}", state: state}
  end

  defp start_orchestrator(config, saver) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         [
           config: config,
           runner_module: Noop,
           auto_start_tick: false,
           name: nil,
           paused_saver: saver
         ]},
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

  describe "park persists to saver" do
    test "saver is written when a runner pauses", %{config: config, saver: saver} do
      MemoryTracker.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, %{seq: 1}})

      orch = start_orchestrator(config, saver)
      :ok = Orchestrator.tick_now(orch)

      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      {MemorySaver, cfg} = saver
      assert {:ok, persisted} = MemorySaver.load_all(cfg)
      assert map_size(persisted) == 1
      assert %{"a" => entry} = persisted
      assert entry.interrupt_reason == :awaiting_buyer_payment
      assert entry.resume_token == %{seq: 1}
    end
  end

  describe "resume removes from saver" do
    test "calling resume_run/3 deletes the persisted entry", %{config: config, saver: saver} do
      MemoryTracker.put_issue(issue("a", "MT-1", "Todo"))

      Noop.Director.set(
        "MT-1",
        {:pause_then, :awaiting_buyer_payment, :tok, {:succeed_after, 0}}
      )

      orch = start_orchestrator(config, saver)
      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      assert :ok = Orchestrator.resume_run(orch, "a", :event)

      {MemorySaver, cfg} = saver

      wait_until(fn ->
        {:ok, persisted} = MemorySaver.load_all(cfg)
        map_size(persisted) == 0
      end)
    end
  end

  describe "stop_run on a paused entry" do
    test "drops it from both memory and saver", %{config: config, saver: saver} do
      MemoryTracker.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_delivery, :tok})

      orch = start_orchestrator(config, saver)
      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      assert :ok = Orchestrator.stop_run(orch, "a")

      assert Orchestrator.snapshot(orch).counts.paused == 0

      {MemorySaver, cfg} = saver
      assert {:ok, %{}} = MemorySaver.load_all(cfg)
    end
  end

  describe "init hydrates from saver" do
    test "a fresh orchestrator restores paused entries from the saver", %{
      config: config,
      saver: {MemorySaver, cfg} = saver
    } do
      # Pre-seed the saver with a paused entry, no orchestrator running yet.
      MemorySaver.ensure_table(cfg)

      entry = %{
        issue: issue("a", "MT-1", "Todo"),
        attempt: 1,
        workspace_path: "/tmp/ws-a",
        interrupt_reason: :awaiting_evaluator_approval,
        resume_token: %{step: "final"},
        paused_at: System.monotonic_time(:millisecond),
        last_event: nil,
        last_message: nil,
        turn_count: 4,
        tokens: %{input_tokens: 200, output_tokens: 100, total_tokens: 300}
      }

      :ok = MemorySaver.put(cfg, "a", entry)

      # Start a fresh orchestrator with the same saver.
      orch = start_orchestrator(config, saver)

      paused_map = Orchestrator.paused(orch)
      assert map_size(paused_map) == 1
      assert %{"a" => hydrated} = paused_map
      assert hydrated.interrupt_reason == :awaiting_evaluator_approval
      assert hydrated.resume_token == %{step: "final"}
      assert hydrated.turn_count == 4

      # Snapshot must surface the hydrated count.
      assert Orchestrator.snapshot(orch).counts.paused == 1
    end
  end
end
