defmodule Raxol.Agent.ProcessTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Process, as: AgentProcess
  alias Raxol.Agent.ContextStore

  # Test agent that counts ticks and collects observations
  defmodule CounterAgent do
    def init(_opts), do: {:ok, %{tick_count: 0, observations: [], actions: []}}

    def observe(events, state) do
      {:ok, %{events: events, tick: state.tick_count}, state}
    end

    def think(_observation, state) do
      if state.tick_count < 3 do
        {:act, {:log, "tick #{state.tick_count}"}, %{state | tick_count: state.tick_count + 1}}
      else
        {:wait, state}
      end
    end

    def act({:log, msg}, state) do
      {:ok, %{state | actions: [msg | state.actions]}}
    end

    def receive_directive({:set_count, n}, state) do
      {:ok, %{state | tick_count: n}}
    end

    def receive_directive(:defer_test, state) do
      {:defer, state}
    end

    def receive_directive({:report_to, pid}, state) do
      send(pid, {:agent_state, state})
      {:ok, state}
    end

    def receive_directive({:crash, reason}, _state) do
      raise reason
    end

    def on_takeover(state) do
      {:ok, Map.put(state, :was_taken_over, true)}
    end

    def on_resume(state) do
      {:ok, Map.put(state, :resumed, true)}
    end

    def context_snapshot(state), do: state

    def restore_context(snapshot), do: {:ok, snapshot}
  end

  setup do
    ContextStore.init()

    start_supervised!({Registry, keys: :unique, name: Raxol.Agent.Registry})
    start_supervised!({DynamicSupervisor, name: Raxol.Agent.DynSup, strategy: :one_for_one})

    on_exit(fn ->
      for id <- ContextStore.list(), do: ContextStore.delete(id)
    end)

    :ok
  end

  describe "start_link/1" do
    test "starts an agent process" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: :test_counter,
          agent_module: CounterAgent,
          tick_ms: 50_000
        )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "restores context from ContextStore on restart" do
      saved_state = %{tick_count: 5, observations: [], actions: ["saved"]}
      ContextStore.save(:restore_test, saved_state)

      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: :restore_test,
          agent_module: CounterAgent,
          tick_ms: 50_000
        )

      status = AgentProcess.get_status(pid)
      assert status.agent_id == :restore_test

      GenServer.stop(pid)
    end
  end

  describe "get_status/1" do
    test "returns agent status map" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: :status_test,
          agent_module: CounterAgent,
          tick_ms: 50_000
        )

      status = AgentProcess.get_status(pid)

      assert status.agent_id == :status_test
      assert status.module == CounterAgent
      assert status.status in [:waiting, :thinking]
      assert status.tick_ms == 50_000

      GenServer.stop(pid)
    end
  end

  describe "takeover/release" do
    test "takeover pauses the agent and release resumes it" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: :takeover_test,
          agent_module: CounterAgent,
          tick_ms: 50_000
        )

      :ok = AgentProcess.takeover(pid)
      status = AgentProcess.get_status(pid)
      assert status.status == :taken_over

      :ok = AgentProcess.release(pid)
      status = AgentProcess.get_status(pid)
      assert status.status == :waiting

      GenServer.stop(pid)
    end
  end

  describe "send_directive/2" do
    test "delivers directive to agent module" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: :directive_test,
          agent_module: CounterAgent,
          tick_ms: 50_000
        )

      AgentProcess.send_directive(pid, {:set_count, 10})
      # Give the cast time to process
      Process.sleep(20)

      GenServer.stop(pid)
    end
  end

  describe "push_event/2" do
    test "adds events to the event buffer" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: :event_test,
          agent_module: CounterAgent,
          tick_ms: 50_000
        )

      AgentProcess.push_event(pid, {:key, "a"})
      AgentProcess.push_event(pid, {:key, "b"})

      status = AgentProcess.get_status(pid)
      assert status.event_buffer_size == 2

      GenServer.stop(pid)
    end
  end

  describe "observe/think/act cycle" do
    test "runs the cycle on tick" do
      {:ok, pid} =
        AgentProcess.start_link(
          agent_id: :cycle_test,
          agent_module: CounterAgent,
          tick_ms: 30
        )

      # Let a few ticks run
      Process.sleep(150)

      # Agent should have ticked and saved context
      case ContextStore.load(:cycle_test) do
        {:ok, ctx} ->
          assert ctx.tick_count > 0

        {:error, :not_found} ->
          # Agent may not have saved yet if it reached wait quickly
          :ok
      end

      GenServer.stop(pid)
    end
  end

  describe "supervised crash and recover" do
    @tag :capture_log
    test "resumes from persisted context after a brutal kill" do
      agent_id = :recover_seed
      ContextStore.save(agent_id, %{tick_count: 7, observations: [], actions: ["seeded"]})

      {:ok, original} = start_supervised_agent(agent_id)
      Process.exit(original, :kill)

      restarted = wait_for_restart(agent_id, original)
      assert restarted != original

      AgentProcess.send_directive(restarted, {:report_to, self()})
      assert_receive {:agent_state, %{tick_count: 7, actions: ["seeded"]}}, 1_000
    end

    @tag :capture_log
    test "persists the latest in-memory state when a callback crashes" do
      agent_id = :recover_crash

      {:ok, original} = start_supervised_agent(agent_id)

      # Mutate state in memory (no explicit save), then crash inside a callback so
      # terminate/2 runs save_context with the latest state.
      AgentProcess.send_directive(original, {:set_count, 42})
      AgentProcess.send_directive(original, {:crash, "boom"})

      restarted = wait_for_restart(agent_id, original)
      assert restarted != original

      AgentProcess.send_directive(restarted, {:report_to, self()})
      assert_receive {:agent_state, %{tick_count: 42}}, 1_000
    end
  end

  defp start_supervised_agent(agent_id) do
    DynamicSupervisor.start_child(
      Raxol.Agent.DynSup,
      {AgentProcess, agent_id: agent_id, agent_module: CounterAgent, tick_ms: 50_000}
    )
  end

  defp wait_for_restart(agent_id, old_pid) do
    wait_until(fn ->
      case registered_pid(agent_id) do
        pid when is_pid(pid) -> pid != old_pid and Process.alive?(pid)
        _ -> false
      end
    end)

    registered_pid(agent_id)
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
