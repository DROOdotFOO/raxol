defmodule Raxol.Core.Runtime.Plugins.PluginLifecycle do
  @moduledoc """
  GenServer for plugin lifecycle coordination.

  Handles stateful plugin operations that require coordination:
  - Loading and unloading plugins
  - Enabling and disabling plugins
  - Managing plugin runtime state
  - File watching for hot reload
  - Timer-based operations

  ## Design

  This module is the "coordination layer" - it's a GenServer because it needs to:
  - Coordinate concurrent plugin operations
  - Manage timers for debounced reloads
  - Track per-plugin runtime state

  Read-only operations should use `PluginRegistry` directly for better performance.

  ## Usage

      # Start lifecycle manager
      {:ok, _pid} = PluginLifecycle.start_link([])

      # Load a plugin
      PluginLifecycle.load(:my_plugin, MyPlugin, %{config: "value"})

      # Enable/disable
      PluginLifecycle.enable(:my_plugin)
      PluginLifecycle.disable(:my_plugin)

      # Get runtime state
      PluginLifecycle.get_state(:my_plugin)
  """

  use GenServer

  alias Raxol.Core.Runtime.Log
  alias Raxol.Core.Runtime.Plugins.PluginRegistry
  alias Raxol.Core.Runtime.Plugins.PluginSupervisor
  alias Raxol.Core.Runtime.Plugins.StateManager, as: PluginStateManager
  alias Raxol.Core.Utils.Debounce

  @type plugin_id :: atom() | String.t()
  @type plugin_status :: :loaded | :enabled | :disabled | :error
  @type plugin_state :: term()

  defstruct [
    :runtime_pid,
    # plugin_states removed - now managed by PluginStateManager (ETS-backed)
    plugin_configs: %{},
    plugin_status: %{},
    initialized: false,
    debounce: nil,
    file_watcher_pid: nil,
    file_watching_enabled: false,
    plugin_dirs: []
  ]

  # ============================================================================
  # Client API
  # ============================================================================

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Loads a plugin module with optional configuration.

  Registers in PluginRegistry and initializes lifecycle state.
  """
  @spec load(plugin_id(), module(), map()) :: :ok | {:error, term()}
  def load(plugin_id, module, config \\ %{}) do
    GenServer.call(__MODULE__, {:load, plugin_id, module, config})
  end

  @doc """
  Unloads a plugin, cleaning up state and unregistering.
  """
  @spec unload(plugin_id()) :: :ok | {:error, term()}
  def unload(plugin_id) do
    GenServer.call(__MODULE__, {:unload, plugin_id})
  end

  @doc """
  Enables a loaded plugin.
  """
  @spec enable(plugin_id()) :: :ok | {:error, term()}
  def enable(plugin_id) do
    GenServer.call(__MODULE__, {:enable, plugin_id})
  end

  @doc """
  Disables a plugin without unloading it.
  """
  @spec disable(plugin_id()) :: :ok | {:error, term()}
  def disable(plugin_id) do
    GenServer.call(__MODULE__, {:disable, plugin_id})
  end

  @doc """
  Reloads a plugin (unload + load).
  """
  @spec reload(plugin_id()) :: :ok | {:error, term()}
  def reload(plugin_id) do
    GenServer.call(__MODULE__, {:reload, plugin_id})
  end

  @doc """
  Gets the runtime state of a plugin.
  """
  @spec get_state(plugin_id()) :: {:ok, plugin_state()} | {:error, :not_found}
  def get_state(plugin_id) do
    GenServer.call(__MODULE__, {:get_state, plugin_id})
  end

  @doc """
  Updates the runtime state of a plugin.
  """
  @spec set_state(plugin_id(), plugin_state()) :: :ok | {:error, :not_found}
  def set_state(plugin_id, state) do
    GenServer.call(__MODULE__, {:set_state, plugin_id, state})
  end

  @doc """
  Gets the configuration of a plugin.
  """
  @spec get_config(plugin_id()) :: map()
  def get_config(plugin_id) do
    GenServer.call(__MODULE__, {:get_config, plugin_id})
  end

  @doc """
  Updates plugin configuration.
  """
  @spec update_config(plugin_id(), map()) :: :ok
  def update_config(plugin_id, config) do
    GenServer.cast(__MODULE__, {:update_config, plugin_id, config})
  end

  @doc """
  Gets the status of a plugin.
  """
  @spec get_status(plugin_id()) :: plugin_status() | nil
  def get_status(plugin_id) do
    GenServer.call(__MODULE__, {:get_status, plugin_id})
  end

  @doc """
  Lists all plugins with their status.
  """
  @spec list_with_status() :: [{plugin_id(), plugin_status()}]
  def list_with_status do
    GenServer.call(__MODULE__, :list_with_status)
  end

  @doc """
  Schedules a debounced reload for a plugin.

  Useful for file-watching scenarios where multiple changes
  should trigger only one reload.
  """
  @spec schedule_reload(plugin_id(), non_neg_integer()) :: :ok
  def schedule_reload(plugin_id, delay_ms \\ 500) do
    GenServer.cast(__MODULE__, {:schedule_reload, plugin_id, delay_ms})
  end

  @doc """
  Enables file watching for plugin hot reload.
  """
  @spec enable_file_watching(list(String.t())) :: :ok
  def enable_file_watching(dirs) do
    GenServer.cast(__MODULE__, {:enable_file_watching, dirs})
  end

  @doc """
  Disables file watching.
  """
  @spec disable_file_watching() :: :ok
  def disable_file_watching do
    GenServer.cast(__MODULE__, :disable_file_watching)
  end

  # ============================================================================
  # GenServer Implementation
  # ============================================================================

  @impl GenServer
  def init(opts) do
    # Ensure registry is initialized
    PluginRegistry.init()

    state = %__MODULE__{
      runtime_pid: Keyword.get(opts, :runtime_pid),
      plugin_dirs: Keyword.get(opts, :plugin_dirs, []),
      file_watching_enabled: Keyword.get(opts, :enable_file_watching, false),
      debounce: Debounce.new(),
      initialized: true
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:load, plugin_id, module, config}, _from, state) do
    id = normalize_id(plugin_id)

    case do_load_plugin(id, module, config, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:filter_event, event}, _from, state) do
    # No plugins loaded means no filtering; otherwise the loaded plugins'
    # filter_event/2 callbacks run through EventFilter.
    if map_size(state.plugin_configs) == 0 do
      {:reply, {:ok, event}, state}
    else
      filtered =
        Raxol.Core.Runtime.Plugins.EventFilter.filter_event(state, event)

      {:reply, filtered, state}
    end
  end

  def handle_call({:unload, plugin_id}, _from, state) do
    id = normalize_id(plugin_id)

    case do_unload_plugin(id, state) do
      {:ok, new_state} ->
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:enable, plugin_id}, _from, state) do
    id = normalize_id(plugin_id)

    case Map.get(state.plugin_status, id) do
      nil ->
        {:reply, {:error, :not_loaded}, state}

      :enabled ->
        {:reply, :ok, state}

      _status ->
        new_status = Map.put(state.plugin_status, id, :enabled)
        new_state = %{state | plugin_status: new_status}
        maybe_call_hook(id, :on_enable, state)
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:disable, plugin_id}, _from, state) do
    id = normalize_id(plugin_id)

    case Map.get(state.plugin_status, id) do
      nil ->
        {:reply, {:error, :not_loaded}, state}

      :disabled ->
        {:reply, :ok, state}

      _status ->
        maybe_call_hook(id, :on_disable, state)
        new_status = Map.put(state.plugin_status, id, :disabled)
        new_state = %{state | plugin_status: new_status}
        {:reply, :ok, new_state}
    end
  end

  def handle_call({:reload, plugin_id}, _from, state) do
    id = normalize_id(plugin_id)

    case PluginRegistry.get(id) do
      {:ok, entry} ->
        config = Map.get(state.plugin_configs, id, %{})

        with {:ok, state1} <- do_unload_plugin(id, state),
             {:ok, state2} <- do_load_plugin(id, entry.module, config, state1) do
          {:reply, :ok, state2}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_state, plugin_id}, _from, state) do
    id = normalize_id(plugin_id)

    # Use centralized StateManager (ETS-backed) for plugin state
    case PluginStateManager.get_plugin_state(to_string(id)) do
      {:ok, plugin_state} -> {:reply, {:ok, plugin_state}, state}
      {:error, :not_found} -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:set_state, plugin_id, plugin_state}, _from, state) do
    id = normalize_id(plugin_id)

    case Map.has_key?(state.plugin_status, id) do
      true ->
        # Use centralized StateManager (ETS-backed) for plugin state
        PluginStateManager.set_plugin_state(to_string(id), plugin_state)
        {:reply, :ok, state}

      false ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:get_config, plugin_id}, _from, state) do
    id = normalize_id(plugin_id)
    config = Map.get(state.plugin_configs, id, %{})
    {:reply, config, state}
  end

  def handle_call({:get_status, plugin_id}, _from, state) do
    id = normalize_id(plugin_id)
    status = Map.get(state.plugin_status, id)
    {:reply, status, state}
  end

  def handle_call(:list_with_status, _from, state) do
    result =
      state.plugin_status
      |> Map.to_list()
      |> Enum.sort_by(fn {id, _} -> id end)

    {:reply, result, state}
  end

  @impl GenServer
  def handle_cast({:update_config, plugin_id, config}, state) do
    id = normalize_id(plugin_id)
    new_configs = Map.put(state.plugin_configs, id, config)
    {:noreply, %{state | plugin_configs: new_configs}}
  end

  def handle_cast({:schedule_reload, plugin_id, delay_ms}, state) do
    id = normalize_id(plugin_id)

    {debounce, _ref} =
      Debounce.schedule(state.debounce, {:reload, id}, delay_ms)

    {:noreply, %{state | debounce: debounce}}
  end

  def handle_cast({:enable_file_watching, dirs}, state) do
    # File watching implementation would go here
    # For now, just store the configuration
    new_state = %{state | file_watching_enabled: true, plugin_dirs: dirs}
    {:noreply, new_state}
  end

  def handle_cast(:disable_file_watching, state) do
    new_state = %{state | file_watching_enabled: false}
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info({:debounce, {:reload, plugin_id}, debounce_id}, state) do
    if Debounce.valid?(state.debounce, {:reload, plugin_id}, debounce_id) do
      Log.debug("Debounced reload triggered for plugin: #{plugin_id}")

      case PluginRegistry.get(plugin_id) do
        {:ok, entry} ->
          config = Map.get(state.plugin_configs, plugin_id, %{})

          case do_unload_plugin(plugin_id, state) do
            {:ok, state1} ->
              case do_load_plugin(plugin_id, entry.module, config, state1) do
                {:ok, state2} ->
                  debounce =
                    Debounce.clear(state2.debounce, {:reload, plugin_id})

                  {:noreply, %{state2 | debounce: debounce}}

                {:error, _} ->
                  {:noreply, state}
              end

            {:error, _} ->
              {:noreply, state}
          end

        :error ->
          {:noreply, state}
      end
    else
      # Stale debounce message, ignore
      {:noreply, state}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp do_load_plugin(plugin_id, module, config, state) do
    # Register in registry
    case PluginRegistry.register(plugin_id, module, %{
           loaded_at: DateTime.utc_now()
         }) do
      :ok ->
        # Initialize plugin state using centralized StateManager
        initial_state = initialize_plugin_state(module, config)
        plugin_id_str = to_string(plugin_id)
        PluginStateManager.set_plugin_state(plugin_id_str, initial_state)

        new_state = %{
          state
          | plugin_configs: Map.put(state.plugin_configs, plugin_id, config),
            plugin_status: Map.put(state.plugin_status, plugin_id, :loaded)
        }

        maybe_call_hook(plugin_id, :on_load, new_state)
        {:ok, new_state}

      {:error, :already_registered} ->
        {:error, :already_loaded}
    end
  end

  defp do_unload_plugin(plugin_id, state) do
    case Map.get(state.plugin_status, plugin_id) do
      nil ->
        {:error, :not_loaded}

      _status ->
        maybe_call_hook(plugin_id, :on_unload, state)

        # Unregister from registry
        PluginRegistry.unregister(plugin_id)

        # Clean up state using centralized StateManager
        PluginStateManager.remove_plugin(to_string(plugin_id))

        new_state = %{
          state
          | plugin_configs: Map.delete(state.plugin_configs, plugin_id),
            plugin_status: Map.delete(state.plugin_status, plugin_id)
        }

        {:ok, new_state}
    end
  end

  defp initialize_plugin_state(module, config) do
    # Use PluginSupervisor for isolated plugin initialization
    case PluginSupervisor.call_plugin_callback(:init, module, :init, [config], timeout: 5_000) do
      {:ok, {:ok, state}} ->
        state

      {:ok, state} when is_map(state) ->
        state

      {:error, reason} ->
        Log.warning("Plugin init failed: #{inspect(reason)}, using empty state")
        %{}

      :not_exported ->
        %{}
    end
  end

  defp maybe_call_hook(plugin_id, hook, _state) do
    case PluginRegistry.get_module(plugin_id) do
      nil ->
        :ok

      module ->
        # Use PluginSupervisor for isolated hook execution (fire and forget)
        case PluginSupervisor.call_plugin_callback(plugin_id, module, hook, [], timeout: 2_000) do
          {:ok, _result} ->
            :ok

          {:error, reason} ->
            Log.warning("Plugin hook #{hook} failed for #{plugin_id}: #{inspect(reason)}")

            :ok

          :not_exported ->
            :ok
        end
    end
  end

  defp normalize_id(id) when is_atom(id), do: id
  defp normalize_id(id) when is_binary(id), do: String.to_atom(id)
end
