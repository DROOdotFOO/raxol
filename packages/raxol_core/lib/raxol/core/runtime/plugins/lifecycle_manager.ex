defmodule Raxol.Core.Runtime.Plugins.LifecycleManager do
  @moduledoc """
  Handles plugin lifecycle operations including loading, unloading, enabling, and disabling plugins.
  """


  @doc """
  Loads a plugin with the given configuration.
  """
  def load_plugin(
        plugin_id,
        config,
        plugins,
        metadata,
        plugin_states,
        load_order,
        command_registry_table,
        plugin_config
      ) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Loading plugin: #{plugin_id}",
      %{plugin_id: plugin_id, config: config}
    )

    case Raxol.Core.Runtime.Plugins.Discovery.load_plugin(
           plugin_id,
           config,
           plugins,
           metadata,
           plugin_states,
           load_order,
           command_registry_table,
           plugin_config
         ) do
      {:ok, updated_maps} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully loaded plugin: #{plugin_id}",
          %{plugin_id: plugin_id}
        )

        {:ok, updated_maps}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to load plugin: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Loads a plugin by module.
  """
  def load_plugin_by_module(
        module,
        config,
        plugins,
        metadata,
        plugin_states,
        load_order,
        command_registry_table,
        plugin_config
      ) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Loading plugin module: #{inspect(module)}",
      %{module: module, config: config}
    )

    # Ensure plugin_states and command_registry_table are maps
    safe_plugin_states =
      case plugin_states do
        states when is_map(states) -> states
        _ -> %{}
      end

    safe_command_registry_table =
      case command_registry_table do
        table when is_map(table) -> table
        _ -> %{}
      end

    case Raxol.Core.Runtime.Plugins.Discovery.load_plugin_by_module(
           module,
           config,
           plugins,
           metadata,
           safe_plugin_states,
           load_order,
           safe_command_registry_table,
           plugin_config
         ) do
      {:ok, {updated_metadata, updated_states, updated_table}} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully loaded plugin module: #{inspect(module)}",
          %{module: module}
        )

        {:ok, {updated_metadata, updated_states, updated_table}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to load plugin module: #{inspect(module)}",
          reason,
          nil,
          %{module: module, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Unloads a plugin.
  """
  def unload_plugin(
        plugin_id,
        plugins,
        metadata,
        plugin_states,
        command_registry_table,
        plugin_config
      ) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Unloading plugin: #{plugin_id}",
      %{plugin_id: plugin_id}
    )

    case Raxol.Core.Runtime.Plugins.Discovery.unload_plugin(
           plugin_id,
           plugins,
           metadata,
           plugin_states,
           command_registry_table,
           plugin_config
         ) do
      {:ok, {updated_metadata, updated_states, updated_command_table}} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully unloaded plugin: #{plugin_id}",
          %{plugin_id: plugin_id}
        )

        {:ok, {updated_metadata, updated_states, updated_command_table}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to unload plugin: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Initializes a plugin with the given configuration.
  """
  def initialize_plugin(
        plugin_name,
        _config,
        plugins,
        metadata,
        plugin_states,
        _load_order,
        command_registry_table,
        _plugin_config
      ) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Initializing plugin: #{plugin_name}",
      %{plugin_name: plugin_name}
    )

    state = %{
      plugins: plugins,
      metadata: metadata,
      plugin_states: plugin_states
    }

    case Raxol.Core.Runtime.Plugins.Discovery.initialize_plugin(
           plugin_name,
           state
         ) do
      {:ok, updated_state} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully initialized plugin: #{plugin_name}",
          %{plugin_name: plugin_name}
        )

        {:ok, {updated_state.metadata, updated_state.plugin_states, command_registry_table}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to initialize plugin: #{plugin_name}",
          reason,
          nil,
          %{plugin_name: plugin_name, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Initializes all plugins.
  """
  def initialize_plugins(
        plugins,
        metadata,
        plugin_config,
        plugin_states,
        load_order,
        command_registry_table,
        config
      ) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Initializing all plugins",
      %{plugin_count: map_size(plugins)}
    )

    case Raxol.Core.Runtime.Plugins.PluginInitializer.initialize_plugins(
           plugins,
           metadata,
           plugin_config,
           plugin_states,
           load_order,
           command_registry_table,
           config || []
         ) do
      {:ok, {updated_metadata, updated_states, updated_table}} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully initialized all plugins",
          %{plugin_count: map_size(plugins)}
        )

        {:ok, {updated_metadata, updated_states, updated_table}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to initialize plugins",
          reason,
          nil,
          %{reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Enables a plugin.
  """
  def enable_plugin(plugin_id, state) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Enabling plugin: #{plugin_id}",
      %{plugin_id: plugin_id}
    )

    case Raxol.Core.Runtime.Plugins.Discovery.enable_plugin(plugin_id, state) do
      {:ok, updated_state} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully enabled plugin: #{plugin_id}",
          %{plugin_id: plugin_id}
        )

        {:ok, updated_state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to enable plugin: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Disables a plugin.
  """
  def disable_plugin(plugin_id, state) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Disabling plugin: #{plugin_id}",
      %{plugin_id: plugin_id}
    )

    case Raxol.Core.Runtime.Plugins.Discovery.disable_plugin(plugin_id, state) do
      {:ok, updated_state} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully disabled plugin: #{plugin_id}",
          %{plugin_id: plugin_id}
        )

        {:ok, updated_state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to disable plugin: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Reloads a plugin.
  """
  def reload_plugin(plugin_id, state) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Reloading plugin: #{plugin_id}",
      %{plugin_id: plugin_id}
    )

    case Raxol.Core.Runtime.Plugins.Discovery.reload_plugin(plugin_id, state) do
      {:ok, {updated_metadata, updated_states, updated_table}} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully reloaded plugin: #{plugin_id}",
          %{plugin_id: plugin_id}
        )

        {:ok, {updated_metadata, updated_states, updated_table}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to reload plugin: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, reason: reason}
        )

        {:error, reason}
    end
  end

  @doc """
  Reloads a plugin from disk.
  """
  def reload_plugin_from_disk(
        plugin_id,
        path,
        plugins,
        metadata,
        plugin_states,
        load_order,
        command_registry_table,
        plugin_config
      ) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Reloading plugin from disk: #{plugin_id}",
      %{plugin_id: plugin_id, path: path}
    )

    case Raxol.Core.Runtime.Plugins.Discovery.reload_plugin_from_disk(
           plugin_id,
           path,
           plugins,
           metadata,
           plugin_states,
           load_order,
           command_registry_table,
           plugin_config
         ) do
      {:ok,
       %{
         metadata: updated_metadata,
         plugin_states: updated_states,
         table: updated_table
       }} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully reloaded plugin from disk: #{plugin_id}",
          %{plugin_id: plugin_id, path: path}
        )

        {:ok, {updated_metadata, updated_states, updated_table}}

      {:error, reason, extra} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to reload plugin from disk: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, path: path, reason: reason, extra: extra}
        )

        {:error, reason}
    end
  end

  @doc """
  Cleans up a plugin.
  """
  def cleanup_plugin(plugin_id, metadata) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Cleaning up plugin: #{plugin_id}",
      %{plugin_id: plugin_id}
    )

    {:ok, updated_metadata} =
      Raxol.Core.Runtime.Plugins.Discovery.cleanup_plugin(
        plugin_id,
        metadata
      )

    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Successfully cleaned up plugin: #{plugin_id}",
      %{plugin_id: plugin_id}
    )

    {:ok, updated_metadata}
  end

  @doc """
  Handles an event.
  """
  def handle_event(
        event,
        plugins,
        metadata,
        plugin_states,
        load_order,
        command_registry_table,
        plugin_config
      ) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Handling event: #{inspect(event)}",
      %{event: event}
    )

    case Raxol.Core.Runtime.Plugins.Discovery.handle_event(
           event,
           plugins,
           metadata,
           plugin_states,
           load_order,
           command_registry_table,
           plugin_config
         ) do
      {:ok, {updated_metadata, updated_states, updated_table}} ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully handled event: #{inspect(event)}",
          %{event: event}
        )

        {:ok, {updated_metadata, updated_states, updated_table}}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to handle event: #{inspect(event)}",
          reason,
          nil,
          %{event: event, reason: reason}
        )

        {:error, reason}
    end
  end
end
