defmodule Raxol.Agent.SupervisorTest do
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Raxol.Agent.ContextStore
  alias Raxol.Agent.Orchestrator

  defmodule SimpleAgent do
    def init(_opts), do: {:ok, %{status: :idle}}
    def observe(_events, state), do: {:ok, %{}, state}
    def think(_observation, state), do: {:wait, state}
    def act(_action, state), do: {:ok, state}
    def receive_directive(_directive, state), do: {:ok, state}
    def context_snapshot(state), do: state
    def restore_context(snapshot), do: {:ok, snapshot}
  end

  setup do
    ContextStore.init()
    start_supervised!(Raxol.Agent.Supervisor)

    on_exit(fn ->
      for id <- ContextStore.list(), do: ContextStore.delete(id)
    end)

    :ok
  end

  describe "rest_for_one supervision" do
    test "a DynSup crash restarts the Orchestrator but leaves the Registry" do
      registry = Process.whereis(Raxol.Agent.Registry)
      dynsup = Process.whereis(Raxol.Agent.DynSup)
      orch = orchestrator_pid()

      assert is_pid(registry)
      assert is_pid(dynsup)
      assert is_pid(orch)

      Process.exit(dynsup, :kill)

      wait_until(fn ->
        match?(pid when is_pid(pid) and pid != orch, orchestrator_pid())
      end)

      # The Registry precedes the DynSup in the child list, so it is untouched.
      assert Process.whereis(Raxol.Agent.Registry) == registry
      # The DynSup and everything started after it come back fresh.
      assert Process.whereis(Raxol.Agent.DynSup) != dynsup
      assert orchestrator_pid() != orch
    end

    test "a Registry crash cascades to the DynSup and Orchestrator" do
      registry = Process.whereis(Raxol.Agent.Registry)
      dynsup = Process.whereis(Raxol.Agent.DynSup)
      orch = orchestrator_pid()

      Process.exit(registry, :kill)

      wait_until(fn ->
        match?(pid when is_pid(pid) and pid != orch, orchestrator_pid())
      end)

      assert Process.whereis(Raxol.Agent.Registry) != registry
      assert Process.whereis(Raxol.Agent.DynSup) != dynsup
      assert orchestrator_pid() != orch
    end

    test "an Orchestrator crash does not take running agents down with it" do
      orch = orchestrator_pid()
      {:ok, :worker} = Orchestrator.spawn_agent(orch, :worker, SimpleAgent, tick_ms: 50_000)

      agent = registered_pid({:process, :worker})
      assert is_pid(agent)

      Process.exit(orch, :kill)

      wait_until(fn ->
        match?(pid when is_pid(pid) and pid != orch, orchestrator_pid())
      end)

      # A crash in the coordinator must not cascade to the worker it spawned.
      assert Process.alive?(agent)
      assert registered_pid({:process, :worker}) == agent
    end
  end

  defp orchestrator_pid, do: registered_pid(:orchestrator)

  defp registered_pid(key) do
    case Registry.lookup(Raxol.Agent.Registry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  rescue
    ArgumentError -> nil
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
