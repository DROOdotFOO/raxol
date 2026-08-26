defmodule Raxol.Core.Runtime.Plugins.PluginEventProcessor do
  @moduledoc """
  Handles event processing and filtering through plugins.

  This module provides a pipeline for processing events through all enabled plugins.
  Events flow through plugins in load order, and any plugin can:

  - Modify the event (return `{:ok, modified_event}`)
  - Pass it through unchanged (return `{:ok, event}`)
  - Stop propagation (return `:halt`)
  - Handle errors gracefully

  ## Plugin Ordering

  Plugins are processed in the following order:

  1. By explicit priority (if defined in plugin metadata)
  2. By load order (plugins loaded first process events first)
  3. By dependency order (dependent plugins process after their dependencies)

  ## Event Filtering

  Plugins implementing the `filter_event/2` callback can modify or stop events:

      def filter_event(event, state) do
        case event do
          %{type: :sensitive} -> :halt  # Stop propagation
          %{type: :modifiable} -> {:ok, Map.put(event, :processed, true)}
          _ -> {:ok, event}  # Pass through unchanged
        end
      end

  ## Error Handling

  Plugin errors are logged but don't stop event propagation to other plugins.
  A crashed plugin is skipped, and the event continues to the next plugin.
  """

  alias Raxol.Core.Runtime.Plugins.PluginSupervisor

  @doc """
  Processes an event through all enabled plugins in load order.
  """
  def process_event_through_plugins(
        event,
        plugins,
        metadata,
        plugin_states,
        load_order,
        command_table,
        plugin_config
      ) do
    initial_state = {metadata, plugin_states, command_table}

    Enum.reduce_while(
      load_order,
      {:ok, initial_state},
      &process_single_plugin(&1, &2, event, plugins, plugin_config)
    )
  end

  defp process_single_plugin(plugin_id, acc, event, plugins, plugin_config) do
    case acc do
      {:ok, {current_metadata, current_states, current_table}} ->
        handle_plugin_processing(
          plugin_id,
          event,
          plugins,
          current_metadata,
          current_states,
          current_table,
          plugin_config
        )

      {:error, _reason} = error ->
        {:halt, error}
    end
  end

  defp handle_plugin_processing(
         plugin_id,
         event,
         plugins,
         metadata,
         states,
         table,
         config
       ) do
    case process_plugin_event(
           plugin_id,
           event,
           plugins,
           metadata,
           states,
           table,
           config
         ) do
      {:ok, result} -> {:cont, {:ok, result}}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  @doc """
  Processes an event for a specific plugin.
  """
  def process_plugin_event(
        plugin_id,
        event,
        plugins,
        metadata,
        plugin_states,
        command_table,
        _plugin_config
      ) do
    with {:ok, plugin_module} <- get_plugin_module(plugins, plugin_id),
         {:ok, _} <- validate_plugin_enabled(metadata, plugin_id),
         {:ok, plugin_state} <- get_plugin_state(plugin_states, plugin_id) do
      execute_plugin_event_handler(
        plugin_module,
        plugin_id,
        event,
        plugin_state,
        metadata,
        plugin_states,
        command_table
      )
    else
      {:error, :plugin_disabled} ->
        {:ok, {metadata, plugin_states, command_table}}

      {:error, _} = error ->
        error
    end
  end

  defp get_plugin_module(plugins, plugin_id) do
    case Map.get(plugins, plugin_id) do
      nil -> {:error, :plugin_not_found}
      module -> {:ok, module}
    end
  end

  defp validate_plugin_enabled(metadata, plugin_id) do
    case Map.get(metadata, plugin_id) do
      %{enabled: true} -> {:ok, :enabled}
      _ -> {:error, :plugin_disabled}
    end
  end

  defp get_plugin_state(plugin_states, plugin_id) do
    case Map.get(plugin_states, plugin_id) do
      nil -> {:error, :plugin_state_not_found}
      state -> {:ok, state}
    end
  end

  defp execute_plugin_event_handler(
         plugin_module,
         plugin_id,
         event,
         plugin_state,
         metadata,
         plugin_states,
         command_table
       ) do
    case function_exported?(plugin_module, :handle_event, 2) do
      true ->
        handle_plugin_event_call(
          plugin_module,
          plugin_id,
          event,
          plugin_state,
          metadata,
          plugin_states,
          command_table
        )

      false ->
        {:ok, {metadata, plugin_states, command_table}}
    end
  end

  defp handle_plugin_event_call(
         plugin_module,
         plugin_id,
         event,
         plugin_state,
         metadata,
         plugin_states,
         command_table
       ) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           plugin_module.handle_event(event, plugin_state)
         end) do
      {:ok, {:ok, updated_plugin_state}} ->
        updated_states =
          Map.put(plugin_states, plugin_id, updated_plugin_state)

        {:ok, {metadata, updated_states, command_table}}

      {:ok, {:error, reason}} ->
        log_plugin_error(plugin_id, event, reason)
        {:ok, {metadata, plugin_states, command_table}}

      {:ok, other} ->
        log_plugin_unexpected_return(plugin_id, event, other)
        {:ok, {metadata, plugin_states, command_table}}

      {:error, exception} ->
        log_plugin_crash(plugin_id, event, exception)
        {:ok, {metadata, plugin_states, command_table}}
    end
  end

  defp log_plugin_error(plugin_id, event, reason) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Plugin #{plugin_id} failed to handle event",
      %{
        plugin_id: plugin_id,
        event: event,
        reason: reason,
        module: __MODULE__
      }
    )
  end

  defp log_plugin_unexpected_return(plugin_id, event, value) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Plugin #{plugin_id} returned unexpected value from handle_event",
      %{
        plugin_id: plugin_id,
        event: event,
        value: value,
        module: __MODULE__
      }
    )
  end

  defp log_plugin_crash(plugin_id, event, exception) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "Plugin #{plugin_id} crashed during event handling",
      exception,
      nil,
      %{plugin_id: plugin_id, event: event, module: __MODULE__}
    )
  end

  # ============================================================================
  # Event Filtering API
  # ============================================================================

  @doc """
  Filters an event through all enabled plugins.

  Unlike `process_event_through_plugins/7`, this function focuses on event
  modification and can halt propagation. Plugins should implement `filter_event/2`.

  ## Parameters

    * `event` - The event to filter
    * `plugins` - Map of plugin_id => module
    * `metadata` - Plugin metadata (must include `:enabled` status)
    * `plugin_states` - Map of plugin_id => state
    * `load_order` - List of plugin IDs in processing order

  ## Returns

    * `{:ok, filtered_event}` - Event after all filters applied
    * `:halt` - Event propagation was stopped by a plugin
    * `{:error, reason}` - An error occurred

  ## Example

      case filter_event(event, plugins, metadata, states, load_order) do
        {:ok, event} -> dispatch_event(event)
        :halt -> :ok  # Event was consumed
        {:error, reason} -> log_error(reason)
      end

  """
  @spec filter_event(term(), map(), map(), map(), [atom()]) ::
          {:ok, term()} | :halt | {:error, term()}
  def filter_event(event, plugins, metadata, plugin_states, load_order) do
    sorted_plugins = sort_plugins_by_priority(load_order, metadata)

    Enum.reduce_while(sorted_plugins, {:ok, event}, fn plugin_id, {:ok, current_event} ->
      case filter_through_plugin(
             plugin_id,
             current_event,
             plugins,
             metadata,
             plugin_states
           ) do
        {:ok, filtered_event} ->
          {:cont, {:ok, filtered_event}}

        :halt ->
          {:halt, :halt}

        {:error, reason} ->
          # Log error but continue with other plugins
          Raxol.Core.Runtime.Log.warning(
            "Plugin #{plugin_id} filter error: #{inspect(reason)}, continuing with other plugins"
          )

          {:cont, {:ok, current_event}}
      end
    end)
  end

  @doc """
  Filters an event through a single plugin with isolation.

  Uses PluginSupervisor for crash isolation.
  """
  @spec filter_through_plugin(atom(), term(), map(), map(), map()) ::
          {:ok, term()} | :halt | {:error, term()}
  def filter_through_plugin(plugin_id, event, plugins, metadata, plugin_states) do
    with {:ok, module} <- get_plugin_module(plugins, plugin_id),
         {:ok, _} <- validate_plugin_enabled(metadata, plugin_id),
         {:ok, plugin_state} <- get_plugin_state(plugin_states, plugin_id),
         true <- function_exported?(module, :filter_event, 2) do
      run_filter(plugin_id, module, event, plugin_state)
    else
      false -> {:ok, event}
      {:error, :plugin_disabled} -> {:ok, event}
      {:error, _} = error -> error
    end
  end

  defp run_filter(plugin_id, module, event, plugin_state) do
    case PluginSupervisor.run_plugin_task(
           plugin_id,
           fn -> module.filter_event(event, plugin_state) end,
           timeout: 1_000
         ) do
      {:ok, {:ok, filtered}} ->
        {:ok, filtered}

      {:ok, :halt} ->
        :halt

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        log_filter_error(plugin_id, event, reason)
        {:ok, event}
    end
  end

  # ============================================================================
  # Plugin Ordering
  # ============================================================================

  @doc """
  Sorts plugins by priority for event processing.

  Plugins with explicit priority in metadata are sorted first (lower = higher priority).
  Plugins without priority retain their load order.
  """
  @spec sort_plugins_by_priority([atom()], map()) :: [atom()]
  def sort_plugins_by_priority(load_order, metadata) do
    Enum.sort_by(load_order, fn plugin_id ->
      case Map.get(metadata, plugin_id) do
        %{priority: priority} when is_integer(priority) -> priority
        # Default priority (low)
        _ -> 1000
      end
    end)
  end

  @doc """
  Gets the effective load order considering dependencies.

  Ensures that plugins are processed after their dependencies.
  """
  @spec get_dependency_ordered_plugins([atom()], map()) :: [atom()]
  def get_dependency_ordered_plugins(load_order, metadata) do
    # Build dependency graph
    deps_graph =
      Enum.reduce(load_order, %{}, fn plugin_id, acc ->
        deps =
          case Map.get(metadata, plugin_id) do
            %{dependencies: deps} when is_list(deps) -> deps
            _ -> []
          end

        Map.put(acc, plugin_id, deps)
      end)

    # Topological sort
    topological_sort(load_order, deps_graph)
  end

  defp topological_sort(plugins, deps_graph) do
    # Simple topological sort using Kahn's algorithm
    # Initialize in-degree counts
    in_degree = Enum.reduce(plugins, %{}, fn p, acc -> Map.put(acc, p, 0) end)

    in_degree =
      Enum.reduce(deps_graph, in_degree, fn {plugin, deps}, acc ->
        Enum.reduce(deps, acc, fn _dep, acc2 ->
          Map.update(acc2, plugin, 1, &(&1 + 1))
        end)
      end)

    # Find all plugins with no dependencies
    queue = Enum.filter(plugins, fn p -> Map.get(in_degree, p, 0) == 0 end)

    do_topological_sort(queue, [], in_degree, deps_graph, MapSet.new(plugins))
  end

  defp do_topological_sort([], result, _in_degree, _deps_graph, _remaining) do
    Enum.reverse(result)
  end

  defp do_topological_sort(
         [current | rest],
         result,
         in_degree,
         deps_graph,
         remaining
       ) do
    new_remaining = MapSet.delete(remaining, current)

    # Find plugins that depend on current
    dependents =
      deps_graph
      |> Enum.filter(fn {_plugin, deps} -> current in deps end)
      |> Enum.map(fn {plugin, _} -> plugin end)

    # Decrease in-degree for dependents
    {new_in_degree, new_ready} =
      Enum.reduce(dependents, {in_degree, []}, fn dep, {deg, ready} ->
        new_deg = Map.update!(deg, dep, &(&1 - 1))

        case Map.get(new_deg, dep) do
          0 -> {new_deg, [dep | ready]}
          _ -> {new_deg, ready}
        end
      end)

    do_topological_sort(
      rest ++ new_ready,
      [current | result],
      new_in_degree,
      deps_graph,
      new_remaining
    )
  end

  defp log_filter_error(plugin_id, event, reason) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Plugin filter failed",
      %{
        plugin_id: plugin_id,
        event_type: get_event_type(event),
        reason: reason,
        module: __MODULE__
      }
    )
  end

  defp get_event_type(%{type: type}), do: type
  defp get_event_type(_), do: :unknown
end
