defmodule Raxol.Core.Runtime.Plugins.PluginManager do
  @moduledoc """
  Facade for plugin management operations.

  This module provides a unified API that delegates to specialized modules:
  - `PluginRegistry` - Fast ETS-backed lookups (no process serialization)
  - `PluginLifecycle` - GenServer for coordination (load, enable, state)

  ## Architecture

  Following Rich Hickey's principle of separating data from coordination:

  ```
  PluginManager (Facade)
       |
       +-- PluginRegistry (Pure + ETS)
       |   - Plugin registration
       |   - Metadata storage
       |   - Command lookups
       |   - Fast concurrent reads
       |
       +-- PluginLifecycle (GenServer)
           - Load/unload coordination
           - Enable/disable state
           - Runtime plugin state
           - File watching/hot reload
  ```

  ## Migration Note

  This module maintains backward compatibility with the old API.
  New code should use:
  - `PluginRegistry` for lookups (faster, no process call)
  - `PluginLifecycle` for lifecycle operations

  ## Usage

      # Load a plugin
      PluginManager.load_plugin_by_module(MyPlugin, %{config: "value"})

      # List plugins (fast ETS lookup)
      PluginManager.list_plugins()

      # Enable/disable
      PluginManager.enable_plugin(:my_plugin)
      PluginManager.disable_plugin(:my_plugin)
  """

  alias Raxol.Core.Runtime.Log

  alias Raxol.Core.Runtime.Plugins.{
    PluginLifecycle,
    PluginRegistry,
    PluginRuntime
  }

  @type plugin_id :: atom() | String.t()
  @type plugin_metadata :: map()
  @type plugin_state :: map()

  # ============================================================================
  # Startup
  # ============================================================================

  @doc """
  Starts the plugin management system.

  Initializes both the registry and lifecycle manager.
  """
  def start_link(opts \\ []) do
    # Ensure registry is initialized
    PluginRegistry.init()

    # Start lifecycle manager
    PluginLifecycle.start_link(opts)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  # ============================================================================
  # Plugin Loading (Delegates to Lifecycle)
  # ============================================================================

  @doc """
  Loads a plugin by module with optional configuration.
  """
  def load_plugin_by_module(module, config \\ %{}) do
    plugin_id = module_to_id(module)
    PluginLifecycle.load(plugin_id, module, config)
  end

  @doc """
  Loads a plugin by ID.
  """
  def load_plugin(plugin_id) do
    # For backward compatibility - tries to load if module exists
    module = id_to_module(plugin_id)

    if Code.ensure_loaded?(module) do
      PluginLifecycle.load(plugin_id, module, %{})
    else
      {:error, :module_not_found}
    end
  end

  @doc """
  Loads a plugin with config (legacy signature).
  """
  def load_plugin(plugin_id, config) do
    module = id_to_module(plugin_id)

    if Code.ensure_loaded?(module) do
      PluginLifecycle.load(plugin_id, module, config)
    else
      {:error, :module_not_found}
    end
  end

  @doc """
  Unloads a plugin.
  """
  def unload_plugin(plugin_id) do
    PluginLifecycle.unload(plugin_id)
  end

  @doc """
  Unloads a plugin (legacy signature with pid).
  """
  def unload_plugin(_pid, plugin_id) do
    unload_plugin(plugin_id)
  end

  @doc """
  Reloads a plugin.
  """
  def reload_plugin(plugin_id) do
    PluginLifecycle.reload(plugin_id)
  end

  # ============================================================================
  # Enable/Disable (Delegates to Lifecycle)
  # ============================================================================

  @doc """
  Enables a plugin.
  """
  def enable_plugin(plugin_id) do
    PluginLifecycle.enable(plugin_id)
  end

  @doc """
  Disables a plugin.
  """
  def disable_plugin(plugin_id) do
    PluginLifecycle.disable(plugin_id)
  end

  # ============================================================================
  # Lookups (Delegates to Registry - Fast ETS reads)
  # ============================================================================

  @doc """
  Lists all registered plugins.

  This is a fast ETS lookup - no GenServer call required.
  """
  def list_plugins do
    PluginRegistry.list()
    |> Enum.map(&plugin_entry_to_legacy/1)
  end

  @doc """
  Gets a plugin by ID.

  Fast ETS lookup.
  """
  def get_plugin(plugin_id) do
    case PluginRegistry.get(plugin_id) do
      {:ok, entry} -> plugin_entry_to_legacy(entry)
      :error -> nil
    end
  end

  @doc """
  Checks if a plugin is loaded.
  """
  def plugin_loaded?(plugin_id) do
    PluginRegistry.registered?(plugin_id)
  end

  @doc """
  Checks if a plugin is loaded (legacy signature with pid).
  """
  def plugin_loaded?(_pid, plugin_id) do
    plugin_loaded?(plugin_id)
  end

  @doc """
  Gets list of loaded plugin IDs.
  """
  def get_loaded_plugins do
    PluginRegistry.list(ids_only: true)
  end

  @doc """
  Gets list of loaded plugin IDs (legacy signature with pid).
  """
  def get_loaded_plugins(_pid) do
    get_loaded_plugins()
  end

  # ============================================================================
  # State Management (Delegates to Lifecycle)
  # ============================================================================

  @doc """
  Gets the runtime state of a plugin.
  """
  def get_plugin_state(plugin_id) do
    case PluginLifecycle.get_state(plugin_id) do
      {:ok, state} -> state
      {:error, _} -> nil
    end
  end

  @doc """
  Sets the runtime state of a plugin.
  """
  def set_plugin_state(plugin_id, state) do
    PluginLifecycle.set_state(plugin_id, state)
  end

  @doc """
  Gets plugin configuration.
  """
  def get_plugin_config(plugin_id) do
    PluginLifecycle.get_config(plugin_id)
  end

  @doc """
  Gets plugin configuration (legacy signature with pid).
  """
  def get_plugin_config(_pid, plugin_id) do
    get_plugin_config(plugin_id)
  end

  @doc """
  Updates plugin configuration.
  """
  def update_plugin_config(plugin_id, config) do
    PluginLifecycle.update_config(plugin_id, config)
  end

  @doc """
  Updates plugin configuration (legacy signature with pid).
  """
  def update_plugin_config(_pid, plugin_id, config) do
    update_plugin_config(plugin_id, config)
  end

  # ============================================================================
  # Initialization (Backward Compatibility)
  # ============================================================================

  @doc """
  Initializes the plugin manager.
  """
  def initialize do
    PluginRegistry.init()
    :ok
  end

  @doc """
  Initializes with configuration.
  """
  def initialize_with_config(_config) do
    PluginRegistry.init()
    :ok
  end

  @doc """
  Initializes a specific plugin.
  """
  def initialize_plugin(plugin_id, config) do
    PluginLifecycle.update_config(plugin_id, config)
  end

  @doc """
  Initializes a specific plugin (legacy signature with pid).
  """
  def initialize_plugin(_pid, plugin_id, config) do
    initialize_plugin(plugin_id, config)
  end

  # ============================================================================
  # Plugin Updates
  # ============================================================================

  @doc """
  Updates a plugin entry using a function.
  """
  def update_plugin(plugin_id, update_fun) when is_function(update_fun, 1) do
    case PluginRegistry.get(plugin_id) do
      {:ok, entry} ->
        updated = update_fun.(plugin_entry_to_legacy(entry))
        PluginRegistry.update_metadata(plugin_id, updated)

      :error ->
        {:error, :plugin_not_found}
    end
  end

  # ============================================================================
  # Hook Calling
  # ============================================================================

  @doc """
  Calls a hook on a plugin.
  """
  def call_hook(plugin_id, hook_name, args) do
    case PluginRuntime.call_hook(plugin_id, hook_name, args) do
      {:error, :not_found} -> {:error, :plugin_not_found}
      :not_exported -> {:error, :hook_not_found}
      result -> result
    end
  end

  @doc """
  Calls a hook on a plugin (legacy signature with pid).
  """
  def call_hook(_pid, plugin_id, hook_name, args) do
    call_hook(plugin_id, hook_name, args)
  end

  # ============================================================================
  # Validation
  # ============================================================================

  @doc """
  Validates plugin configuration.
  """
  def validate_plugin_config(_plugin_id, config) do
    if is_map(config) do
      {:ok, config}
    else
      {:error, :invalid_config}
    end
  end

  # ============================================================================
  # Legacy Compatibility
  # ============================================================================

  @doc false
  def stop(pid \\ __MODULE__) do
    GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  @doc false
  def handle_error(error, context) do
    Log.error("Plugin error", error: error, context: context)
    {:error, error}
  end

  @doc false
  def handle_cleanup(_context), do: :ok

  @doc false
  def handle_event(state, _event), do: state

  @doc false
  def get_commands(_state), do: %{}

  @doc false
  def get_metadata(_state), do: %{}

  @doc false
  def handle_command(_state, _command, _args), do: {:error, :not_implemented}

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp module_to_id(module) when is_atom(module) do
    module
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.to_atom()
  end

  defp id_to_module(plugin_id) when is_atom(plugin_id) do
    # Try to find module by convention
    name =
      plugin_id
      |> Atom.to_string()
      |> Macro.camelize()

    Module.concat([Raxol, Plugins, name])
  end

  defp id_to_module(plugin_id) when is_binary(plugin_id) do
    plugin_id
    |> String.to_atom()
    |> id_to_module()
  end

  defp plugin_entry_to_legacy(entry) do
    %{
      id: entry.id,
      module: entry.module,
      metadata: entry.metadata,
      enabled: PluginLifecycle.get_status(entry.id) == :enabled
    }
  end
end
