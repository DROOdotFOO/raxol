defmodule Raxol.Plugins.StableRuntimeTracerTest do
  use ExUnit.Case, async: false

  alias Raxol.Plugins.{EventHandler, Manager}
  alias Raxol.Core.Runtime.Plugins.{PluginLifecycle, PluginSupervisor}

  defmodule TracerPlugin do
    @behaviour Raxol.Plugins.Plugin

    def init(%{test_pid: test_pid}) do
      send(test_pid, {:callback, :init, self()})
      {:ok, %{test_pid: test_pid, ticks: 0}}
    end

    def get_api_version, do: "1.0"
    def get_dependencies, do: []

    def get_metadata do
      %{name: "stable_runtime_tracer", version: "1.0.0", dependencies: []}
    end

    def handle_input(state, "schedule") do
      send(state.test_pid, {:callback, :input, self()})
      Process.send_after(self(), :tick, 0)
      {:ok, state}
    end

    def handle_input(state, _input), do: {:ok, state}

    def handle_command(:increment, [amount], state) do
      send(state.test_pid, {:callback, :command, self()})
      state = %{state | ticks: state.ticks + amount}
      {:ok, state, state.ticks}
    end

    def handle_event(:tick, state) do
      send(state.test_pid, {:callback, :timer, self()})
      {:ok, %{state | ticks: state.ticks + 1}}
    end

    def cleanup(state) do
      send(state.test_pid, {:callback, :cleanup, self()})
      :ok
    end
  end

  setup do
    start_supervised!(PluginSupervisor)
    start_supervised!(PluginLifecycle)
    :ok
  end

  test "root plugin callbacks and timers share one stable runtime" do
    {:ok, manager} = Manager.new()
    config = %{test_pid: self()}

    assert {:ok, manager} = Manager.load_plugin(manager, TracerPlugin, config)
    assert_receive {:callback, :init, runtime_pid}
    assert runtime_pid != self()

    assert {:ok, manager} = EventHandler.handle_input(manager, "schedule")
    assert_receive {:callback, :input, ^runtime_pid}
    assert_receive {:callback, :timer, ^runtime_pid}

    assert {:ok, manager, 2} =
             Manager.handle_command(
               manager,
               "stable_runtime_tracer",
               :increment,
               [1]
             )

    assert_receive {:callback, :command, ^runtime_pid}

    assert %{ticks: 2} =
             Manager.get_plugin_state(manager, "stable_runtime_tracer")

    assert {:ok, manager} =
             Manager.unload_plugin(manager, "stable_runtime_tracer")

    assert_receive {:callback, :cleanup, ^runtime_pid}
    refute Process.alive?(runtime_pid)

    assert {:ok, manager} = Manager.load_plugin(manager, TracerPlugin, config)
    assert_receive {:callback, :init, reloaded_pid}
    refute reloaded_pid == runtime_pid

    assert {:ok, _manager} =
             Manager.unload_plugin(manager, "stable_runtime_tracer")
  end
end
