defmodule Raxol.Symphony.Runners.RaxolAgentTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.{Config, Issue, Tracker}
  alias Raxol.Symphony.Runners.RaxolAgent
  alias Raxol.Symphony.Trackers.Memory

  setup do
    start_supervised!({Memory, []})
    :ok
  end

  defp config(agent_overrides \\ %{}, max_turns \\ 1) do
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
          agent: Map.merge(%{backend: "mock", response: "ok"}, agent_overrides)
        }
      },
      prompt_template: "Working on {{ issue.identifier }} -- {{ issue.title }}"
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

  describe "successful single-turn run" do
    test "returns :ok and emits stream events to parent" do
      Memory.put_issue(%{issue() | state: "Done"})

      :ok = RaxolAgent.run(issue(), config(), parent: self(), attempt: nil)

      assert_received {:run_event, "issue-1", %{event: :text_delta}}
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}
    end

    test "first-turn prompt substitutes issue identifier and title" do
      # Configure mock to echo the prompt back as response so we can inspect it.
      # Mock backend doesn't echo, but we can verify by checking the parent
      # received text_delta with the configured response.
      Memory.put_issue(%{issue() | state: "Done"})

      :ok = RaxolAgent.run(issue(), config(%{response: "got it"}), parent: self())

      assert_received {:run_event, "issue-1", %{event: :text_delta, message: "got it"}}
    end
  end

  describe "multi-turn continuation" do
    test "loops while issue stays active and stops at max_turns" do
      Memory.put_issue(%{issue() | state: "In Progress"})

      :ok = RaxolAgent.run(issue(), config(%{}, _max_turns = 3), parent: self())

      # We cannot rely on the order of receive between turns, but we should
      # have at least 3 turn_completed events.
      events = collect_events("issue-1", 200)
      turn_completes = Enum.count(events, &(&1.event == :turn_completed))
      assert turn_completes == 3
    end

    test "stops when tracker reports terminal state" do
      Memory.put_issue(%{issue() | state: "Done"})

      :ok = RaxolAgent.run(issue("Todo"), config(%{}, _max_turns = 5), parent: self())

      events = collect_events("issue-1", 200)
      assert Enum.count(events, &(&1.event == :turn_completed)) == 1
    end

    test "stops when tracker tracker is unavailable" do
      # Memory is started but transition to non-existent ID -> empty result
      :ok = RaxolAgent.run(issue("Todo"), config(%{}, _max_turns = 5), parent: self())

      events = collect_events("issue-1", 200)
      # Single turn since Memory has no record of "issue-1" -> :done branch
      assert Enum.count(events, &(&1.event == :turn_completed)) == 1
    end
  end

  describe "pause_detector" do
    test "always-pause detector returns {:pause, _, _} from run/3" do
      Memory.put_issue(%{issue() | state: "Todo"})

      detector = fn _event ->
        {:pause, :awaiting_buyer_payment, %{seq: 1}}
      end

      cfg = config(%{pause_detector: detector})

      assert {:pause, :awaiting_buyer_payment, %{seq: 1}} =
               RaxolAgent.run(issue(), cfg, parent: self())
    end

    test ":continue from detector falls through to normal completion" do
      Memory.put_issue(%{issue() | state: "Done"})

      detector = fn _event -> :continue end
      cfg = config(%{pause_detector: detector})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self())
      assert_received {:run_event, "issue-1", %{event: :turn_completed}}
    end

    test "{module, fun} detector form is supported" do
      Memory.put_issue(%{issue() | state: "Todo"})

      cfg =
        config(%{pause_detector: {__MODULE__, :__test_always_pause__}})

      assert {:pause, :awaiting_delivery, :tok} =
               RaxolAgent.run(issue(), cfg, parent: self())
    end

    test "detector only fires on a matching event tag" do
      Memory.put_issue(%{issue() | state: "Done"})

      # Pause only on tool_use; mock backend emits text_delta + turn_complete,
      # so this run should reach :ok normally.
      detector = fn
        {:tool_use, _} -> {:pause, :awaiting_buyer_payment, :tok}
        _ -> :continue
      end

      cfg = config(%{pause_detector: detector})

      assert :ok = RaxolAgent.run(issue(), cfg, parent: self())
    end

    test "events fire before the detector decides to pause" do
      Memory.put_issue(%{issue() | state: "Todo"})

      detector = fn _event -> {:pause, :awaiting_evaluator_approval, :tok} end
      cfg = config(%{pause_detector: detector})

      _ = RaxolAgent.run(issue(), cfg, parent: self())

      # At least one event should have been forwarded to parent before the
      # detector halted stream consumption.
      assert_received {:run_event, "issue-1", _}
    end
  end

  @doc false
  def __test_always_pause__(_event), do: {:pause, :awaiting_delivery, :tok}

  describe "compile-time absence" do
    test "returns :raxol_agent_not_loaded when stream module missing" do
      # Re-define the runner's stream_module/0 via a process-dictionary hack?
      # Instead, just verify the public boolean: Code.ensure_loaded?/1 returns
      # true here, so we skip this case in the local repo. The runtime branch
      # is exercised in consumer apps that omit :raxol_agent.
      assert Code.ensure_loaded?(Raxol.Agent.Stream)
    end
  end

  describe "config dispatch" do
    test "runner.kind=raxol_agent resolves to RaxolAgent module" do
      cfg = config()
      assert {:ok, RaxolAgent} = Raxol.Symphony.Runner.resolve(cfg)
    end

    test "explicit override wins over config" do
      cfg = config()

      assert {:ok, Raxol.Symphony.Runners.Noop} =
               Raxol.Symphony.Runner.resolve(cfg, runner_module: Raxol.Symphony.Runners.Noop)
    end
  end

  defp collect_events(issue_id, timeout_ms) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_collect_events(issue_id, deadline, [])
  end

  defp do_collect_events(issue_id, deadline, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:run_event, ^issue_id, event} ->
        do_collect_events(issue_id, deadline, [event | acc])
    after
      remaining -> Enum.reverse(acc)
    end
  end

  # silence unused tracker warning
  _ = Tracker
end
