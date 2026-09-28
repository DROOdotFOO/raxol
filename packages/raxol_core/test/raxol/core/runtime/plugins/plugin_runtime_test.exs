defmodule Raxol.Core.Runtime.Plugins.PluginRuntimeTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Plugins.{
    PluginInstanceSupervisor,
    PluginLifecycle,
    PluginManager,
    PluginRuntime,
    PluginSupervisor
  }

  defmodule StatefulPlugin do
    def init(config) do
      send(config.test_pid, {:initialized, self()})
      {:ok, %{count: 0, test_pid: config.test_pid}}
    end

    def handle_event(:increment, state) do
      send(state.test_pid, {:handled, self()})
      {:ok, %{state | count: state.count + 1}}
    end

    def handle_event(:arm_timer, state) do
      Process.send_after(self(), :timer_fired, 0)
      {:ok, state}
    end

    def handle_event(:timer_fired, state) do
      send(state.test_pid, {:timer_handled, self()})
      {:ok, %{state | count: state.count + 1}}
    end

    def filter_event(event, state) do
      send(state.test_pid, {:filtered, self()})
      {:ok, Map.put(event, :filtered, true)}
    end

    def custom_hook(value) do
      send(value, {:hook_called, self()})
      :hook_result
    end

    def handle_command(:add, [amount], state) do
      new_state = %{state | count: state.count + amount}
      send(state.test_pid, {:command_handled, self()})
      {:ok, new_state, new_state.count}
    end

    def state_first(state, amount) do
      send(state.test_pid, {:state_first, self()})
      {:ok, %{state | count: state.count + amount}, :updated}
    end

    def state_last(amount, state) do
      send(state.test_pid, {:state_last, self()})
      {:cont, %{state | count: state.count + amount}}
    end

    def crashing_callback(_state), do: raise("callback failed")
  end

  defmodule BlockingPlugin do
    def init(config), do: {:ok, config}

    def handle_event(:block, state) do
      send(state.test_pid, {:blocked, self()})

      receive do
        :release -> {:ok, state}
      end
    end
  end

  setup do
    start_supervised!(PluginSupervisor)
    start_supervised!(PluginLifecycle)
    :ok
  end

  test "a loaded plugin initializes and handles events on one stable runtime process" do
    assert :ok =
             PluginLifecycle.load(:stateful, StatefulPlugin, %{test_pid: self()})

    assert_receive {:initialized, runtime_pid}

    assert {:ok, %{count: 1}} =
             PluginRuntime.handle_event(:stateful, :increment)

    assert_receive {:handled, ^runtime_pid}
    assert Process.alive?(runtime_pid)
  end

  test "state, filters, hooks, and timer messages stay on the runtime process" do
    assert :ok =
             PluginLifecycle.load(:stateful, StatefulPlugin, %{test_pid: self()})

    assert_receive {:initialized, runtime_pid}

    assert :ok =
             PluginLifecycle.set_state(:stateful, %{count: 4, test_pid: self()})

    assert {:ok, %{count: 4}} = PluginLifecycle.get_state(:stateful)

    assert {:ok, %{filtered: true}} = PluginLifecycle.filter_event(%{})
    assert_receive {:filtered, ^runtime_pid}

    assert {:ok, :hook_result} =
             PluginManager.call_hook(:stateful, :custom_hook, [self()])

    assert_receive {:hook_called, ^runtime_pid}

    assert {:ok, _state} = PluginLifecycle.handle_event(:stateful, :arm_timer)
    assert_receive {:timer_handled, ^runtime_pid}
    assert {:ok, %{count: 5}} = PluginLifecycle.get_state(:stateful)

    assert {:ok, %{count: 8}, 8} =
             PluginLifecycle.handle_command(:stateful, :add, [3])

    assert_receive {:command_handled, ^runtime_pid}
  end

  test "generic stateful callbacks execute serially without losing runtime state" do
    assert :ok =
             PluginLifecycle.load(:stateful, StatefulPlugin, %{test_pid: self()})

    assert_receive {:initialized, runtime_pid}

    assert {:ok, %{count: 2}, :updated} =
             PluginRuntime.invoke(:stateful, :state_first, [2], :first)

    assert_receive {:state_first, ^runtime_pid}

    assert {:cont, %{count: 5}} =
             PluginRuntime.invoke(:stateful, :state_last, [3], :last)

    assert_receive {:state_last, ^runtime_pid}
    assert {:ok, %{count: 5}} = PluginLifecycle.get_state(:stateful)

    assert {:error, {:crashed, %RuntimeError{message: "callback failed"}}} =
             PluginRuntime.invoke(:stateful, :crashing_callback)

    assert Process.alive?(runtime_pid)
    assert {:ok, %{count: 5}} = PluginLifecycle.get_state(:stateful)
  end

  test "unload stops the runtime and reload creates a new runtime process" do
    assert :ok =
             PluginLifecycle.load(:stateful, StatefulPlugin, %{test_pid: self()})

    assert_receive {:initialized, first_pid}
    monitor = Process.monitor(first_pid)

    assert :ok = PluginLifecycle.unload(:stateful)
    assert_receive {:DOWN, ^monitor, :process, ^first_pid, _reason}
    assert {:error, :not_found} = PluginLifecycle.get_state(:stateful)

    assert :ok =
             PluginLifecycle.load(:stateful, StatefulPlugin, %{test_pid: self()})

    assert_receive {:initialized, second_pid}
    refute second_pid == first_pid

    assert :ok = PluginLifecycle.reload(:stateful)
    assert_receive {:initialized, third_pid}
    refute third_pid == second_pid
  end

  test "a blocked plugin does not block lifecycle operations or another plugin" do
    assert :ok =
             PluginLifecycle.load(:blocked, BlockingPlugin, %{test_pid: self()})

    blocked_pid = PluginInstanceSupervisor.runtime_pid(:blocked)

    task = Task.async(fn -> PluginLifecycle.handle_event(:blocked, :block) end)
    assert_receive {:blocked, ^blocked_pid}

    assert :loaded = PluginLifecycle.get_status(:blocked)

    assert :ok =
             PluginLifecycle.load(:stateful, StatefulPlugin, %{test_pid: self()})

    assert_receive {:initialized, other_pid}

    assert {:ok, %{count: 1}} =
             PluginLifecycle.handle_event(:stateful, :increment)

    assert_receive {:handled, ^other_pid}

    send(blocked_pid, :release)
    assert {:ok, _state} = Task.await(task)
  end
end
