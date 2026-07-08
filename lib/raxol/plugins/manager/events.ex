defmodule Raxol.Plugins.Manager.Events do
  @moduledoc """
  Handles plugin event processing.
  Provides functions for processing various types of events through plugins.
  """


  alias Raxol.Plugins.EventHandler
  alias Raxol.Plugins.Manager

  @doc """
  Processes input through all enabled plugins.
  Delegates to `Raxol.Plugins.EventHandler.handle_input/2`.
  """
  def process_input(%Manager{} = manager, input) when is_binary(input) do
    EventHandler.handle_input(manager, input)
  end

  @doc """
  Processes output through all enabled plugins.
  Returns {:ok, manager, transformed_output} if a plugin transforms the output,
  or {:ok, manager} if no transformation is needed.
  Delegates to `Raxol.Plugins.EventHandler.handle_output/2`.
  """
  def process_output(%Manager{} = manager, output) when is_binary(output) do
    EventHandler.handle_output(manager, output)
  end

  @doc """
  Notifies all enabled plugins of a terminal resize event.
  Delegates to `Raxol.Plugins.EventHandler.handle_resize/3`.
  """
  def handle_resize(%Manager{} = manager, width, height)
      when is_integer(width) and is_integer(height) do
    EventHandler.handle_resize(manager, width, height)
  end

  @doc """
  Processes a mouse event through all enabled plugins, providing cell context.
  Plugins can choose to halt propagation if they handle the event.
  Returns {:ok, updated_manager, :propagate | :halt} or {:error, reason}.
  Delegates to `Raxol.Plugins.EventHandler.handle_mouse_event/3`.
  """
  def handle_mouse_event(%Manager{} = manager, event, rendered_cells)
      when is_map(event) do
    case EventHandler.handle_mouse_event(manager, event, rendered_cells) do
      {:ok, updated_manager} -> {:ok, updated_manager, :propagate}
    end
  end

  @doc """
  Broadcasts an event to all enabled plugins.
  Returns {:ok, updated_manager} or {:error, reason}.
  """
  def broadcast_event(%Manager{} = manager, event) do
    Enum.reduce_while(
      manager.plugins,
      {:ok, manager},
      &broadcast_plugin_event(&1, &2, event)
    )
  end

  defp broadcast_plugin_event({_name, plugin}, {:ok, acc_manager}, event) do
    case plugin.enabled do
      true ->
        module = plugin.__struct__

        case function_exported?(module, :handle_event, 2) do
          true ->
            handle_plugin_event(module, plugin, event, acc_manager)

          false ->
            {:cont, {:ok, acc_manager}}
        end

      false ->
        {:cont, {:ok, acc_manager}}
    end
  end

  defp handle_plugin_event(module, plugin, event, acc_manager) do
    case module.handle_event(plugin, event) do
      {:ok, updated_plugin} ->
        updated_manager =
          Manager.update_plugins(
            acc_manager,
            Map.put(acc_manager.plugins, plugin.name, updated_plugin)
          )

        {:cont, {:ok, updated_manager}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @doc """
  Loads a plugin module and initializes it. Delegates to `Raxol.Plugins.Lifecycle.load_plugin/2` or `/3`.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  def load_plugin(%Manager{} = manager, module) when is_atom(module) do
    Raxol.Plugins.Lifecycle.load_plugin(manager, module)
  end

  def load_plugin(%Manager{} = manager, module, config)
      when is_atom(module) and is_map(config) do
    Raxol.Plugins.Lifecycle.load_plugin(manager, module, config)
  end

  def new do
    Raxol.Core.new()
  end

  @doc """
  Unloads a plugin from the manager.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  def unload_plugin(%Manager{} = manager, plugin_name)
      when is_binary(plugin_name) do
    _plugin_key = normalize_plugin_key(plugin_name)
    Raxol.Plugins.Lifecycle.unload_plugin(manager, plugin_name)
  end

  @doc """
  Enables a plugin in the manager.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  def enable_plugin(%Manager{} = manager, plugin_name)
      when is_binary(plugin_name) do
    case get_plugin(manager, plugin_name) do
      {:ok, plugin} ->
        updated_plugin = %{plugin | enabled: true}
        plugin_key = normalize_plugin_key(plugin_name)

        updated_manager =
          Manager.update_plugins(
            manager,
            Map.put(manager.plugins, plugin_key, updated_plugin)
          )

        {:ok, updated_manager}

      error ->
        error
    end
  end

  @doc """
  Disables a plugin in the manager.
  Returns `{:ok, updated_manager}` or `{:error, reason}`.
  """
  def disable_plugin(%Manager{} = manager, plugin_name)
      when is_binary(plugin_name) do
    case get_plugin(manager, plugin_name) do
      {:ok, plugin} ->
        updated_plugin = %{plugin | enabled: false}
        plugin_key = normalize_plugin_key(plugin_name)

        updated_manager =
          Manager.update_plugins(
            manager,
            Map.put(manager.plugins, plugin_key, updated_plugin)
          )

        {:ok, updated_manager}

      error ->
        error
    end
  end

  @doc """
  Gets a plugin by name from the manager.
  Returns `{:ok, plugin}` or `{:error, :not_found}`.
  """
  def get_plugin(%Manager{} = manager, plugin_name)
      when is_binary(plugin_name) do
    plugin_key = normalize_plugin_key(plugin_name)

    case Map.get(manager.plugins, plugin_key) do
      nil -> {:error, "Plugin #{plugin_name} not found"}
      plugin -> {:ok, plugin}
    end
  end

  # Helper to normalize plugin keys to strings
  defp normalize_plugin_key(key) when is_binary(key), do: key
end
