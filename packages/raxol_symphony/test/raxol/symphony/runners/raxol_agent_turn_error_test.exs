defmodule Raxol.Symphony.Runners.RaxolAgentTurnErrorTest.TruncatedBackend do
  @moduledoc """
  Backend whose stream ends without a `{:done, _}` event, the shape a
  provider connection dropped mid-turn produces.
  """

  @behaviour Raxol.Agent.AIBackend

  @impl true
  def complete(_messages, _opts), do: {:error, :truncated}

  @impl true
  def stream(_messages, _opts), do: {:ok, [{:chunk, "half an ans"}]}

  @impl true
  def available?, do: true

  @impl true
  def name, do: "Truncated Backend"

  @impl true
  def capabilities, do: [:streaming]
end

defmodule Raxol.Symphony.Runners.RaxolAgentTurnErrorTest do
  @moduledoc """
  Verifies per-turn error propagation.

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
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
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
      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )

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

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end

    test "all-pass policies: :ok" do
      Memory.put_issue(%{issue() | state: "Done"})

      cfg = config(%{policies: [Policy.Timeout.new(5_000)]})

      assert :ok =
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: nil
               )
    end
  end

  describe "a turn whose stream never completes" do
    test "a backend error surfaces as {:error, reason}, not a clean turn" do
      state = turn_state(backend_opts: [error: {:http_status, 401}])

      assert {:error, {:http_status, 401}} =
               RaxolAgent.__workflow_collect_turn__(state)

      # The failure is still forwarded, so the run feed shows what happened.
      assert_received {:run_event, "issue-1", %{event: :turn_failed}}
    end

    test "a stream that ends without :done surfaces as {:error, :no_done}" do
      state =
        turn_state(
          backend: Raxol.Symphony.Runners.RaxolAgentTurnErrorTest.TruncatedBackend,
          backend_opts: []
        )

      assert {:error, :no_done} = RaxolAgent.__workflow_collect_turn__(state)
    end

    test "a queued pause still wins over a stream error" do
      state =
        turn_state(
          backend_opts: [error: :boom],
          pause_detector: fn _event -> {:pause, :awaiting_review, :tok} end
        )

      assert {:ok, _events, {:pause, :awaiting_review, :tok}} =
               RaxolAgent.__workflow_collect_turn__(state)
    end
  end

  describe "policies see a failed turn as a failure" do
    test "Retry re-attempts a stream error" do
      state =
        turn_state(
          backend_opts: [error: {:http_status, 429}],
          policies: [Policy.Retry.exponential(max_attempts: 3, base_ms: 0)]
        )

      assert {:error, {:http_status, 429}} =
               RaxolAgent.__workflow_collect_turn__(state)

      # One forwarded failure per attempt: the provider was called three
      # times, not once with two silent successes.
      assert length(forwarded_turn_failures()) == 3
    end

    test "Cache does not memoize a failed turn" do
      table = :"sym_test_policy_cache_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      end)

      policy =
        Policy.Cache.ets(ttl_ms: 60_000, key_fn: fn _params -> :turn end, table: table)

      state =
        turn_state(
          backend_opts: [error: {:http_status, 429}],
          policies: [policy]
        )

      assert {:error, {:http_status, 429}} =
               RaxolAgent.__workflow_collect_turn__(state)

      assert :miss = Raxol.Agent.Cache.get(policy.storage, :turn)

      # A memoized failure would short-circuit the second turn without
      # reaching the provider, so the retry could never recover.
      assert {:error, {:http_status, 429}} =
               RaxolAgent.__workflow_collect_turn__(state)

      assert length(forwarded_turn_failures()) == 2
    end
  end

  defp forwarded_turn_failures do
    receive do
      {:run_event, "issue-1", %{event: :turn_failed}} ->
        [:turn_failed | forwarded_turn_failures()]
    after
      0 -> []
    end
  end

  # The turn body reads its backend straight off the workflow state, so a
  # failing provider is expressible without one. Mirrors the map
  # `build_workflow_state/5` hands to `AgentWorkflow.run_turn/1`.
  defp turn_state(overrides) do
    %{
      issue: issue(),
      config: config(%{}),
      parent: self(),
      attempt: nil,
      backend: Raxol.Agent.Backend.Mock,
      backend_opts: [response: "ok"],
      system_prompt: nil,
      pause_detector: nil,
      turn: 1,
      max_turns: 1,
      policies: [],
      sandboxes: [],
      thread_log: nil,
      thread_id: "symphony-agent-issue-1-0"
    }
    |> Map.merge(Map.new(overrides))
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
               RaxolAgent.run(issue(), cfg,
                 parent: self(),
                 workspace_path: @workspace,
                 attempt: 9
               )

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
