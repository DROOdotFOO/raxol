defmodule Raxol.Core.Runtime.Plugins.CommandHelper do
  @moduledoc """
  Handles plugin command registration and dispatch for the Plugin Manager.
  """

  alias Raxol.Core.Runtime.Plugins.CommandRegistry

  @doc """
  Finds a command handler in the command table, normalizing the command name.
  """
  @spec find_plugin_for_command(
          map(),
          atom() | String.t(),
          module() | nil,
          non_neg_integer()
        ) ::
          {:ok, {module(), atom(), non_neg_integer()}} | :not_found
  def find_plugin_for_command(command_table, command_name, namespace, _arity) do
    processed_name =
      command_name
      |> to_string()
      |> String.trim()
      |> String.downcase()

    namespace_module = process_namespace(namespace)

    case CommandRegistry.lookup_command(
           command_table,
           namespace_module,
           processed_name
         ) do
      {:ok, {module, _handler, arity}} ->
        {:ok, {module, :handle_command, arity}}

      {:error, :not_found} ->
        :not_found
    end
  end

  @doc """
  Registers commands from a plugin module's `get_commands/0` callback.
  Returns the updated command table.
  """
  @spec register_plugin_commands(module(), map(), map()) :: map()
  def register_plugin_commands(plugin_module, _plugin_state, command_table) do
    if function_exported?(plugin_module, :get_commands, 0) do
      case safe_get_commands(plugin_module) do
        {:ok, commands} ->
          process_commands(plugin_module, commands, command_table)

        {:error, error} ->
          Raxol.Core.Runtime.Log.error_with_stacktrace(
            "Error calling get_commands/0 on #{inspect(plugin_module)}: #{inspect(error)}",
            error,
            nil
          )

          command_table
      end
    else
      command_table
    end
  end

  @doc """
  Dispatches a command, looking it up in the table and executing the handler.
  """
  @spec handle_command(map(), String.t(), module() | nil, list() | nil, map()) ::
          {:ok, map()} | {:error, atom()} | {:error, atom(), map()}
  def handle_command(command_table, command_name_str, _namespace, args, state) do
    with {:ok, {plugin_module, handler, _arity}} <-
           lookup_valid_command(command_table, command_name_str, args),
         {:ok, plugin_id, plugin_state} <-
           get_plugin_state(state, plugin_module),
         {:ok, new_state, _result, plugin_id} <-
           execute_and_update_state(handler, args, plugin_state, plugin_id) do
      {:ok, Map.put(state.plugin_states, plugin_id, new_state)}
    else
      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :invalid_args} ->
        {:error, :invalid_args, state.plugin_states}

      {:error, :missing_plugin_state} ->
        {:error, :missing_plugin_state, state.plugin_states}

      {:error, :exception, new_state, plugin_id} ->
        {:error, :exception, Map.put(state.plugin_states, plugin_id, new_state)}

      {:error, reason, new_state, plugin_id} ->
        {:error, reason, Map.put(state.plugin_states, plugin_id, new_state)}
    end
  end

  @doc """
  Removes all commands for a module from the command table.
  """
  @spec unregister_plugin_commands(map(), module()) :: map()
  def unregister_plugin_commands(command_table, plugin_module) do
    Raxol.Core.Runtime.Log.debug("Unregistering commands for module: #{inspect(plugin_module)}")

    CommandRegistry.unregister_commands_by_module(command_table, plugin_module)
  end

  @doc """
  Finds the plugin ID for a given module in the plugins map.
  """
  @spec find_plugin_id_by_module(map(), module()) :: String.t() | nil
  def find_plugin_id_by_module(plugins, module) do
    Enum.find_value(plugins, fn {id, mod} -> if mod == module, do: id end)
  end

  @doc """
  Validates that command arguments are a list of strings or numbers.
  """
  @spec validate_command_args(term()) :: :ok | {:error, :invalid_args}
  def validate_command_args(args) when is_list(args) do
    if Enum.all?(args, &(is_binary(&1) or is_number(&1))) do
      :ok
    else
      {:error, :invalid_args}
    end
  end

  def validate_command_args(_), do: {:error, :invalid_args}

  # --- Private ---

  @spec process_namespace(atom()) :: atom()
  defp process_namespace(namespace) when is_atom(namespace), do: namespace

  @spec process_namespace(String.t()) :: atom() | nil
  defp process_namespace(namespace) when is_binary(namespace) do
    String.to_existing_atom(namespace)
  rescue
    ArgumentError ->
      Raxol.Core.Runtime.Log.debug("Namespace string could not be converted to an existing atom.")

      nil
  end

  @spec process_namespace(term()) :: nil
  defp process_namespace(_), do: nil

  defp safe_get_commands(plugin_module) do
    task = Task.async(fn -> {:ok, plugin_module.get_commands()} end)

    case Task.yield(task, 5000) || Task.shutdown(task) do
      {:ok, result} -> result
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  defp process_commands(plugin_module, commands, command_table)
       when is_list(commands) do
    Enum.reduce(
      commands,
      command_table,
      &register_command(plugin_module, &1, &2)
    )
  end

  defp register_command(plugin_module, {name, function, arity}, acc)
       when is_atom(name) and is_atom(function) and is_integer(arity) and
              arity >= 0 do
    name_str = name |> Atom.to_string() |> String.trim() |> String.downcase()

    if valid_command_name?(name_str) and
         function_exported?(plugin_module, function, arity) do
      CommandRegistry.register_command(
        acc,
        plugin_module,
        name_str,
        plugin_module,
        function,
        arity
      )
    else
      Raxol.Core.Runtime.Log.warning_with_context(
        "Plugin #{inspect(plugin_module)} does not export #{function}/#{arity} for command #{inspect(name_str)}. Skipping registration.",
        context: __MODULE__,
        stacktrace: nil
      )

      acc
    end
  end

  defp register_command(_plugin_module, _invalid, acc), do: acc

  defp valid_command_name?(name_str) do
    String.match?(name_str, ~r/^[a-zA-Z0-9_-]+$/)
  end

  defp lookup_valid_command(command_table, command_name_str, args) do
    case validate_command_args(args) do
      :ok -> find_command_in_table(command_table, command_name_str)
      {:error, :invalid_args} -> {:error, :invalid_args}
    end
  end

  defp find_command_in_table(command_table, command_name_str) do
    Enum.find_value(command_table, {:error, :not_found}, fn {_namespace, commands} ->
      build_handler_for(commands, command_name_str)
    end)
  end

  defp build_handler_for(commands, command_name_str) do
    case Enum.find(commands, fn {name, _, _} -> name == command_name_str end) do
      nil ->
        nil

      {_name, {module, function, arity}, _metadata} ->
        handler = fn args, state -> apply(module, function, [args, state]) end
        {:ok, {module, handler, arity}}
    end
  end

  defp get_plugin_state(state, plugin_module) do
    case find_plugin_id_by_module(state.plugins, plugin_module) do
      nil ->
        {:error, :missing_plugin_state}

      plugin_id ->
        case Map.get(state.plugin_states, plugin_id) do
          nil -> {:error, :missing_plugin_state}
          plugin_state -> {:ok, plugin_id, plugin_state}
        end
    end
  end

  defp execute_and_update_state(handler, args, plugin_state, plugin_id) do
    case execute_command(handler, args, plugin_state) do
      {:ok, new_state, result} ->
        {:ok, new_state, result, plugin_id}

      {:error, :exception, new_state} ->
        {:error, :exception, new_state, plugin_id}

      {:error, reason, new_state} ->
        {:error, reason, new_state, plugin_id}
    end
  end

  defp execute_command(handler, args, plugin_state) do
    caller = self()
    tag = make_ref()

    {pid, monitor_ref} =
      spawn_monitor(fn ->
        send(caller, {tag, handler.(args, plugin_state)})
      end)

    receive do
      {^tag, {:ok, new_state, result}} when is_map(new_state) ->
        Process.demonitor(monitor_ref, [:flush])
        {:ok, new_state, result}

      {^tag, {:error, reason, new_state}} when is_map(new_state) ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, reason, new_state}

      {^tag, other} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:unexpected_plugin_return, other}, plugin_state}

      {:DOWN, ^monitor_ref, :process, ^pid, _reason} ->
        {:error, :exception, plugin_state}
    after
      5000 ->
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(pid, :kill)
        {:error, :timeout}
    end
  end
end
