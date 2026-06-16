defmodule Raxol.Symphony.Runners.RaxolAgentThreadLogTest do
  @moduledoc """
  Phase 11: verifies the `agent.thread_log` opt-in records a per-run
  audit trail at turn boundaries.

  Append points covered:

    * `:state_snapshot` per completed turn -- `__workflow_collect_turn__`
      writes one with `%{turn, event_count, last_event, paused}`.
    * `:message` with `%{event: :resumed}` -- `AgentWorkflow.after_turn`
      writes one each time `Workflow.interrupt/1` returns a value
      (operator resume path).

  Pauses themselves are NOT logged here -- they are covered by
  `[:raxol, :workflow, :run, :paused]` telemetry, and the after-node
  body re-runs on resume so double-writing would duplicate them.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp ets_thread_log do
    table = :"sym_runner_thread_log_test_#{:erlang.unique_integer([:positive])}"
    on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
    {Raxol.Agent.ThreadLog.Ets, %{table: table}}
  end

  defp config(agent_overrides, max_turns \\ 1)

  defp config(agent_overrides, max_turns) do
    base = %{backend: "mock", response: "ok", workflow_mode: true}

    Config.from_workflow(%{
      config: %{
        tracker: %{
          kind: "memory",
          active_states: ["Todo", "In Progress"],
          terminal_states: ["Done", "Cancelled"]
        },
        agent: %{max_turns: max_turns},
        runner: %{
          kind: "raxol_agent",
          agent: Map.merge(base, agent_overrides)
        }
      },
      prompt_template: "{{ issue.identifier }}"
    })
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "T", state: "Todo"}
  end

  describe "thread_log: nil (default)" do
    test "no-ops: runner completes normally without an adapter" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)
    end
  end

  describe "thread_log: {Ets, ...}" do
    test "appends :state_snapshot per completed turn" do
      adapter = ets_thread_log()

      Memory.put_issue(%{issue() | state: "In Progress"})

      cfg = config(%{thread_log: adapter}, 3)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: 1)

      thread_id = "symphony-agent-issue-1-1"

      {:ok, events} = Raxol.Agent.ThreadLog.list(adapter, thread_id)

      snapshots = Enum.filter(events, &(&1.kind == :state_snapshot))
      # Three full turns -> three snapshots.
      assert length(snapshots) == 3

      # Snapshot payload shape.
      [first | _] = snapshots
      assert is_integer(first.payload.turn)
      assert first.payload.event_count >= 1
      assert first.payload.paused == false
    end

    test "appends :message with :resumed when pause/resume cycle completes" do
      adapter = ets_thread_log()

      Memory.put_issue(%{issue() | state: "Done"})

      # Stateful detector: pauses on first event, then continues.
      {:ok, ref} = Agent.start_link(fn -> :first end)

      detector = fn _event ->
        case Agent.get_and_update(ref, fn s -> {s, :later} end) do
          :first -> {:pause, :awaiting_review, %{ref: ref}}
          _ -> :continue
        end
      end

      cfg = config(%{thread_log: adapter, pause_detector: detector})

      # Pause.
      assert {:pause, :awaiting_review, pause_token} =
               RaxolAgent.run(issue(), cfg, parent: self(), attempt: 2)

      thread_id = "symphony-agent-issue-1-2"

      # Resume.
      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 attempt: 2,
                 resume_token: pause_token,
                 resume_value: :approved
               )

      {:ok, events} = Raxol.Agent.ThreadLog.list(adapter, thread_id)

      resume_events =
        Enum.filter(events, fn e ->
          e.kind == :message and is_map(e.payload) and
            Map.get(e.payload, :event) == :resumed
        end)

      # Exactly one resume entry per pause/resume cycle.
      assert length(resume_events) == 1
      [resume | _] = resume_events
      assert resume.payload.interrupt_reason == :awaiting_review
      assert resume.payload.resume_value == :approved
    end

    test "thread_id encodes issue.id and attempt" do
      adapter = ets_thread_log()
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{thread_log: adapter})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: 7)

      # No collision with the default "0" attempt -- write happens at
      # symphony-agent-issue-1-7.
      thread_id_7 = "symphony-agent-issue-1-7"
      {:ok, events} = Raxol.Agent.ThreadLog.list(adapter, thread_id_7)
      assert events != []

      {:ok, default_events} =
        Raxol.Agent.ThreadLog.list(adapter, "symphony-agent-issue-1-0")

      assert default_events == []
    end

    test "events have strictly monotonic sequence" do
      adapter = ets_thread_log()
      Memory.put_issue(%{issue() | state: "In Progress"})

      cfg = config(%{thread_log: adapter}, 3)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: 3)

      thread_id = "symphony-agent-issue-1-3"

      {:ok, events} = Raxol.Agent.ThreadLog.list(adapter, thread_id)

      sequences = Enum.map(events, & &1.sequence)
      assert sequences == Enum.sort(sequences)
      assert sequences == Enum.uniq(sequences)
    end

    test "bare-module form is normalized" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{thread_log: Raxol.Agent.ThreadLog.Ets})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: 4)

      # Default Ets table is used.
      {:ok, events} =
        Raxol.Agent.ThreadLog.list({Raxol.Agent.ThreadLog.Ets, %{}}, "symphony-agent-issue-1-4")

      assert Enum.any?(events, &(&1.kind == :state_snapshot))
    end
  end
end
