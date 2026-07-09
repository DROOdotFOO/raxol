defmodule Raxol.Core.Runtime.Plugins.EventFilter do
  @moduledoc """
  Handles event filtering for plugins.
  This module is responsible for:
  - Filtering events through registered plugin filters
  - Managing event modifications
  - Handling event halting
  """


  @doc """
  Filters an event through registered plugin filters.
  Returns the filtered event or :halt if the event should be stopped.
  """
  @spec filter_event(map(), map()) :: map() | :halt
  def filter_event(plugin_manager_state, event) do
    Raxol.Core.Runtime.Log.debug(
      "[#{__MODULE__}] filter_event called for: #{inspect(event.type)}"
    )

    # Get all enabled plugins in load order
    enabled_plugins = get_enabled_plugins(plugin_manager_state)

    # Apply filters in load order
    Enum.reduce_while(enabled_plugins, event, fn plugin_id, current_event ->
      case apply_plugin_filter(plugin_id, current_event, plugin_manager_state) do
        {:ok, modified_event} ->
          {:cont, modified_event}

        :halt ->
          {:halt, :halt}

        {:error, reason} ->
          Raxol.Core.Runtime.Log.warning_with_context(
            "[#{__MODULE__}] Plugin #{plugin_id} filter error: #{inspect(reason)}",
            %{plugin_id: plugin_id, reason: reason, module: __MODULE__}
          )

          {:cont, current_event}
      end
    end)
  end

  # --- Private Helpers ---

  # Get list of enabled plugins in load order
  @spec get_enabled_plugins(map()) :: [atom()]
  defp get_enabled_plugins(state) do
    Enum.filter(state.load_order, fn plugin_id ->
      match?(%{enabled: true}, Map.get(state.metadata, plugin_id))
    end)
  end

  # Apply a single plugin's filter to the event
  @spec apply_plugin_filter(atom(), map(), map()) ::
          {:ok, map()} | :halt | {:error, term()}
  defp apply_plugin_filter(plugin_id, event, state) do
    case Map.get(state.plugins, plugin_id) do
      nil ->
        {:error, :plugin_not_found}

      plugin_module ->
        call_plugin_filter_safely(plugin_module, plugin_id, event, state)
    end
  end

  defp call_plugin_filter_safely(plugin_module, plugin_id, event, state) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           call_plugin_filter(plugin_module, plugin_id, event, state)
         end) do
      {:ok, result} ->
        result

      {:error, e} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[#{__MODULE__}] Plugin #{plugin_id} filter crashed",
          e,
          nil,
          %{plugin_id: plugin_id, event: event, module: __MODULE__}
        )

        {:error, :filter_crashed}
    end
  end

  defp call_plugin_filter(plugin_module, plugin_id, event, state) do
    case function_exported?(plugin_module, :filter_event, 2) do
      true ->
        plugin_module.filter_event(
          event,
          Map.get(state.plugin_states, plugin_id)
        )

      false ->
        # Plugin doesn't implement filtering, pass event through unchanged
        {:ok, event}
    end
  end
end
