defmodule Raxol.Symphony.OrchestratorParallelTest do
  @moduledoc """
  Behaviour of the orchestrator's `:graph_parallel` workflow mode: eligible
  issues are batched into one fan-out graph run per tick, and each slot's
  outcome fans back to the per-issue retry paths on batch exit.

  Fan-out assertions read the snapshot delivered with the `:batch_exit`
  listener event, which is captured exactly at batch completion -- before the
  continuation-retry timer can fire -- so the tests carry no wall-clock races.
  """
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Orchestrator}
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Task.Supervisor, name: Raxol.Symphony.TaskSupervisor})
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()
    :ok
  end

  defp parallel_config(opts \\ []) do
    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        polling: %{interval_ms: 60_000},
        agent: %{
          max_concurrent_agents: Keyword.get(opts, :max_concurrent_agents, 10),
          max_retry_backoff_ms: 60_000
        },
        codex: %{stall_timeout_ms: 0},
        runner: %{kind: "noop"},
        workflow_mode: :graph_parallel,
        workflow_parallelism: Keyword.get(opts, :workflow_parallelism, 3)
      },
      prompt_template: ""
    })
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{identifier}", state: state}
  end

  defp start_orchestrator(config) do
    {:ok, pid} =
      start_supervised(
        {Orchestrator, config: config, runner_module: Noop, auto_start_tick: false, name: nil},
        id: {Orchestrator, make_ref()}
      )

    pid
  end

  defp put_three_todos do
    Memory.put_issues([
      issue("a", "MP-1", "Todo"),
      issue("b", "MP-2", "Todo"),
      issue("c", "MP-3", "Todo")
    ])
  end

  test "fans a batch of eligible issues into one parallel worker" do
    put_three_todos()
    for id <- ~w(MP-1 MP-2 MP-3), do: Noop.Director.set(id, :stall)

    pid = start_orchestrator(parallel_config())
    :ok = Orchestrator.tick_now(pid)

    snap = Orchestrator.snapshot(pid)
    assert snap.counts.batches == 1
    assert snap.counts.running == 0
    assert [batch] = snap.batches
    assert batch.size == 3
    assert Enum.sort(batch.issue_identifiers) == ~w(MP-1 MP-2 MP-3)
  end

  test "successful slots fan back to continuation retries per issue" do
    put_three_todos()
    for id <- ~w(MP-1 MP-2 MP-3), do: Noop.Director.set(id, {:succeed_after, 10})

    pid = start_orchestrator(parallel_config())
    :ok = Orchestrator.subscribe(pid)
    :ok = Orchestrator.tick_now(pid)

    assert_receive {:symphony_event, :batch_exit, snap}, 2_000
    assert snap.counts.batches == 0
    assert snap.counts.retrying == 3
    assert Enum.all?(snap.retrying, &(&1.error == nil))
  end

  test "a failing slot goes to failure retry while its siblings continue" do
    put_three_todos()
    Noop.Director.set("MP-1", {:succeed_after, 10})
    Noop.Director.set("MP-2", {:fail_after, 10, :boom})
    Noop.Director.set("MP-3", {:succeed_after, 10})

    pid = start_orchestrator(parallel_config())
    :ok = Orchestrator.subscribe(pid)
    :ok = Orchestrator.tick_now(pid)

    assert_receive {:symphony_event, :batch_exit, snap}, 2_000
    assert snap.counts.retrying == 3

    failed = Enum.filter(snap.retrying, &(&1.error != nil))
    assert [only] = failed
    assert only.issue_identifier == "MP-2"
    assert only.error =~ "boom"
  end

  test "a paused slot is parked as resumable while its siblings continue" do
    put_three_todos()
    Noop.Director.set("MP-1", {:succeed_after, 10})
    Noop.Director.set("MP-2", {:pause, :awaiting_review, %{token: 7}})
    Noop.Director.set("MP-3", {:succeed_after, 10})

    pid = start_orchestrator(parallel_config())
    :ok = Orchestrator.subscribe(pid)
    :ok = Orchestrator.tick_now(pid)

    assert_receive {:symphony_event, :batch_exit, snap}, 2_000

    # The paused issue parks (awaiting a resume); the two siblings run to
    # completion and fan back to continuation retries.
    assert snap.counts.paused == 1
    assert snap.counts.retrying == 2

    assert [parked] = snap.paused
    assert parked.issue_identifier == "MP-2"
    assert parked.interrupt_reason == :awaiting_review

    # The parked entry carries the runner's resume token, so the run can be
    # resumed later via `Orchestrator.resume_run/3`.
    assert %{"b" => entry} = Orchestrator.paused(pid)
    assert entry.resume_token == %{token: 7}
    assert entry.interrupt_reason == :awaiting_review
  end

  test "max_concurrent_agents caps the batch size below workflow_parallelism" do
    Memory.put_issues(for n <- 1..5, do: issue("id#{n}", "MP-#{n}", "Todo"))
    for n <- 1..5, do: Noop.Director.set("MP-#{n}", :stall)

    config = parallel_config(max_concurrent_agents: 2, workflow_parallelism: 3)
    pid = start_orchestrator(config)
    :ok = Orchestrator.tick_now(pid)

    snap = Orchestrator.snapshot(pid)
    assert snap.counts.batches == 1
    assert [%{size: 2}] = snap.batches
  end

  test "an eligible issue beyond the cap is picked up on a later tick" do
    put_three_todos()
    for id <- ~w(MP-1 MP-2 MP-3), do: Noop.Director.set(id, :stall)

    config = parallel_config(max_concurrent_agents: 10, workflow_parallelism: 2)
    pid = start_orchestrator(config)

    :ok = Orchestrator.tick_now(pid)
    snap1 = Orchestrator.snapshot(pid)
    assert snap1.counts.batches == 1
    assert [%{size: 2}] = snap1.batches

    :ok = Orchestrator.tick_now(pid)
    snap2 = Orchestrator.snapshot(pid)
    assert snap2.counts.batches == 2

    dispatched =
      snap2.batches |> Enum.flat_map(& &1.issue_identifiers) |> Enum.sort()

    # every issue dispatched exactly once -- no double-dispatch across batches.
    assert dispatched == ~w(MP-1 MP-2 MP-3)
  end
end
