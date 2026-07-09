defmodule Raxol.Core.Runtime.Plugins.PluginReloader do
  @moduledoc """
  Handles plugin reloading operations including reloading by ID and from disk.
  """


  @doc """
  Reloads a plugin by ID.
  """
  def reload_plugin_by_id(plugin_id_string, state) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Reloading plugin by ID: #{plugin_id_string}",
      %{plugin_id_string: plugin_id_string}
    )

    case Raxol.Core.Runtime.Plugins.LifecycleManager.reload_plugin(
           plugin_id_string,
           state
         ) do
      {:ok, {updated_metadata, updated_states, updated_table}} ->
        # Merge the updated state components
        updated_state = %{
          state
          | metadata: updated_metadata,
            plugin_states: updated_states,
            table: updated_table
        }

        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully reloaded plugin by ID: #{plugin_id_string}",
          %{plugin_id_string: plugin_id_string}
        )

        {:ok, updated_state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to reload plugin by ID: #{plugin_id_string}",
          reason,
          nil,
          %{plugin_id_string: plugin_id_string, reason: reason}
        )

        {:error, reason, state}
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

    case Raxol.Core.Runtime.Plugins.LifecycleManager.reload_plugin(
           plugin_id,
           state
         ) do
      {:ok, {updated_metadata, updated_states, updated_table}} ->
        # Merge the updated state components
        updated_state = %{
          state
          | metadata: updated_metadata,
            plugin_states: updated_states,
            table: updated_table
        }

        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Successfully reloaded plugin: #{plugin_id}",
          %{plugin_id: plugin_id}
        )

        {:ok, updated_state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Failed to reload plugin: #{plugin_id}",
          reason,
          nil,
          %{plugin_id: plugin_id, reason: reason}
        )

        {:error, reason, state}
    end
  end
end
