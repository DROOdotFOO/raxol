defmodule Raxol.Symphony.Runners.RaxolAgent.AgentWorkflowTest do
  @moduledoc """
  Phase 7-specific tests for the multi-node `AgentWorkflow` graph:
  the LLM turn (`:turn_N`) is checkpointed independently from the
  decision step (`:after_turn_N`), so a pause + resume cycle MUST
  re-run only the after node -- never the LLM stream.

  The cheapest way to verify this is to count `:turn_completed`
  events forwarded to the parent across a pause/resume. The mock
  backend emits exactly one `:turn_completed` per `Raxol.Agent.Stream`
  run, so the count equals the number of LLM turns executed.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp config(agent_overrides, max_turns \\ 1) do
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
      prompt_template: "Working on {{ issue.identifier }}"
    })
  end

  defp issue(state \\ "Todo") do
    %Issue{
      id: "issue-1",
      identifier: "MT-1",
      title: "T",
      state: state
    }
  end

  defp count_turn_completed(issue_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_count(issue_id, deadline, 0)
  end

  defp do_count(issue_id, deadline, count) do
    if System.monotonic_time(:millisecond) >= deadline do
      count
    else
      receive do
        {:run_event, ^issue_id, %{event: :turn_completed}} ->
          do_count(issue_id, deadline, count + 1)

        {:run_event, ^issue_id, _other} ->
          do_count(issue_id, deadline, count)
      after
        20 -> do_count(issue_id, deadline, count)
      end
    end
  end

  describe "Phase 7: per-turn checkpointing" do
    test "pause + resume re-runs the after node, NOT the LLM turn" do
      # Stateful detector that pauses on its first invocation, then
      # passes through. We expect exactly ONE :turn_completed event
      # forwarded across the entire pause+resume cycle.
      Memory.put_issue(%{issue() | state: "Done"})

      {:ok, ref} = Agent.start_link(fn -> :first end)

      detector = fn _event ->
        case Agent.get_and_update(ref, fn s -> {s, :later} end) do
          :first -> {:pause, :awaiting_review, %{ref: ref}}
          _ -> :continue
        end
      end

      cfg = config(%{pause_detector: detector})

      # Pause on turn 1.
      assert {:pause, :awaiting_review, pause_token} =
               RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # Resume. Phase 7's after_turn_1 re-runs, calls Workflow.interrupt
      # which now returns the resume_value, clears pause_request,
      # checks tracker (Done -> :done), finishes with :ok. The :turn_1
      # node body does NOT re-run, so no second :turn_completed event
      # is forwarded.
      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 attempt: nil,
                 resume_token: pause_token,
                 resume_value: :approved
               )

      # Phase 6 (single-node) would have produced 2 :turn_completed
      # events here (turn re-ran on resume). Phase 7 produces 1.
      assert count_turn_completed("issue-1", 200) == 1
    end

    test "non-paused multi-turn run forwards one :turn_completed per turn" do
      Memory.put_issue(%{issue() | state: "In Progress"})

      cfg = config(%{}, 3)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # 3 turns -> 3 turn_completed events.
      assert count_turn_completed("issue-1", 400) == 3
    end

    test "pause request is QUEUED -- the rest of the turn still streams" do
      # Detector pauses on the first event, but the turn's remaining
      # events (text_delta + turn_completed from the mock backend) are
      # still forwarded to the parent. The pause fires at the turn
      # boundary in :after_turn_1.
      Memory.put_issue(%{issue() | state: "Todo"})

      detector = fn _event -> {:pause, :awaiting_review, :tok} end

      cfg = config(%{pause_detector: detector})

      assert {:pause, :awaiting_review, _token} =
               RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # The mock backend's events still arrived even though the very
      # first event triggered pause. Specifically: turn_completed
      # arrived too.
      assert count_turn_completed("issue-1", 200) == 1
    end
  end
end
