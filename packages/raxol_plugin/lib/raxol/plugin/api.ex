defmodule Raxol.Plugin.API do
  @moduledoc """
  Public API facade for plugin management operations.

  Delegates to `Raxol.Core.Runtime.Plugins.PluginManager` with
  graceful error handling when the manager process is not running.

  ## Usage

      Raxol.Plugin.API.load(MyPlugin, %{option: "value"})
      Raxol.Plugin.API.enable(:my_plugin)
      Raxol.Plugin.API.list()
  """

  @compile {:no_warn_undefined,
            [
              Raxol.Core.Runtime.Plugins.PluginManager,
              Raxol.Core.Runtime.Plugins.PluginLifecycle
            ]}

  @type plugin_id :: atom() | String.t()

  @doc """
  Loads a plugin module with optional configuration.
  """
  @spec load(module(), map()) :: :ok | {:error, term()}
  def load(module, config \\ %{}) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.load_plugin_by_module(module, config) end)
  end

  @doc """
  Unloads a plugin by ID.
  """
  @spec unload(plugin_id()) :: :ok | {:error, term()}
  def unload(plugin_id) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.unload_plugin(plugin_id) end)
  end

  @doc """
  Enables a loaded plugin.
  """
  @spec enable(plugin_id()) :: :ok | {:error, term()}
  def enable(plugin_id) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.enable_plugin(plugin_id) end)
  end

  @doc """
  Disables a plugin without unloading it.
  """
  @spec disable(plugin_id()) :: :ok | {:error, term()}
  def disable(plugin_id) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.disable_plugin(plugin_id) end)
  end

  @doc """
  Lists all registered plugins.
  """
  @spec list() :: [map()] | {:error, term()}
  def list do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.list_plugins() end)
  end

  @doc """
  Gets the runtime state of a plugin.
  """
  @spec get_state(plugin_id()) :: term() | {:error, term()}
  def get_state(plugin_id) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.get_plugin_state(plugin_id) end)
  end

  @doc """
  Reloads a plugin (unload + load).
  """
  @spec reload(plugin_id()) :: :ok | {:error, term()}
  def reload(plugin_id) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.reload_plugin(plugin_id) end)
  end

  @doc """
  Checks whether a plugin is currently loaded.
  """
  @spec loaded?(plugin_id()) :: boolean() | {:error, term()}
  def loaded?(plugin_id) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.plugin_loaded?(plugin_id) end)
  end

  @doc """
  Gets a plugin entry by ID.
  """
  @spec get(plugin_id()) :: map() | nil | {:error, term()}
  def get(plugin_id) do
    call(fn -> Raxol.Core.Runtime.Plugins.PluginManager.get_plugin(plugin_id) end)
  end

  # Wraps calls in try/catch :exit for when the PluginManager/Lifecycle
  # GenServer is not running.
  @spec call((-> result)) :: result | {:error, :plugin_manager_not_running} when result: term()
  defp call(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :plugin_manager_not_running}
  end
end
