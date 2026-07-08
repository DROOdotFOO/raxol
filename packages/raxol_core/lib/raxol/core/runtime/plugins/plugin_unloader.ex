defmodule Raxol.Core.Runtime.Plugins.PluginUnloader do
  @moduledoc """
  Handles unloading of plugins, including command and state cleanup.
  """

  alias Raxol.Core.Runtime.Plugins.CommandRegistry

  @doc """
  Unloads a plugin, cleaning up commands and state.
  """
  def unload_plugin(plugin_id, metadata, _config, states, command_table, _opts) do
    with {:ok, _plugin_metadata} <- Map.fetch(metadata, plugin_id),
         :ok <- unregister_plugin_commands(plugin_id, command_table) do
      cleanup_plugin_state(plugin_id, metadata, states, command_table)
    else
      :error -> {:ok, {metadata, states, command_table}}
    end
  end

  @doc """
  Unregisters plugin commands.
  """
  def unregister_plugin_commands(plugin_id, command_table) do
    CommandRegistry.unregister_plugin_commands(plugin_id, command_table)
  end

  @doc """
  Cleans up plugin state and metadata.
  """
  def cleanup_plugin_state(plugin_id, metadata, states, command_table) do
    Raxol.Core.GlobalRegistry.unregister(:plugins, plugin_id)
    meta = Map.delete(metadata, plugin_id)
    sts = Map.delete(states, plugin_id)
    {:ok, {meta, sts, command_table}}
  end

  @doc """
  Handles unload errors.
  """
  def handle_unload_error(reason, plugin_id) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "Failed to unload plugin",
      reason,
      nil,
      %{module: __MODULE__, plugin_id: plugin_id, reason: reason}
    )

    {:error, reason}
  end
end
