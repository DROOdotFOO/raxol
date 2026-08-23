defmodule Raxol.Symphony.OrchestratorPausedGcTest.RaisingSaver do
  @moduledoc false
  # put/3 raises MatchError, mimicking `:ok = :dets.insert(...)` failing on a
  # full/read-only disk.
  @behaviour Raxol.Symphony.Orchestrator.PausedSaver

  @impl true
  def put(_config, _issue_id, _entry), do: :ok = :not_ok

  @impl true
  def delete(_config, _issue_id), do: :ok

  @impl true
  def load_all(_config), do: {:ok, %{}}
end

defmodule Raxol.Symphony.OrchestratorPausedGcTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.OrchestratorPausedGcTest.RaisingSaver

  alias Raxol.Symphony.{Config, Issue, Orchestrator, Workspace}
  alias Raxol.Symphony.Orchestrator.PausedSaver.Memory, as: MemorySaver
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory, as: MemoryTracker

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({MemoryTracker, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    workspace_root =
      Path.join(System.tmp_dir!(), "symphony_gc_#{:erlang.unique_integer([:positive])}")

    File.mkdir_p!(workspace_root)
    on_exit(fn -> File.rm_rf(workspace_root) end)

    config =
      Config.from_workflow(%{
        config: %{
          tracker: %{
            kind: "memory",
            active_states: ["Todo", "In Progress"],
            terminal_states: ["Done", "Cancelled"]
          },
          workspace: %{root: workspace_root},
          polling: %{interval_ms: 60_000},
          agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
          codex: %{stall_timeout_ms: 0},
          runner: %{kind: "noop"}
        },
        prompt_template: ""
      })

    table = :"symphony_gc_paused_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)

    %{config: config, saver: {MemorySaver, %{table: table}}, workspace_root: workspace_root}
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{identifier}", state: state}
  end

  defp start_orchestrator(config, saver, opts) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         [
           config: config,
           runner_module: Noop,
           auto_start_tick: false,
           name: nil,
           paused_saver: saver
         ] ++ opts},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp wait_until(fun, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(deadline, fun)
  end

  defp do_wait_until(deadline, fun) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("wait_until timed out")
      true -> Process.sleep(10) && do_wait_until(deadline, fun)
    end
  end

  describe "abandoned paused runs are garbage-collected past the TTL" do
    test "expires a stale hydrated entry, removing workspace and saver row", %{
      config: config,
      saver: {MemorySaver, cfg} = saver
    } do
      MemorySaver.ensure_table(cfg)

      # Real workspace dir under the config root, so removal is observable.
      {:ok, %{path: workspace_path}} = Workspace.ensure(config, "MT-1")
      assert File.dir?(workspace_path)

      stale =
        System.system_time(:millisecond) - :timer.hours(24 * 8)

      entry = %{
        issue: issue("a", "MT-1", "Todo"),
        attempt: 1,
        workspace_path: workspace_path,
        interrupt_reason: :awaiting_buyer_payment,
        resume_token: :tok,
        paused_at: System.monotonic_time(:millisecond),
        paused_at_system: stale,
        last_event: nil,
        last_message: nil,
        turn_count: 2,
        tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      }

      :ok = MemorySaver.put(cfg, "a", entry)

      # Issue is NOT registered with the tracker, so a tick will not re-dispatch it.
      orch = start_orchestrator(config, saver, [])
      assert Orchestrator.snapshot(orch).counts.paused == 1

      :ok = Orchestrator.tick_now(orch)

      assert Orchestrator.snapshot(orch).counts.paused == 0
      assert {:ok, persisted} = MemorySaver.load_all(cfg)
      assert map_size(persisted) == 0
      refute File.dir?(workspace_path)
    end

    test "flushes the abandoned run's prompt-cache row, so it does not leak", %{
      saver: {MemorySaver, cfg} = saver,
      workspace_root: workspace_root
    } do
      MemorySaver.ensure_table(cfg)

      # Opt-in prompt cache wired under runner.agent, as a live run would have.
      cache_table = :"symphony_gc_prompt_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        if :ets.whereis(cache_table) != :undefined, do: :ets.delete(cache_table)
      end)

      cache = {Raxol.Agent.Cache.Ets, %{table: cache_table}}

      cached_config =
        Config.from_workflow(%{
          config: %{
            tracker: %{
              kind: "memory",
              active_states: ["Todo", "In Progress"],
              terminal_states: ["Done", "Cancelled"]
            },
            workspace: %{root: workspace_root},
            polling: %{interval_ms: 60_000},
            agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
            codex: %{stall_timeout_ms: 0},
            runner: %{kind: "noop", agent: %{prompt_cache: cache}}
          },
          prompt_template: ""
        })

      # Seed the row a live dispatch of this issue would have written, keyed on
      # the stable issue id ({:prompt, "a"}).
      :ok = Raxol.Agent.Cache.put(cache, {:prompt, "a"}, {"fp", "MT-1"}, 60_000)
      assert :ets.info(cache_table, :size) == 1

      {:ok, %{path: workspace_path}} = Workspace.ensure(cached_config, "MT-1")

      stale = System.system_time(:millisecond) - :timer.hours(24 * 8)

      entry = %{
        issue: issue("a", "MT-1", "Todo"),
        attempt: 1,
        workspace_path: workspace_path,
        interrupt_reason: :awaiting_buyer_payment,
        resume_token: :tok,
        paused_at: System.monotonic_time(:millisecond),
        paused_at_system: stale,
        last_event: nil,
        last_message: nil,
        turn_count: 2,
        tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      }

      :ok = MemorySaver.put(cfg, "a", entry)

      orch = start_orchestrator(cached_config, saver, [])
      assert Orchestrator.snapshot(orch).counts.paused == 1

      :ok = Orchestrator.tick_now(orch)

      # The abandoned paused run was GC'd past its TTL...
      assert Orchestrator.snapshot(orch).counts.paused == 0
      # ...and the paused-GC path flushed its prompt-cache row, so the terminal
      # claim-drop leaves no orphaned entry (O(in-flight) bound holds here too).
      assert :ets.info(cache_table, :size) == 0
    end

    test "keeps a recently paused entry", %{config: config, saver: {MemorySaver, cfg} = saver} do
      MemorySaver.ensure_table(cfg)

      entry = %{
        issue: issue("a", "MT-1", "Todo"),
        attempt: 1,
        workspace_path: Path.join(config.workspace.root, "recent"),
        interrupt_reason: :awaiting_delivery,
        resume_token: :tok,
        paused_at: System.monotonic_time(:millisecond),
        paused_at_system: System.system_time(:millisecond),
        last_event: nil,
        last_message: nil,
        turn_count: 0,
        tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      }

      :ok = MemorySaver.put(cfg, "a", entry)

      orch = start_orchestrator(config, saver, [])
      :ok = Orchestrator.tick_now(orch)

      assert Orchestrator.snapshot(orch).counts.paused == 1
    end

    test "releases the claim so the issue becomes dispatchable again", %{
      config: config,
      saver: saver
    } do
      MemoryTracker.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, :tok})

      # Tiny TTL so the live-parked run expires on the next tick.
      orch = start_orchestrator(config, saver, paused_max_age_ms: 1)
      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      # Re-dispatch would otherwise re-pause; make it stall so a freed claim
      # is observable as a fresh running entry.
      Noop.Director.set("MT-1", :stall)
      Process.sleep(5)
      :ok = Orchestrator.tick_now(orch)

      # If the claim were NOT released, the GC'd issue could not be re-dispatched.
      wait_until(fn ->
        snap = Orchestrator.snapshot(orch)
        snap.counts.paused == 0 and snap.counts.running == 1
      end)
    end
  end

  describe "durability flag" do
    test "a persisted pause is marked durable? true", %{config: config, saver: saver} do
      MemoryTracker.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, :tok})

      orch = start_orchestrator(config, saver, [])
      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      [paused] = Orchestrator.snapshot(orch).paused
      assert paused.durable? == true
    end

    test "a raising saver degrades instead of crashing and marks durable? false", %{
      config: config
    } do
      MemoryTracker.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:pause, :awaiting_buyer_payment, :tok})

      # RaisingSaver.put raises MatchError, mimicking `:ok = :dets.insert(...)`
      # failing on a full/read-only disk.
      orch = start_orchestrator(config, {RaisingSaver, %{}}, [])
      :ok = Orchestrator.tick_now(orch)
      wait_until(fn -> Orchestrator.snapshot(orch).counts.paused == 1 end)

      # GenServer survived the raise.
      assert Process.alive?(orch)

      [paused] = Orchestrator.snapshot(orch).paused
      assert paused.durable? == false
    end
  end
end
