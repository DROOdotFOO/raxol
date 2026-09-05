defmodule Raxol.Symphony.Runners.RaxolAgentWorkflowEnvelopeTest do
  @moduledoc """
  Validates that `agent.workflow_mode: true` routes the
  RaxolAgent runner through `Raxol.Workflow.Compiled.invoke/resume`
  while preserving the existing `Runner.run/3` contract:

    * `:ok` on a clean finish.
    * `{:pause, reason, token}` on a detector pause, with the workflow's
      run_id embedded in the token.
    * `{:error, reason}` on a runner error.
    * Resume via `:resume_token` + `:resume_value` calls `Compiled.resume`
      and continues past the pause.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Trackers.Memory

  # The orchestrator allocates a per-issue workspace and the runner requires
  # it; these cases assert other behaviour, so any path will do.
  @workspace "/tmp/raxol-symphony-test-workspace"

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp config(agent_overrides, max_turns \\ 1)

  defp config(agent_overrides, max_turns) do
    base = %{
      backend: "mock",
      response: "ok",
      workflow_mode: true
    }

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
      title: "Refactor X",
      state: state
    }
  end

  # A detector under workflow_mode needs a saver whose store outlives
  # the process that writes the checkpoint. Creating the table here
  # makes the test process its owner.
  defp workflow_saver do
    table = :sym_test_envelope_saver
    Raxol.Workflow.Checkpoint.Saver.Ets.ensure_table(%{table: table})
    {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}
  end

  describe "workflow_mode: true happy path" do
    test ":ok when the tracker reports terminal mid-loop" do
      # State Done at start -> after turn 1 the tracker check returns :done,
      # node body returns :done, iterate/1 wraps as {:ok, state} with
      # run_result :ok.
      Memory.put_issue(%{issue() | state: "Done"})

      assert :ok =
               RaxolAgent.run(issue(), config(%{}, 3),
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # Events were still forwarded from the mock backend.
      assert_received {:run_event, "issue-1", %{event: :text_delta}}
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}
    end

    test ":ok when max_turns is reached" do
      Memory.put_issue(%{issue() | state: "In Progress"})

      assert :ok =
               RaxolAgent.run(issue(), config(%{}, 2),
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      events = collect_events("issue-1", 200)
      # Two full turns under workflow_mode.
      assert Enum.count(events, &(&1.event == :turn_completed)) == 2
    end
  end

  describe "workflow_mode: true pause path" do
    test "pause_detector firing routes through Workflow.interrupt + surfaces {:pause, reason, token}" do
      Memory.put_issue(%{issue() | state: "Todo"})

      pause_token = %{seq: 1, context: "from-detector"}

      detector = fn _event ->
        {:pause, :awaiting_buyer_payment, pause_token}
      end

      cfg = config(%{pause_detector: detector, workflow_saver: workflow_saver()})

      assert {:pause, :awaiting_buyer_payment, token} =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # The runner-level token carries workflow_run_id so the orchestrator
      # can route a later resume_run/3 back through Compiled.resume.
      assert is_binary(token.workflow_run_id)
      assert token.issue_id == "issue-1"
      assert token.paused_via == :workflow
    end

    test "resume_token + resume_value continues past the pause" do
      Memory.put_issue(%{issue() | state: "Done"})

      # Stateful detector: pauses ONCE, then passes through on subsequent
      # invocations (i.e., the resumed turn re-runs but the detector now
      # says continue).
      {:ok, pid} = Agent.start_link(fn -> :first end)

      detector = fn _event ->
        case Agent.get_and_update(pid, fn s -> {s, :second} end) do
          :first -> {:pause, :awaiting_external, %{handle: pid}}
          _ -> :continue
        end
      end

      cfg = config(%{pause_detector: detector, workflow_saver: workflow_saver()})

      # First pass pauses.
      assert {:pause, :awaiting_external, pause_token} =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      assert is_binary(pause_token.workflow_run_id)

      # Resume: pass the same config (with the now-:second detector) and the
      # prior token + resume_value. The runner calls Compiled.resume; the
      # node body re-runs from the top, the detector returns :continue, the
      # mock backend's :done event completes the turn.
      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil,
                 resume_token: pause_token,
                 resume_value: :approved
               )
    end
  end

  describe "workflow_mode: false is unchanged" do
    test "the default (no flag) still uses the legacy do_run path" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg =
        Config.from_workflow(%{
          config: %{
            tracker: %{
              kind: "memory",
              active_states: ["Todo", "In Progress"],
              terminal_states: ["Done", "Cancelled"]
            },
            agent: %{max_turns: 1},
            runner: %{
              kind: "raxol_agent",
              agent: %{backend: "mock", response: "ok"}
            }
          },
          prompt_template: ""
        })

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end
  end

  defp collect_events(issue_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect(issue_id, deadline, [])
  end

  defp do_collect(issue_id, deadline, acc) do
    if System.monotonic_time(:millisecond) >= deadline do
      Enum.reverse(acc)
    else
      receive do
        {:run_event, ^issue_id, payload} ->
          do_collect(issue_id, deadline, [payload | acc])
      after
        20 -> do_collect(issue_id, deadline, acc)
      end
    end
  end
end
