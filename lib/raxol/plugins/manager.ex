defmodule Raxol.Plugins.Manager do
  @moduledoc """
  Plugin manager for Raxol.
  Handles plugin lifecycle, registration, and state management.
  """


  alias Raxol.Plugins.{
    Plugin,
    PluginConfig
  }

  @type t :: %__MODULE__{
          plugins: %{String.t() => Plugin.t()},
          plugin_states: %{String.t() => any()},
          plugin_config: PluginConfig.t(),
          metadata: map(),
          event_handler: function() | nil,
          api_version: String.t(),
          loaded_plugins: %{String.t() => Plugin.t()},
          config: map(),
          load_order: [String.t()]
        }

  defstruct [
    :plugins,
    :plugin_states,
    :plugin_config,
    :metadata,
    :event_handler,
    api_version: "1.0",
    loaded_plugins: %{},
    config: %{},
    load_order: []
  ]

  @doc """
  Creates a new plugin manager with default configuration.
  """
  def new(_opts \\ []) do
    plugin_config = Raxol.Plugins.PluginConfig.new()

    manager = %__MODULE__{
      plugins: %{},
      plugin_states: %{},
      plugin_config: plugin_config,
      metadata: %{},
      event_handler: nil,
      api_version: "1.0",
      loaded_plugins: %{},
      config: plugin_config
    }

    {:ok, manager}
  end

  @doc """
  Gets a list of all loaded plugins.
  """
  def list_plugins(%__MODULE__{} = manager) do
    Map.values(manager.plugins)
  end

  @doc """
  Gets a plugin by name.
  """
  def get_plugin(%__MODULE__{} = manager, name) when is_binary(name) do
    plugin_key = normalize_plugin_key(name)
    Map.get(manager.plugins, plugin_key)
  end

  @doc """
  Gets a plugin's state by name.
  """
  def get_plugin_state(%__MODULE__{} = manager, name) when is_binary(name) do
    plugin_key = normalize_plugin_key(name)
    Map.get(manager.plugin_states, plugin_key)
  end

  @doc """
  Sets a plugin's state by name.
  """
  def set_plugin_state(%__MODULE__{} = manager, name, state)
      when is_binary(name) do
    plugin_key = normalize_plugin_key(name)

    %{
      manager
      | plugin_states: Map.put(manager.plugin_states, plugin_key, state)
    }
  end

  @doc """
  Updates a plugin's state using a function.
  """
  def update_plugin_state(%__MODULE__{} = manager, name, update_fun)
      when is_binary(name) and is_function(update_fun, 1) do
    plugin_key = normalize_plugin_key(name)
    current_state = Map.get(manager.plugin_states, plugin_key, %{})
    new_state = update_fun.(current_state)

    %{
      manager
      | plugin_states: Map.put(manager.plugin_states, plugin_key, new_state)
    }
  end

  @doc """
  Gets the current API version of the plugin manager.
  """
  def get_api_version(%__MODULE__{} = manager) do
    manager.api_version
  end

  @doc """
  Returns a map of loaded plugin names to plugin structs (for test compatibility).
  """
  def loaded_plugins(%__MODULE__{} = manager) do
    manager.loaded_plugins
  end

  @doc """
  Updates the plugins map in the manager and keeps loaded_plugins in sync.
  """
  def update_plugins(%__MODULE__{} = manager, plugins) when is_map(plugins) do
    %{manager | plugins: plugins, loaded_plugins: plugins}
  end

  @doc """
  Updates the configuration in the manager.
  """
  def update_config(%__MODULE__{} = manager, config) do
    %{manager | config: config}
  end

  @doc """
  Loads a plugin module and initializes it. Delegates to Raxol.Plugins.Lifecycle.load_plugin/3.
  """
  def load_plugin(%__MODULE__{} = manager, module) when is_atom(module) do
    Raxol.Plugins.Lifecycle.load_plugin(manager, module)
  end

  @doc """
  Loads a plugin module with specific configuration and initializes it.
  Delegates to Raxol.Plugins.Lifecycle.load_plugin/3.
  """
  def load_plugin(%__MODULE__{} = manager, module, config)
      when is_atom(module) and is_map(config) do
    Raxol.Plugins.Lifecycle.load_plugin(manager, module, config)
  end

  @doc """
  Unloads a plugin by name and cleans up its resources.
  Delegates to Raxol.Plugins.Lifecycle.unload_plugin/2.
  """
  def unload_plugin(%__MODULE__{} = manager, plugin_name)
      when is_binary(plugin_name) do
    Raxol.Plugins.Lifecycle.unload_plugin(manager, plugin_name)
  end

  @doc """
  Enables a plugin by name.
  Delegates to Raxol.Plugins.Lifecycle.enable_plugin/2.
  """
  def enable_plugin(%__MODULE__{} = manager, plugin_name)
      when is_binary(plugin_name) do
    Raxol.Plugins.Lifecycle.enable_plugin(manager, plugin_name)
  end

  @doc """
  Disables a plugin by name.
  Delegates to Raxol.Plugins.Lifecycle.disable_plugin/2.
  """
  def disable_plugin(%__MODULE__{} = manager, plugin_name)
      when is_binary(plugin_name) do
    Raxol.Plugins.Lifecycle.disable_plugin(manager, plugin_name)
  end

  @doc """
  Loads multiple plugins in the correct dependency order.
  Delegates to Raxol.Plugins.Lifecycle.load_plugins/2.
  """
  def load_plugins(%__MODULE__{} = manager, modules) when is_list(modules) do
    Raxol.Plugins.Lifecycle.load_plugins(manager, modules)
  end

  # Helper to normalize plugin keys to strings
  defp normalize_plugin_key(key) when is_binary(key), do: key
end
