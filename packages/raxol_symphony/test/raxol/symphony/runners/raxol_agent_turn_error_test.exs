defmodule Raxol.Symphony.Runners.RaxolAgentTurnErrorTest do
  @moduledoc """
  Phase 14: verifies per-turn error propagation.

  Policy failures (retries exhausted, timeout) surface as
  `{:error, {:policy_failed, reason}}` from `RaxolAgent.run/3`, so
  the orchestrator's failure-retry ladder kicks in with exponential
  backoff. Sandbox denies stay graceful: `:ok` from `run/3` with
  the `[:raxol, :symphony, :sandbox, :denied]` telemetry firing
  -- the orchestrator's failure-retry on every deny would be
  wasteful (the next attempt would just be denied again).
  """

  use ExUnit.Case, async: false

  alias Raxol.Agent.Policy
  alias Raxol.Symphony.{Config, Issue}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.TestSupport.DenyTurnSandbox
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

  describe "Policy.Timeout that always fires" do
    test "surfaces as {:error, {:policy_failed, :timeout}} from run/3" do
      Memory.put_issue(%{issue() | state: "In Progress"})

      # Wall ms of 1 means the mock backend's microsecond completion is
      # still likely to BEAT the timeout; force the failure by combining
      # Timeout with a Retry policy that exhausts. Cleaner: use a
      # Timeout of 1 with a synthetic slow backend... but the mock
      # is fast. Instead use Retry alone with a synthetic op-fail via
      # a backend that throws -- nope, mock doesn't throw.
      #
      # Easiest reliable failure: use Retry with max_attempts: 1 against
      # a backend that signals an error. The Mock has no error mode,
      # so we wrap with a Timeout of 1ms but force a sleep in opts.
      # The mock has `latency_ms` -- crank it past the timeout.
      policies = [Policy.Timeout.new(5)]

      cfg = config(%{policies: policies, latency_ms: 200})

      assert {:error, {:policy_failed, :timeout}} =
               RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)
    end
  end

  describe "Sandbox deny" do
    test "surfaces as :ok from run/3 (NOT a hard error)" do
      Memory.put_issue(%{issue() | state: "Done"})

      handler_id = "sandbox_deny_test_#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :symphony, :sandbox, :denied],
        fn _e, _m, metadata, _ -> send(test_pid, {:denied, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      cfg =
        config(%{
          sandboxes: [%DenyTurnSandbox{reason: :rate_limit_per_hour}]
        })

      # Deny IS surfaced as :ok -- the orchestrator's retry layer
      # would do nothing useful here (every retry would deny again).
      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)

      # The telemetry handler caught the deny -- this is the
      # operator-visible signal.
      assert_receive {:denied, metadata}, 200
      assert metadata.reason == :rate_limit_per_hour
    end
  end

  describe "Successful runs are unchanged" do
    test "no policies + no sandboxes: :ok" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{})
      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)
    end

    test "all-pass policies: :ok" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{policies: [Policy.Timeout.new(5_000)]})
      assert :ok = RaxolAgent.run(issue(), cfg, parent: self(), attempt: nil)
    end
  end

  describe "ThreadLog audit on error" do
    test ":state_snapshot is appended with error field set when the turn fails" do
      thread_log_table =
        :"sym_test_threadlog_error_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        if :ets.whereis(thread_log_table) != :undefined,
          do: :ets.delete(thread_log_table)
      end)

      adapter = {Raxol.Agent.ThreadLog.Ets, %{table: thread_log_table}}

      Memory.put_issue(%{issue() | state: "In Progress"})

      cfg =
        config(%{
          thread_log: adapter,
          policies: [Policy.Timeout.new(5)],
          latency_ms: 200
        })

      assert {:error, {:policy_failed, :timeout}} =
               RaxolAgent.run(issue(), cfg, parent: self(), attempt: 9)

      {:ok, events} =
        Raxol.Agent.ThreadLog.list(
          adapter,
          "symphony-agent-issue-1-9"
        )

      snapshots = Enum.filter(events, &(&1.kind == :state_snapshot))
      assert length(snapshots) >= 1
      [first | _] = snapshots
      assert first.payload.error == {:policy_failed, :timeout}
      assert first.payload.event_count == 0
    end
  end
end
