defmodule Raxol.Symphony.OrchestratorPausedReleaseTest do
  @moduledoc """
  Discarding a parked run must release what its runner kept alive for the
  resume -- for `Raxol.Symphony.Runners.RaxolAgentSession`, the agent session
  subtree under `Raxol.Agent.DynSup`. Both discard paths, `stop_run/2` on a
  parked run and the paused-run TTL GC, hand the entry's resume token to the
  runner's optional `release/1`.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Orchestrator.PausedSaver.Memory, as: MemorySaver
  alias Raxol.Symphony.Test.EtsTables
  alias Raxol.Symphony.Trackers.Memory, as: MemoryTracker

  defmodule ReleasingRunner do
    @moduledoc false
    @behaviour Raxol.Symphony.Runner

    @impl true
    def run(_issue, _config, _opts), do: :ok

    @impl true
    def release(token) do
      send(:persistent_term.get({__MODULE__, :test_pid}), {:released, token})
      :ok
    end
  end

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({MemoryTracker, []})

    :persistent_term.put({ReleasingRunner, :test_pid}, self())
    on_exit(fn -> :persistent_term.erase({ReleasingRunner, :test_pid}) end)

    root = Path.join(System.tmp_dir!(), "sym_release_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    table = :"sym_release_paused_#{:erlang.unique_integer([:positive])}"
    MemorySaver.ensure_table(%{table: table})
    on_exit(fn -> EtsTables.drop(table) end)

    %{root: root, saver_cfg: %{table: table}}
  end

  defp config(root) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo"],
          terminal_states: ["Done"]
        },
        workspace: %{root: root},
        polling: %{interval_ms: 60_000},
        agent: %{max_concurrent_agents: 10, max_retry_backoff_ms: 60_000},
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"}
      },
      prompt_template: ""
    })
  end

  defp parked(id, overrides) do
    Map.merge(
      %{
        issue: %Issue{id: id, identifier: "PR-#{id}", title: "T", state: "Todo"},
        attempt: 0,
        workspace_path: "/tmp/PR-#{id}",
        host: nil,
        interrupt_reason: :awaiting_review,
        resume_token: %{session_id: "session-#{id}"},
        paused_at: System.monotonic_time(:millisecond),
        paused_at_system: System.system_time(:millisecond),
        last_event: nil,
        last_message: nil,
        turn_count: 0,
        tokens: %{input_tokens: 0, output_tokens: 0, total_tokens: 0}
      },
      overrides
    )
  end

  defp start_orchestrator(root, saver_cfg, opts) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator,
         [
           config: config(root),
           runner_module: ReleasingRunner,
           auto_start_tick: false,
           name: nil,
           paused_saver: {MemorySaver, saver_cfg}
         ] ++ opts},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  test "stopping a parked run releases its runner resources", %{root: root, saver_cfg: cfg} do
    MemorySaver.put(cfg, "a", parked("a", %{}))
    pid = start_orchestrator(root, cfg, [])
    assert Orchestrator.snapshot(pid).counts.paused == 1

    assert :ok = Orchestrator.stop_run(pid, "a")

    assert_received {:released, %{session_id: "session-a"}}
    assert Orchestrator.snapshot(pid).counts.paused == 0
  end

  test "a parked run expired by the TTL GC releases its runner resources", %{
    root: root,
    saver_cfg: cfg
  } do
    MemorySaver.put(cfg, "b", parked("b", %{paused_at_system: 0}))
    pid = start_orchestrator(root, cfg, paused_max_age_ms: 1)
    :ok = Orchestrator.subscribe(pid)

    :ok = Orchestrator.tick_now(pid)

    assert_receive {:symphony_event, :paused_gc, snap}, 2_000
    assert snap.counts.paused == 0
    assert_received {:released, %{session_id: "session-b"}}
  end
end
