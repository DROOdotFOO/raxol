defmodule Raxol.Symphony.Runners.RaxolAgentModuleMetadataTest do
  @moduledoc """
  Verifies the Symphony RaxolAgent runner picks up sandbox/0 and
  thread_log/0 declared on a `use Raxol.Agent` module via
  `agent.module` config.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.TestSupport.AgentWithMetadata
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

  defp attach_denied(test_pid) do
    handler_id = "metadata_denied_#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol, :symphony, :sandbox, :denied],
      fn _e, _m, metadata, _ -> send(test_pid, {:denied, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "agent.module sandbox extraction" do
    test "module.sandbox/0 entries are appended to the per-turn chain" do
      Memory.put_issue(%{issue() | state: "Done"})
      attach_denied(self())

      cfg = config(%{module: AgentWithMetadata})

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # AgentWithMetadata's sandbox/0 includes a DenyTurnSandbox with
      # reason :module_deny -- the runner picked it up.
      assert_receive {:denied, %{reason: :module_deny}}, 200
    end

    test "agent.sandboxes config + module.sandbox/0 compose first-to-last" do
      Memory.put_issue(%{issue() | state: "Done"})
      attach_denied(self())

      # Direct sandbox denies with a different reason. It should fire
      # before the module-declared one because config sandboxes are
      # prepended.
      direct_sandbox = %Raxol.Symphony.TestSupport.DenyTurnSandbox{reason: :direct_deny}

      cfg =
        config(%{
          module: AgentWithMetadata,
          sandboxes: [direct_sandbox]
        })

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # First-deny-wins: the direct config sandbox fired, not the
      # module-declared one.
      assert_receive {:denied, %{reason: :direct_deny}}, 200
      refute_received {:denied, %{reason: :module_deny}}
    end
  end

  describe "agent.module thread_log default" do
    test "module.thread_log/0 is used when agent.thread_log is unset" do
      table = :symphony_test_module_thread_log

      on_exit(fn ->
        if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      end)

      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{module: AgentWithMetadata})

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 0
               )

      # The module-declared thread_log captured the run's snapshot
      # despite agent.thread_log being unset.
      {:ok, events} =
        Raxol.Agent.ThreadLog.list(
          {Raxol.Agent.ThreadLog.Ets, %{table: table}},
          "symphony-agent-issue-1-0"
        )

      assert Enum.any?(events, &(&1.kind == :state_snapshot))
    end

    test "agent.thread_log config wins over module.thread_log/0" do
      table = :"direct_thread_log_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      end)

      direct = {Raxol.Agent.ThreadLog.Ets, %{table: table}}

      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{module: AgentWithMetadata, thread_log: direct})

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 7
               )

      # Direct config got the events.
      {:ok, direct_events} =
        Raxol.Agent.ThreadLog.list(direct, "symphony-agent-issue-1-7")

      assert direct_events != []
    end
  end
end
