defmodule Raxol.Agent.OrchestratorTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Orchestrator
  # Minimal agent for orchestrator tests
  defmodule SimpleAgent do
    def init(_opts), do: {:ok, %{status: :idle}}
    def observe(_events, state), do: {:ok, %{}, state}
    def think(_observation, state), do: {:wait, state}
    def act(_action, state), do: {:ok, state}
    def receive_directive(_directive, state), do: {:ok, state}
    def on_takeover(state), do: {:ok, Map.put(state, :taken_over, true)}
    def on_resume(state), do: {:ok, Map.put(state, :resumed, true)}
    def context_snapshot(state), do: state
    def restore_context(snapshot), do: {:ok, snapshot}
  end

  setup do
    Raxol.Agent.ContextStore.init()

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})

    orch = start_supervised!(Orchestrator)
    %{orch: orch}
  end

  describe "spawn_agent/4" do
    test "spawns an agent and assigns a pane", %{orch: orch} do
      assert {:ok, :scout} =
               Orchestrator.spawn_agent(orch, :scout, SimpleAgent, tick_ms: 50_000)

      layout = Orchestrator.get_layout(orch)
      assert layout.agent_count == 1
      assert Map.has_key?(layout.panes, :scout)
    end

    test "auto-focuses the first agent", %{orch: orch} do
      Orchestrator.spawn_agent(orch, :first, SimpleAgent, tick_ms: 50_000)

      layout = Orchestrator.get_layout(orch)
      assert layout.focused == :first
    end

    test "rejects duplicate agent ids", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :dup, SimpleAgent, tick_ms: 50_000)

      assert {:error, :already_exists} =
               Orchestrator.spawn_agent(orch, :dup, SimpleAgent, tick_ms: 50_000)
    end
  end

  describe "kill_agent/2" do
    test "removes the agent and its pane", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :doomed, SimpleAgent, tick_ms: 50_000)

      :ok = Orchestrator.kill_agent(orch, :doomed)

      layout = Orchestrator.get_layout(orch)
      assert layout.agent_count == 0
      refute Map.has_key?(layout.panes, :doomed)
    end

    test "shifts focus when focused agent is killed", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :a1, SimpleAgent, tick_ms: 50_000)
      {:ok, _} = Orchestrator.spawn_agent(orch, :a2, SimpleAgent, tick_ms: 50_000)

      Orchestrator.focus_pane(orch, :a1)
      Orchestrator.kill_agent(orch, :a1)

      layout = Orchestrator.get_layout(orch)
      # Focus should shift to remaining agent
      assert layout.focused == :a2
    end
  end

  describe "focus_pane/2" do
    test "switches focused pane", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :p1, SimpleAgent, tick_ms: 50_000)
      {:ok, _} = Orchestrator.spawn_agent(orch, :p2, SimpleAgent, tick_ms: 50_000)

      :ok = Orchestrator.focus_pane(orch, :p2)

      layout = Orchestrator.get_layout(orch)
      assert layout.focused == :p2
    end

    test "rejects invalid pane", %{orch: orch} do
      assert {:error, :pane_not_found} = Orchestrator.focus_pane(orch, :nonexistent)
    end
  end

  describe "pilot_takeover/1 and pilot_release/1" do
    test "takeover puts orchestrator in takeover mode", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :target, SimpleAgent, tick_ms: 50_000)

      :ok = Orchestrator.pilot_takeover(orch)

      layout = Orchestrator.get_layout(orch)
      assert layout.pilot_mode == :takeover
    end

    test "release returns to observe mode", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :target, SimpleAgent, tick_ms: 50_000)

      :ok = Orchestrator.pilot_takeover(orch)
      :ok = Orchestrator.pilot_release(orch)

      layout = Orchestrator.get_layout(orch)
      assert layout.pilot_mode == :observe
    end

    test "takeover fails without focused pane", %{orch: orch} do
      assert {:error, :no_focused_pane} = Orchestrator.pilot_takeover(orch)
    end
  end

  describe "send_directive/3" do
    test "sends directive to a specific agent", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :worker, SimpleAgent, tick_ms: 50_000)

      assert :ok = Orchestrator.send_directive(orch, :worker, {:task, "analyze"})
    end

    test "returns error for unknown agent", %{orch: orch} do
      assert {:error, :not_found} =
               Orchestrator.send_directive(orch, :ghost, {:task, "analyze"})
    end
  end

  describe "broadcast_directive/2" do
    test "sends directive to all agents", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :w1, SimpleAgent, tick_ms: 50_000)
      {:ok, _} = Orchestrator.spawn_agent(orch, :w2, SimpleAgent, tick_ms: 50_000)

      # Should not raise
      :ok = Orchestrator.broadcast_directive(orch, {:priority, :high})
    end
  end

  describe "send_input/2" do
    test "routes input to focused agent during takeover", %{orch: orch} do
      fake_terminal = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, _} =
        Orchestrator.spawn_agent(orch, :input_target, SimpleAgent,
          tick_ms: 50_000,
          terminal_pid: fake_terminal
        )

      :ok = Orchestrator.pilot_takeover(orch)
      assert :ok = Orchestrator.send_input(orch, "hello")
    end

    test "rejects input when not in takeover mode", %{orch: orch} do
      {:ok, _} =
        Orchestrator.spawn_agent(orch, :no_takeover, SimpleAgent, tick_ms: 50_000)

      assert {:error, :not_in_takeover} = Orchestrator.send_input(orch, "hello")
    end

    test "rejects input with no focused pane", %{orch: orch} do
      assert {:error, :not_in_takeover} = Orchestrator.send_input(orch, "hello")
    end

    test "returns error when pane has no terminal", %{orch: orch} do
      {:ok, _} =
        Orchestrator.spawn_agent(orch, :no_term, SimpleAgent, tick_ms: 50_000)

      :ok = Orchestrator.pilot_takeover(orch)
      assert {:error, :no_terminal} = Orchestrator.send_input(orch, "hello")
    end
  end

  describe "recommendation handling" do
    test "stores pending recommendation from layout_recommendation message", %{orch: orch} do
      rec = %{
        id: "rec1",
        layout_changes: [%{pane_id: :scout, action: :hide, params: %{}}],
        confidence: 0.85,
        reasoning: "test",
        timestamp: 0
      }

      send(orch, {:layout_recommendation, rec})
      Process.sleep(10)

      assert Orchestrator.get_pending_recommendation(orch) == rec
    end

    test "accept clears pending and notifies subscribers", %{orch: orch} do
      Orchestrator.subscribe(orch)

      rec = %{id: "rec2", layout_changes: [], confidence: 0.8, reasoning: "", timestamp: 0}
      send(orch, {:layout_recommendation, rec})
      assert_receive {:orchestrator_event, {:recommendation_pending, ^rec}}, 100

      :ok = Orchestrator.accept_recommendation(orch)

      assert_receive {:orchestrator_event, {:recommendation_accepted, ^rec}}, 100
      assert Orchestrator.get_pending_recommendation(orch) == nil
    end

    test "reject clears pending and notifies subscribers", %{orch: orch} do
      Orchestrator.subscribe(orch)

      rec = %{id: "rec3", layout_changes: [], confidence: 0.8, reasoning: "", timestamp: 0}
      send(orch, {:layout_recommendation, rec})
      assert_receive {:orchestrator_event, {:recommendation_pending, ^rec}}, 100

      :ok = Orchestrator.reject_recommendation(orch)

      assert_receive {:orchestrator_event, {:recommendation_rejected, ^rec}}, 100
      assert Orchestrator.get_pending_recommendation(orch) == nil
    end

    test "accept/reject with no pending returns error", %{orch: orch} do
      assert {:error, :no_pending} = Orchestrator.accept_recommendation(orch)
      assert {:error, :no_pending} = Orchestrator.reject_recommendation(orch)
    end
  end

  describe "get_statuses/1" do
    test "returns status for all agents", %{orch: orch} do
      {:ok, _} = Orchestrator.spawn_agent(orch, :s1, SimpleAgent, tick_ms: 50_000)
      {:ok, _} = Orchestrator.spawn_agent(orch, :s2, SimpleAgent, tick_ms: 50_000)

      statuses = Orchestrator.get_statuses(orch)

      assert Map.has_key?(statuses, :s1)
      assert Map.has_key?(statuses, :s2)
      assert statuses[:s1].agent_id == :s1
    end
  end

  describe "agent crash self-heal" do
    test "rebinds to the supervisor-restarted pid after a crash", %{orch: orch} do
      {:ok, :resilient} =
        Orchestrator.spawn_agent(orch, :resilient, SimpleAgent, tick_ms: 50_000)

      original = registered_pid(:resilient)
      assert is_pid(original)

      Process.exit(original, :kill)

      # The DynamicSupervisor restarts the agent under the same Registry name.
      wait_until(fn ->
        case registered_pid(:resilient) do
          pid when is_pid(pid) -> pid != original and Process.alive?(pid)
          _ -> false
        end
      end)

      restarted = registered_pid(:resilient)
      assert is_pid(restarted)
      assert restarted != original

      # The orchestrator heals its own view: the agent reports a live status,
      # not the stale-pid :dead, and its pane is retained.
      wait_until(fn ->
        statuses = Orchestrator.get_statuses(orch)
        match?(%{status: status} when status != :dead, statuses[:resilient])
      end)

      statuses = Orchestrator.get_statuses(orch)
      assert statuses[:resilient].status in [:waiting, :thinking]

      layout = Orchestrator.get_layout(orch)
      assert layout.agent_count == 1
      assert Map.has_key?(layout.panes, :resilient)
      assert layout.panes[:resilient].agent_pid == restarted
    end

    test "kill_agent removes the agent permanently with no restart", %{orch: orch} do
      {:ok, :doomed_perm} =
        Orchestrator.spawn_agent(orch, :doomed_perm, SimpleAgent, tick_ms: 50_000)

      assert is_pid(registered_pid(:doomed_perm))

      :ok = Orchestrator.kill_agent(orch, :doomed_perm)

      layout = Orchestrator.get_layout(orch)
      assert layout.agent_count == 0
      refute Map.has_key?(layout.panes, :doomed_perm)

      # A deliberate kill is not a crash: the supervisor does not bring it back.
      wait_until(fn -> registered_pid(:doomed_perm) == nil end)
      refute Map.has_key?(Orchestrator.get_statuses(orch), :doomed_perm)
    end
  end

  defp registered_pid(agent_id) do
    case Registry.lookup(Raxol.Agent.Registry, {:process, agent_id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  # Polls a predicate up to a bound; deterministic, no timing assertions.
  defp wait_until(fun, attempts \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
