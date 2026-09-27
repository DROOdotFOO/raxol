# Was `defmodule StateManager` at the top level -- an unnamespaced, generic
# name injected into the global module namespace of every application that
# depends on raxol_core. Renamed rather than merged into the namespaced module
# below because the two have colliding arities (that module adds /2 and /3
# compatibility wrappers over these /1 and /2 functions).
defmodule Raxol.Core.Runtime.Plugins.StateManager.Impl do
  @moduledoc """
  Plugin state management utilities with full functionality.

  Provides state management for the plugin system, including initialization,
  updates, persistence, and cleanup. Integrates with the unified state manager
  for consistency and performance.

  Callers should use `Raxol.Core.Runtime.Plugins.StateManager`, which delegates
  here and carries the arity-compatibility wrappers.
  """

  alias Raxol.Core.Runtime.Log

  # NOTE: this alias deliberately shadows this module's own last name segment.
  # Every bare `StateManager.*` call in this module body targets
  # `Raxol.Core.StateManager` (the unified store in main raxol), NOT recursion
  # into this module.
  alias Raxol.Core.StateManager

  # Raxol.Core.StateManager lives in main raxol; suppress warnings when
  # compiling raxol_core standalone.
  @compile {:no_warn_undefined, Raxol.Core.StateManager}
  @type plugin_id :: String.t()
  @type plugin_module :: module()
  @type plugin_config :: map()
  @type plugin_state :: term()

  @doc """
  Gets plugin state by plugin ID.
  """
  @spec get_plugin_state(plugin_id()) ::
          {:ok, plugin_state()} | {:error, :not_found}
  def get_plugin_state(plugin_id) do
    state_key = [:plugins, :states, plugin_id]

    case StateManager.get_state(state_key) do
      nil -> {:error, :not_found}
      state -> {:ok, state}
    end
  end

  @doc """
  Sets plugin state directly.
  """
  @spec set_plugin_state(plugin_id(), plugin_state()) :: :ok
  def set_plugin_state(plugin_id, state) do
    state_key = [:plugins, :states, plugin_id]
    StateManager.set_state(state_key, state)
  end

  @doc """
  Updates plugin state using an update function.
  """
  @spec update_plugin_state(plugin_id(), (plugin_state() -> plugin_state())) ::
          {:ok, plugin_state()}
  def update_plugin_state(plugin_id, update_fn) do
    state_key = [:plugins, :states, plugin_id]

    _ =
      StateManager.update_state(state_key, fn current_state ->
        update_fn.(current_state || %{})
      end)

    # Update metadata timestamp
    metadata_key = [:plugins, :metadata, plugin_id]

    _ =
      StateManager.update_state(metadata_key, fn metadata ->
        case metadata do
          nil ->
            %{updated_at: :os.system_time(:millisecond)}

          existing ->
            Map.put(existing, :updated_at, :os.system_time(:millisecond))
        end
      end)

    {:ok, StateManager.get_state(state_key)}
  rescue
    error ->
      Log.error("Failed to update plugin state for #{plugin_id}: #{inspect(error)}")

      {:error, error}
  end

  @doc """
  Lists all plugin states.
  """
  @spec list_plugin_states() :: [{plugin_id(), plugin_state()}]
  def list_plugin_states do
    case StateManager.get_state([:plugins, :states]) do
      nil -> []
      states when is_map(states) -> Map.to_list(states)
      _ -> []
    end
  end

  @doc """
  Gets plugin metadata.
  """
  @spec get_plugin_metadata(plugin_id()) :: {:ok, map()} | {:error, :not_found}
  def get_plugin_metadata(plugin_id) do
    metadata_key = [:plugins, :metadata, plugin_id]

    case StateManager.get_state(metadata_key) do
      nil -> {:error, :not_found}
      metadata -> {:ok, metadata}
    end
  end

  @doc """
  Removes plugin state and metadata.
  """
  @spec remove_plugin(plugin_id()) :: :ok
  def remove_plugin(plugin_id) do
    _ = StateManager.delete_state([:plugins, :states, plugin_id])
    _ = StateManager.delete_state([:plugins, :metadata, plugin_id])
    Log.info("Removed state for plugin #{plugin_id}")
    :ok
  end

  @doc """
  Initializes the plugin state manager subsystem.
  """
  @spec initialize(term()) :: {:ok, term()}
  def initialize(state) do
    # Ensure plugins namespace exists in unified state
    _ =
      StateManager.set_state([:plugins], %{
        states: %{},
        metadata: %{},
        initialized_at: :os.system_time(:millisecond)
      })

    Log.info("Plugin state manager initialized")
    {:ok, state}
  end

  @doc """
  Cleans up all plugin states.
  """
  @spec cleanup() :: :ok
  def cleanup do
    _ = StateManager.delete_state([:plugins])
    Log.info("Plugin state manager cleaned up")
    :ok
  end
end

# The public face of plugin state management. Carries the arity-compatibility
# wrappers that the implementation module cannot, because they collide.
defmodule Raxol.Core.Runtime.Plugins.StateManager do
  @moduledoc """
  Plugin state management.

  Delegates to `Raxol.Core.Runtime.Plugins.StateManager.Impl` and adds the
  arity-2/3 compatibility wrappers used by older call sites.
  """

  alias Raxol.Core.Runtime.Plugins.StateManager.Impl

  defdelegate get_plugin_state(plugin_id), to: Impl
  defdelegate set_plugin_state(plugin_id, state), to: Impl
  defdelegate update_plugin_state(plugin_id, update_fn), to: Impl
  defdelegate list_plugin_states(), to: Impl
  defdelegate get_plugin_metadata(plugin_id), to: Impl
  defdelegate remove_plugin(plugin_id), to: Impl
  defdelegate initialize(state), to: Impl
  defdelegate cleanup(), to: Impl

  @doc """
  Gets plugin state with both plugin_id and state parameters for compatibility.
  """
  @spec get_plugin_state(String.t(), term()) :: {:ok, term()}
  def get_plugin_state(plugin_id, _state) do
    Impl.get_plugin_state(plugin_id)
  end

  @doc """
  Sets plugin state with plugin_id and state parameters for compatibility.
  """
  @spec set_plugin_state(String.t(), term(), term()) :: {:ok, term()}
  def set_plugin_state(plugin_id, state, _current_state) do
    Impl.set_plugin_state(plugin_id, state)
    {:ok, state}
  end

  @doc """
  Updates plugin state with additional state parameter for compatibility.
  """
  @spec update_plugin_state(String.t(), term(), (term() -> term())) ::
          {:ok, term()}
  def update_plugin_state(plugin_id, _state, update_fn) do
    Impl.update_plugin_state(plugin_id, update_fn)
  end
end
