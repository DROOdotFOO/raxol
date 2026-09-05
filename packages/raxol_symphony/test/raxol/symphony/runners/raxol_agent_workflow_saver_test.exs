defmodule Raxol.Symphony.Runners.RaxolAgentWorkflowSaverTest do
  @moduledoc """
  A paused workflow-mode run pauses in one worker task and resumes in
  another, so its checkpoints have to outlive the process that wrote
  them.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Trackers.Memory
  alias Raxol.Workflow.Checkpoint.Saver

  @workspace "/tmp/raxol-symphony-test-workspace"

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp config(agent_overrides) do
    base = %{backend: "mock", response: "ok", workflow_mode: true}

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
          agent: Map.merge(base, agent_overrides)
        }
      },
      prompt_template: "Working on {{ issue.identifier }}"
    })
  end

  defp issue do
    %Issue{id: "issue-1", identifier: "MT-1", title: "T", state: "Todo"}
  end

  # Pauses on the first event, then passes through, so the resumed run
  # finishes instead of pausing again.
  defp pause_once_detector do
    {:ok, ref} = Agent.start_link(fn -> :first end)

    fn _event ->
      pause_on_first(Agent.get_and_update(ref, fn seen -> {seen, :later} end), ref)
    end
  end

  defp pause_on_first(:first, ref), do: {:pause, :awaiting_review, %{ref: ref}}
  defp pause_on_first(_later, _ref), do: :continue

  defp run_in_task(cfg, opts) do
    parent = self()

    Task.async(fn ->
      RaxolAgent.run(
        issue(),
        cfg,
        Keyword.merge([parent: parent, workspace_path: @workspace, attempt: nil], opts)
      )
    end)
    |> Task.await(5_000)
  end

  describe "no agent.workflow_saver" do
    test "a run that can pause is refused rather than left unresumable" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{pause_detector: pause_once_detector()})

      assert {:error, :no_durable_workflow_saver} =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end

    test "a run that cannot pause keeps the default saver" do
      Memory.put_issue(%{issue() | state: "Done"})

      assert :ok =
               RaxolAgent.run(issue(), config(%{}),
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end
  end

  describe "an agent.workflow_saver whose store outlives the worker" do
    # This covers the configuration the refusal above steers operators
    # towards, not the hazard itself: the default saver's table dying
    # with its first writer is a property of the worker task the
    # orchestrator spawns, which this suite does not stand up.
    test "a pause in one task resumes from another" do
      Memory.put_issue(%{issue() | state: "Done"})

      table = :sym_test_workflow_saver
      # Creating the table here makes the test process its owner, so it
      # outlives both worker tasks and goes away with the test. A table
      # created by the first writer instead dies with that writer.
      Saver.Ets.ensure_table(%{table: table})

      cfg =
        config(%{
          pause_detector: pause_once_detector(),
          workflow_saver: {Saver.Ets, %{table: table}}
        })

      assert {:pause, :awaiting_review, pause_token} = run_in_task(cfg, [])

      assert :ok =
               run_in_task(cfg,
                 resume_token: pause_token,
                 resume_value: :approved
               )
    end
  end
end
