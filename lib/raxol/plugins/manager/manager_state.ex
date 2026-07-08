defmodule Raxol.Plugins.Manager.State do
  @moduledoc """
  Handles plugin state management and updates.
  Provides functions for updating plugin state and managing plugin lifecycle states.
  """


  alias Raxol.Plugins.Manager

  @doc """
  Updates the state of a specific plugin within the manager.
  The `update_fun` receives the current plugin state and should return the new state.
  """
  def update_plugin(%Manager{} = manager, name, update_fun)
      when is_binary(name) and is_function(update_fun, 1) do
    plugin = Map.get(manager.plugins, name)
    new_plugin_state = update_fun.(plugin)

    case is_struct(new_plugin_state, plugin.__struct__) do
      true ->
        %{manager | plugins: Map.put(manager.plugins, name, new_plugin_state)}

      false ->
        manager
    end
  end

  @doc """
  Enables a plugin by name.
  Delegates to `Raxol.Plugins.Lifecycle.enable_plugin/2`.
  """
  def enable_plugin(%Manager{} = manager, name) when is_binary(name) do
    update_plugin(manager, name, &Map.put(&1, :enabled, true))
  end

  @doc """
  Disables a plugin by name.
  Delegates to `Raxol.Plugins.Lifecycle.disable_plugin/2`.
  """
  def disable_plugin(%Manager{} = manager, name) when is_binary(name) do
    update_plugin(manager, name, &Map.put(&1, :enabled, false))
  end

  @doc """
  Loads a plugin module and initializes it with the given configuration.
  Delegates to `Raxol.Plugins.Lifecycle.load_plugin/3`.
  """
  def load_plugin(%Manager{} = manager, module, config \\ %{})
      when is_atom(module) do
    Raxol.Plugins.Lifecycle.load_plugin(manager, module, config)
  end

  @doc """
  Loads multiple plugins in the correct dependency order.
  Delegates to `Raxol.Plugins.Lifecycle.load_plugins/2`.
  """
  def load_plugins(%Manager{} = manager, modules) when is_list(modules) do
    case Raxol.Plugins.Lifecycle.load_plugins(manager, modules) do
      {:ok, updated_manager} -> {:ok, updated_manager}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Unloads a plugin by name.
  Delegates to `Raxol.Plugins.Lifecycle.unload_plugin/2`.
  """
  def unload_plugin(%Manager{} = manager, name) when is_binary(name) do
    %{manager | plugins: Map.delete(manager.plugins, name)}
  end
end
