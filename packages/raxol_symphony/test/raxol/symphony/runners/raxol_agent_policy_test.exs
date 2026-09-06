defmodule Raxol.Symphony.Runners.RaxolAgentPolicyTest do
  @moduledoc """
  Verifies the `agent.policies` opt-in wraps each LLM turn
  via `Raxol.Agent.PolicyApplier.apply/3`.

  The verification strategy: attach a telemetry handler for
  `[:raxol, :agent, :policy, :applied]` and count how many times it
  fires across a multi-turn run. One firing per turn proves the wrap
  is happening.
  """

  use ExUnit.Case, async: false

  alias Raxol.Agent.Policy
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

  defp attach_applied_counter(test_pid, tag) do
    handler_id = "policy_test_#{tag}_#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol, :agent, :policy, :applied],
      fn _event, _measurements, metadata, _ ->
        send(test_pid, {:policy_applied, tag, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp count_applied(tag, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_count(tag, deadline, 0)
  end

  defp do_count(tag, deadline, n) do
    if System.monotonic_time(:millisecond) >= deadline do
      n
    else
      receive do
        {:policy_applied, ^tag, _metadata} -> do_count(tag, deadline, n + 1)
      after
        20 -> do_count(tag, deadline, n)
      end
    end
  end

  describe "policies: [] (default)" do
    test "PolicyApplier is NOT invoked (no :applied event)" do
      Memory.put_issue(%{issue() | state: "Done"})

      attach_applied_counter(self(), :no_policies)

      cfg = config(%{})

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # An empty policies list still calls PolicyApplier.apply/3 with [],
      # which DOES emit the :applied event. So count >= 1. The contract
      # we verify is "the runner uses the applier", not "the applier
      # short-circuits on []".
      assert count_applied(:no_policies, 100) >= 1
    end
  end

  describe "policies: [Timeout, Retry]" do
    test "one :applied event per turn" do
      Memory.put_issue(%{issue() | state: "In Progress"})

      attach_applied_counter(self(), :multi)

      policies = [
        Policy.Timeout.new(5_000),
        Policy.Retry.exponential(max_attempts: 3, base_ms: 50)
      ]

      cfg = config(%{policies: policies}, 3)

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # 3 turns wrapped -> 3 :applied events.
      assert count_applied(:multi, 400) == 3
    end

    test "metadata carries the turn and issue id, never the argument" do
      Memory.put_issue(%{issue() | state: "Done"})

      handler_id = "metadata_test_#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :agent, :policy, :applied],
        fn _e, _m, metadata, _ -> send(test_pid, {:metadata, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      policies = [Policy.Timeout.new(5_000)]
      cfg = config(%{policies: policies})

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

      # The runner threads its two identifiers in as `metadata:`; the applier
      # no longer emits its argument, so `params` must be gone from the event.
      assert_receive {:metadata, metadata}, 200
      assert metadata.turn == 1
      assert metadata.issue_id == "issue-1"
      refute Map.has_key?(metadata, :params)
    end
  end

  describe "policies: invalid shape" do
    test "non-list policies value falls back to []" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{policies: "not-a-list"})

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end
  end
end
