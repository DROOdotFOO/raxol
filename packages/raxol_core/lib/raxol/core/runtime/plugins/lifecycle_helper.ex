defmodule Raxol.Core.Runtime.Plugins.LifecycleHelper do
  @moduledoc """
  Helper functions for plugin lifecycle management.
  """

  @behaviour Raxol.Core.Runtime.Plugins.LifecycleHelper.Behaviour

  alias Raxol.Core.Runtime.Plugins.{
    PluginErrorHandler,
    PluginEventProcessor,
    PluginInitializer,
    PluginLifecycleCallbacks,
    PluginReloader
  }

  def init(opts) do
    {:ok, opts}
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
