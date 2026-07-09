defmodule Raxol.Core.Runtime.Plugins.LifecycleHelper do
  @moduledoc """
  Helper functions for plugin lifecycle management.
  """

  @behaviour Raxol.Core.Runtime.Plugins.LifecycleHelper.Behaviour

  alias Raxol.Core.Runtime.Plugins.{
    Loader,
    PluginCommandManager,
    PluginErrorHandler,
    PluginEventProcessor,
    PluginInitializer,
    PluginLifecycleCallbacks,
    PluginReloader,
    PluginUnloader,
    PluginValidator
  }


  def init(opts) do
    {:ok, opts}
  end

  # Not part of the behaviour - internal helper function
  def load_plugin(
        plugin_id_or_module,
        config,
        plugins,
        metadata,
        plugin_states,
        load_order,
        command_table,
        plugin_config
      ) do
    with {:ok, {plugin_id, plugin_module}} <-
           PluginValidator.resolve_plugin_identity(plugin_id_or_module),
         :ok <-
           PluginValidator.validate_plugin(
             plugin_id,
             plugin_module,
             plugins,
             %{}
           ),
         {:ok, plugin_metadata} <- Loader.extract_metadata(plugin_module),
         {:ok, updated_maps} <-
           initialize_and_register_plugin(%{
             plugin_id: plugin_id,
             plugin_module: plugin_module,
             plugin_metadata: plugin_metadata,
             config: config,
             plugins: plugins,
             metadata: metadata,
             plugin_states: plugin_states,
             load_order: load_order,
             command_table: command_table,
             plugin_config: plugin_config
           }) do
      {:ok, updated_maps}
    else
      {:error, :already_loaded} ->
        {:error, "Plugin #{plugin_id_or_module} is already loaded"}

      {:error, :invalid_plugin} ->
        {:error, "Plugin #{plugin_id_or_module} does not implement required behaviour"}

      {:error, reason} ->
        PluginErrorHandler.handle_load_error(reason, plugin_id_or_module)
    end
  end

  defp initialize_and_register_plugin(%{
         plugin_id: plugin_id,
         plugin_module: plugin_module,
         plugin_metadata: plugin_metadata,
         config: config,
         plugins: plugins,
         metadata: metadata,
         plugin_states: plugin_states,
         load_order: load_order,
         command_table: command_table,
         plugin_config: plugin_config
       }) do
    with {:ok, initial_state} <-
           StateManager.initialize_plugin_state(plugin_module, config),
         {:ok, _} <-
           register_plugin_components(%{
             plugin_id: plugin_id,
             plugin_module: plugin_module,
             initial_state: initial_state,
             command_table: command_table,
             plugin_metadata: plugin_metadata,
             plugins: plugins,
             metadata: metadata,
             plugin_states: plugin_states,
             load_order: load_order,
             plugin_config: plugin_config
           }) do
      {:ok,
       _build_updated_maps(%{
         plugin_id: plugin_id,
         plugin_module: plugin_module,
         plugin_metadata: plugin_metadata,
         initial_state: initial_state,
         config: config,
         plugins: plugins,
         metadata: metadata,
         plugin_states: plugin_states,
         load_order: load_order,
         plugin_config: plugin_config
       })}
    end
  end

  defp register_plugin_components(%{
         plugin_id: plugin_id,
         plugin_module: plugin_module,
         initial_state: initial_state,
         command_table: command_table,
         plugin_metadata: plugin_metadata,
         plugins: _plugins,
         metadata: _metadata,
         plugin_states: _plugin_states,
         load_order: _load_order,
         plugin_config: plugin_config
       }) do
    with {:ok, _} <-
           StateManager.update_plugin_state_legacy(
             plugin_id,
             initial_state,
             plugin_config
           ),
         :ok <-
           PluginCommandManager.register_commands(
             plugin_module,
             initial_state,
             command_table
           ) do
      case _register_plugin(plugin_id, plugin_metadata) do
        :ok -> {:ok, nil}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp _build_updated_maps(%{
         plugin_id: plugin_id,
         plugin_module: plugin_module,
         plugin_metadata: plugin_metadata,
         initial_state: initial_state,
         config: config,
         plugins: plugins,
         metadata: metadata,
         plugin_states: plugin_states,
         load_order: load_order,
         plugin_config: plugin_config
       }) do
    %{
      plugins: Map.put(plugins, plugin_id, plugin_module),
      metadata: Map.put(metadata, plugin_id, plugin_metadata),
      plugin_states: Map.put(plugin_states, plugin_id, initial_state),
      load_order: [plugin_id | load_order],
      plugin_config: Map.put(plugin_config, plugin_id, config)
    }
  end

  defp _register_plugin(plugin_id, plugin_metadata) do
    Raxol.Core.GlobalRegistry.register(:plugins, plugin_id, plugin_metadata)
  end

  def initialize_plugins(
        plugins,
        metadata,
        config,
        states,
        load_order,
        command_table,
        opts
      ) do
    PluginInitializer.initialize_plugins(
      plugins,
      metadata,
      config,
      states,
      load_order,
      command_table,
      opts
    )
  end

  # Not part of the behaviour - internal helper function
  def cleanup_plugin(plugin_id, metadata) do
    case PluginLifecycleCallbacks.cleanup_plugin(plugin_id, metadata) do
      {:ok, _metadata} -> :ok
    end
  end

  # Not part of the behaviour - internal helper function
  def handle_state_transition(plugin_id, old_state, new_state) do
    PluginLifecycleCallbacks.handle_state_transition(
      plugin_id,
      old_state,
      new_state
    )
  end

  # Not part of the behaviour - internal helper function
  def init_plugin(plugin_id, metadata) do
    PluginLifecycleCallbacks.init_plugin(plugin_id, metadata)
  end

  # Not part of the behaviour - internal helper function
  def load_plugin_by_module(
        module,
        metadata,
        config,
        states,
        command_table,
        plugin_manager,
        current_metadata,
        opts
      ) do
    PluginLifecycleCallbacks.load_plugin_by_module(
      module,
      metadata,
      config,
      states,
      command_table,
      plugin_manager,
      current_metadata,
      opts
    )
  end

  def reload_plugin(
        plugin_id,
        metadata,
        config,
        states,
        command_table,
        plugin_manager,
        opts
      ) do
    PluginLifecycleCallbacks.reload_plugin(
      plugin_id,
      metadata,
      config,
      states,
      command_table,
      plugin_manager,
      opts
    )
  end

  # Not part of the behaviour - internal helper function
  def terminate_plugin(plugin_id, metadata, reason) do
    case PluginLifecycleCallbacks.terminate_plugin(plugin_id, metadata, reason) do
      {:ok, _metadata} -> :ok
    end
  end

  # Not part of the behaviour - internal helper function
  def handle_event(
        event,
        plugins,
        metadata,
        plugin_states,
        load_order,
        command_table,
        plugin_config
      ) do
    # Delegate event processing to PluginEventProcessor
    case PluginEventProcessor.process_event_through_plugins(
           event,
           plugins,
           metadata,
           plugin_states,
           load_order,
           command_table,
           plugin_config
         ) do
      {:ok, {updated_metadata, updated_states, updated_table}} ->
        {:ok, {updated_metadata, updated_states, updated_table}}

      {:error, reason} ->
        PluginErrorHandler.handle_event_error(event, reason)
    end
  end

  # Not part of the behaviour - internal helper function
  def reload_plugin_from_disk(
        plugin_id,
        _plugin_module,
        _plugin_path,
        _plugin_state,
        _command_table,
        _metadata,
        _plugin_manager,
        _opts
      ) do
    PluginReloader.reload_plugin(plugin_id, %{})
  end

  # Not part of the behaviour - internal helper function
  def unload_plugin(plugin_id, metadata, config, states, command_table, opts) do
    PluginUnloader.unload_plugin(
      plugin_id,
      metadata,
      config,
      states,
      command_table,
      opts
    )
  end

  @doc """
  Enables a plugin by updating its state to enabled.
  """
  # Not part of the behaviour - internal helper function
  def enable_plugin(plugin, plugin_states) do
    # For now, just return the existing plugin state as enabled
    # This is a simple implementation that can be enhanced later
    plugin_id =
      case {is_map(plugin), Map.has_key?(plugin, :name)} do
        {true, true} -> plugin.name
        _ -> "unknown"
      end

    case Map.get(plugin_states, plugin_id) do
      nil ->
        # If no state exists, create a basic enabled state
        {:ok, %{enabled: true, name: plugin_id}}

      existing_state ->
        # Update existing state to enabled
        {:ok, Map.put(existing_state, :enabled, true)}
    end
  end

  @doc """
  Disables a plugin by updating its state to disabled.
  """
  # Not part of the behaviour - internal helper function
  def disable_plugin(plugin, plugin_states) do
    # For now, just return the existing plugin state as disabled
    # This is a simple implementation that can be enhanced later
    plugin_id =
      case {is_map(plugin), Map.has_key?(plugin, :name)} do
        {true, true} -> plugin.name
        _ -> "unknown"
      end

    case Map.get(plugin_states, plugin_id) do
      nil ->
        # If no state exists, create a basic disabled state
        {:ok, %{enabled: false, name: plugin_id}}

      existing_state ->
        # Update existing state to disabled
        {:ok, Map.put(existing_state, :enabled, false)}
    end
  end

  @doc """
  Catch-all for load_plugin/3. Raises a clear error if called with the wrong arity.
  """
  def load_plugin(_a, _b, _c) do
    {:error, {:not_implemented, "Use load_plugin/8 instead of load_plugin/3"}}
  end

  # Implement required behaviour callbacks
  @impl true
  def init_lifecycle(plugin_id, opts) do
    # Initialize plugin with default metadata and config
    # init_plugin always returns {:ok, _}, never errors
    {:ok, _} = init_plugin(plugin_id, opts[:metadata] || %{})
    {:ok, plugin_id}
  end

  @impl true
  def start_lifecycle(plugin_id, _state) do
    # Return success - plugin is already initialized
    {:ok, plugin_id}
  end

  @impl true
  def stop_lifecycle(plugin_id, _state) do
    # Return success - plugin can be stopped
    {:ok, plugin_id}
  end

  @impl true
  def terminate_lifecycle(plugin_id, _state) do
    # Simple termination logic
    terminate_plugin(plugin_id, %{}, :shutdown)
    :ok
  end
end
