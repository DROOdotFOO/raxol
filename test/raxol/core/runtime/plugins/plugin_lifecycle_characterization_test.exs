defmodule Raxol.Core.Runtime.Plugins.PluginLifecycleCharacterizationTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Plugins.{
    PluginLifecycle,
    PluginRegistry,
    PluginSupervisor
  }

  defmodule CharacterizedPlugin do
    def init(config), do: {:ok, %{config: config, value: 1}}

    def on_load do
      send(
        Process.whereis(:plugin_lifecycle_characterization),
        {:hook, :load, self()}
      )

      :ok
    end

    def on_enable do
      send(
        Process.whereis(:plugin_lifecycle_characterization),
        {:hook, :enable, self()}
      )

      :ok
    end

    def on_disable do
      send(
        Process.whereis(:plugin_lifecycle_characterization),
        {:hook, :disable, self()}
      )

      :ok
    end

    def on_unload do
      send(
        Process.whereis(:plugin_lifecycle_characterization),
        {:hook, :unload, self()}
      )

      :ok
    end
  end

  setup do
    Process.register(self(), :plugin_lifecycle_characterization)
    start_supervised!(PluginSupervisor)
    start_supervised!(PluginLifecycle)
    :ok
  end

  test "load, state access, hooks, status changes, and unload retain their public behavior" do
    plugin_id = :characterized_plugin
    config = %{mode: :test}

    assert :ok = PluginLifecycle.load(plugin_id, CharacterizedPlugin, config)
    assert_receive {:hook, :load, load_hook_pid}
    assert load_hook_pid != self()

    assert {:ok, %{config: ^config, value: 1}} =
             PluginLifecycle.get_state(plugin_id)

    assert PluginLifecycle.get_config(plugin_id) == config
    assert PluginLifecycle.get_status(plugin_id) == :loaded
    assert PluginRegistry.registered?(plugin_id)

    assert :ok = PluginLifecycle.set_state(plugin_id, %{value: 2})
    assert {:ok, %{value: 2}} = PluginLifecycle.get_state(plugin_id)

    assert :ok = PluginLifecycle.enable(plugin_id)
    assert_receive {:hook, :enable, enable_hook_pid}
    assert enable_hook_pid != self()
    assert PluginLifecycle.get_status(plugin_id) == :enabled

    assert :ok = PluginLifecycle.disable(plugin_id)
    assert_receive {:hook, :disable, disable_hook_pid}
    assert disable_hook_pid != self()
    assert PluginLifecycle.get_status(plugin_id) == :disabled

    assert :ok = PluginLifecycle.unload(plugin_id)
    assert_receive {:hook, :unload, unload_hook_pid}
    assert unload_hook_pid != self()
    assert {:error, :not_found} = PluginLifecycle.get_state(plugin_id)
    refute PluginRegistry.registered?(plugin_id)
  end
end
