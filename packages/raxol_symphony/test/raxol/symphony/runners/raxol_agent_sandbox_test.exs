defmodule Raxol.Symphony.Runners.RaxolAgentSandboxTest do
  @moduledoc """
  Phase 13: verifies the `agent.sandboxes` opt-in walks the
  `Raxol.Agent.Sandbox.Chain` for each turn and short-circuits on
  the first deny.

  Strategy: define test-only `Sandbox` impls (allow / abstain /
  deny) in `test/support/symphony_test_sandboxes.ex`, attach a
  telemetry handler for `[:raxol, :symphony, :sandbox, :denied]`,
  and verify call counts + run outcomes.
  """

  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.TestSupport.{AbstainSandbox, AllowSandbox, DenyTurnSandbox}
  alias Raxol.Symphony.Trackers.Memory

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

  defp attach_denied_counter(test_pid, tag) do
    handler_id = "sandbox_denied_#{tag}_#{:erlang.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol, :symphony, :sandbox, :denied],
      fn _e, _m, metadata, _ -> send(test_pid, {:denied, tag, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "sandboxes: [] (default)" do
    test "no chain walked; turn runs normally" do
      Memory.put_issue(%{issue() | state: "Done"})

      attach_denied_counter(self(), :default)

      cfg = config(%{})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # No denied telemetry should fire on the empty chain.
      refute_receive {:denied, :default, _}, 50
    end
  end

  describe "sandboxes: [AllowSandbox]" do
    test "all-:ok chain runs the turn" do
      Memory.put_issue(%{issue() | state: "Done"})

      attach_denied_counter(self(), :allow)

      cfg = config(%{sandboxes: [%AllowSandbox{}]})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      refute_receive {:denied, :allow, _}, 50

      # Mock backend's events should still arrive.
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}
    end
  end

  describe "sandboxes: [DenyTurnSandbox]" do
    test "first deny short-circuits the turn and fires :denied telemetry" do
      Memory.put_issue(%{issue() | state: "Done"})

      attach_denied_counter(self(), :deny)

      cfg =
        config(%{
          sandboxes: [%DenyTurnSandbox{reason: :budget_exhausted}]
        })

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      assert_receive {:denied, :deny, metadata}, 200
      assert metadata.action == :turn
      assert metadata.reason == :budget_exhausted
      assert metadata.agent_id == "issue-1"
      assert metadata.turn == 1

      # The mock backend's events should NOT arrive (no stream was
      # pulled).
      refute_received {:run_event, "issue-1", %{event: :turn_completed}}
    end

    test "deny fires once per turn under multi-turn config" do
      Memory.put_issue(%{issue() | state: "In Progress"})

      attach_denied_counter(self(), :deny_multi)

      cfg = config(%{sandboxes: [%DenyTurnSandbox{reason: :rate_limit}]}, 3)

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # Three turns, three denies (since each turn re-walks the chain).
      assert_receive {:denied, :deny_multi, _}, 200
      assert_receive {:denied, :deny_multi, _}, 200
      assert_receive {:denied, :deny_multi, _}, 200

      # The mock backend never streamed.
      refute_received {:run_event, "issue-1", %{event: :turn_completed}}
    end
  end

  describe "chain composition" do
    test "allow then deny: deny wins" do
      Memory.put_issue(%{issue() | state: "Done"})

      attach_denied_counter(self(), :compose)

      cfg =
        config(%{
          sandboxes: [
            %AllowSandbox{},
            %AbstainSandbox{},
            %DenyTurnSandbox{reason: :downstream_block}
          ]
        })

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      assert_receive {:denied, :compose, metadata}, 200
      assert metadata.reason == :downstream_block
    end

    test "deny first: short-circuits before reaching the allow" do
      Memory.put_issue(%{issue() | state: "Done"})

      attach_denied_counter(self(), :compose_short)

      cfg =
        config(%{
          sandboxes: [
            %DenyTurnSandbox{reason: :first_block},
            %AllowSandbox{}
          ]
        })

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      assert_receive {:denied, :compose_short, %{reason: :first_block}}, 200
    end
  end

  describe "sandboxes: invalid shape" do
    test "non-list value falls back to []" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{sandboxes: "not-a-list"})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)
    end
  end
end
