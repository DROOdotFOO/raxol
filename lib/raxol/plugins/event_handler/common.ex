defmodule Raxol.Plugins.EventHandler.Common do
  @moduledoc """
  Common utilities and helper functions for event handling across plugins.
  """


  alias Raxol.Plugins.Lifecycle.Dependencies
  alias Raxol.Plugins.Manager

  @type event :: map()
  @type plugin :: map()
  @type manager :: Manager.t()
  @type accumulator :: map()
  @type callback_name :: atom()
  @type result_handler_fun :: fun()

  @doc """
  Generic dispatcher that reduces over plugins and calls a specific handler function.
  """
  @spec dispatch_event(
          map(),
          callback_name(),
          list(),
          non_neg_integer(),
          accumulator(),
          result_handler_fun()
        ) :: accumulator() | {:error, term()}
  def dispatch_event(
        manager,
        callback_name,
        args,
        required_arity,
        initial_acc,
        result_handler
      ) do
    Enum.reduce_while(manager.plugins, initial_acc, fn {_key, plugin}, acc ->
      handle_plugin_event(
        plugin,
        callback_name,
        args,
        required_arity,
        acc,
        result_handler
      )
    end)
  end

  @doc """
  Handles calling a specific callback on a plugin and processing the result.
  """
  @spec handle_plugin_event(
          plugin(),
          callback_name(),
          list(),
          non_neg_integer(),
          accumulator(),
          result_handler_fun()
        ) :: {:cont, accumulator()} | {:halt, accumulator()}
  def handle_plugin_event(
        plugin,
        callback_name,
        args,
        required_arity,
        acc,
        result_handler
      ) do
    with :ok <- validate_plugin_map(plugin),
         :ok <- validate_plugin_enabled(plugin),
         :ok <- validate_plugin_callback(plugin, callback_name, required_arity) do
      execute_plugin_callback(plugin, callback_name, args, acc, result_handler)
    else
      {:error, :invalid_plugin} ->
        log_invalid_plugin(plugin)
        {:cont, acc}

      _other ->
        {:cont, acc}
    end
  end

  @doc """
  Updates the manager state with a new plugin state.
  """
  @spec update_manager_state(map(), plugin(), map()) :: map()
  def update_manager_state(manager, plugin, new_plugin_state) do
    plugin_name = Dependencies.normalize_plugin_key(plugin.name)

    %{
      manager
      | plugin_states:
          Map.put(manager.plugin_states, plugin_name, new_plugin_state)
    }
  end

  @doc """
  Updates a plugin instance in the manager.
  """
  @spec update_manager_plugin(map(), plugin(), plugin()) :: map()
  def update_manager_plugin(manager, _old_plugin, updated_plugin) do
    plugin_name = Dependencies.normalize_plugin_key(updated_plugin.name)

    %{
      manager
      | plugins: Map.put(manager.plugins, plugin_name, updated_plugin),
        loaded_plugins:
          Map.put(manager.loaded_plugins, plugin_name, updated_plugin)
    }
  end

  @doc """
  Extracts plugin state from a plugin struct.
  """
  @spec extract_plugin_state(plugin()) :: map()
  def extract_plugin_state(%{state: state}), do: state
  def extract_plugin_state(%{plugin_state: state}), do: state
  def extract_plugin_state(plugin) when is_map(plugin), do: %{}

  def extract_plugin_state(_), do: %{}

  # Helper functions for plugin validation
  defp validate_plugin_map(plugin) when not is_map(plugin),
    do: {:error, :invalid_plugin}

  defp validate_plugin_map(_plugin), do: :ok

  defp validate_plugin_enabled(%{enabled: true}), do: :ok

  defp validate_plugin_enabled(plugin) do
    case Map.get(plugin, :enabled, false) do
      true -> :ok
      false -> {:error, :disabled}
    end
  end

  defp validate_plugin_callback(plugin, callback_name, required_arity) do
    case has_required_callback?(plugin, callback_name, required_arity) do
      true -> :ok
      false -> {:error, :missing_callback}
    end
  end

  defp execute_plugin_callback(plugin, callback_name, args, acc, result_handler) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           # Get the plugin from the manager
           plugin_instance = Manager.get_plugin(acc.manager, plugin.name)
           # Prepend the plugin instance to the args
           full_args = [plugin_instance | args]
           result = apply(plugin.module, callback_name, full_args)
           result_handler.(acc, plugin, callback_name, result)
         end) do
      {:ok, result} ->
        result

      {:error, error} ->
        log_plugin_crash(plugin, callback_name, error)
        {:cont, acc}
    end
  end

  @doc """
  Logs an error from a plugin.
  """
  @spec log_plugin_error(plugin(), callback_name(), term()) :: :ok
  def log_plugin_error(plugin, callback_name, reason) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Plugin #{plugin.name} failed in #{callback_name}",
      %{
        plugin: plugin.name,
        callback: callback_name,
        reason: inspect(reason),
        module: __MODULE__
      }
    )
  end

  @doc """
  Logs an unexpected result from a plugin.
  """
  @spec log_unexpected_result(plugin(), callback_name(), term()) :: :ok
  def log_unexpected_result(plugin, callback_name, result) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Plugin #{plugin.name} returned unexpected result from #{callback_name}",
      %{
        plugin: plugin.name,
        callback: callback_name,
        result: inspect(result),
        module: __MODULE__
      }
    )
  end

  # Private helper functions

  defp has_required_callback?(plugin, callback_name, required_arity) do
    case plugin.module do
      nil ->
        false

      module when is_atom(module) ->
        function_exported?(module, callback_name, required_arity)

      _ ->
        false
    end
  end

  defp log_invalid_plugin(plugin) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Invalid plugin structure encountered",
      %{
        plugin: inspect(plugin),
        module: __MODULE__
      }
    )
  end

  defp log_plugin_crash(plugin, callback_name, error) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "Plugin #{plugin.name} crashed in #{callback_name}",
      error,
      nil,
      %{
        plugin: plugin.name,
        callback: callback_name,
        module: __MODULE__
      }
    )
  end
end
