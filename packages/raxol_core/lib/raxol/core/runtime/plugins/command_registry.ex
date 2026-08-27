defmodule Raxol.Core.Runtime.Plugins.CommandRegistry do
  @moduledoc """
  Manages command registration and execution for plugins.

  Commands are stored in a plain map keyed by namespace (module) with lists of
  `{name, {module, function, arity}, metadata}` tuples as values.
  """

  @type command_name :: String.t()
  @type command_handler :: (list(), map() -> term())
  @type command_metadata :: %{
          optional(:description) => String.t(),
          optional(:usage) => String.t(),
          optional(:aliases) => [String.t()],
          optional(:timeout) => pos_integer()
        }
  @type command_entry ::
          {command_name(), {module(), atom(), non_neg_integer()}, command_metadata()}
  @type command_table :: %{optional(module()) => [command_entry()]}

  @doc """
  Returns the default table name atom for ETS-backed registries.
  """
  @spec new() :: atom()
  def new, do: :command_registry_table

  @doc """
  Registers a command under a namespace in the command table.

  Returns the updated table map, or `{:error, :invalid_table}` if
  `table` is not a map.
  """
  @spec register_command(
          command_table() | term(),
          module(),
          String.t(),
          module(),
          atom(),
          non_neg_integer()
        ) ::
          command_table() | {:error, :invalid_table}
  def register_command(table, namespace, command_name, module, function, arity)
      when is_map(table) do
    entry = {command_name, {module, function, arity}, %{}}
    existing = Map.get(table, namespace, [])
    Map.put(table, namespace, [entry | existing])
  end

  def register_command(
        _not_a_map,
        _namespace,
        _command_name,
        _module,
        _function,
        _arity
      ) do
    {:error, :invalid_table}
  end

  @doc """
  Removes a single command from a namespace. Returns the updated table,
  or the input unchanged if `table` is not a map.
  """
  @spec unregister_command(command_table() | term(), module(), String.t()) ::
          command_table() | term()
  def unregister_command(table, namespace, command_name) when is_map(table) do
    commands = Map.get(table, namespace, [])
    updated = Enum.reject(commands, fn {name, _, _} -> name == command_name end)
    Map.put(table, namespace, updated)
  end

  def unregister_command(table, _namespace, _command_name), do: table

  @doc """
  Looks up a command by namespace and name. Returns a handler function
  wrapping `apply(module, function, ...)`.
  """
  @spec lookup_command(command_table() | term(), module(), String.t()) ::
          {:ok, {module(), command_handler(), non_neg_integer()}}
          | {:error, :not_found | :invalid_table}
  def lookup_command(table, namespace, command_name) when is_map(table) do
    table
    |> Map.get(namespace, [])
    |> find_and_create_handler(command_name)
  end

  def lookup_command(_not_a_map, _namespace, _command_name),
    do: {:error, :invalid_table}

  @doc """
  Removes all commands for a module from the table.
  """
  @spec unregister_commands_by_module(command_table() | term(), module()) ::
          command_table() | term()
  def unregister_commands_by_module(table, module) when is_map(table) do
    Map.delete(table, module)
  end

  def unregister_commands_by_module(table, _module), do: table

  @doc """
  Registers commands from a plugin module's `commands/0` callback.

  Validates handlers and metadata, checks for name conflicts against
  existing commands in the table.
  """
  @spec register_plugin_commands(module(), map(), command_table()) ::
          {:ok, command_table()} | {:error, term()}
  def register_plugin_commands(plugin_module, plugin_state, command_table) do
    with {:ok, commands} <- get_plugin_commands(plugin_module),
         :ok <- validate_commands(commands),
         :ok <- check_command_conflicts(commands, command_table) do
      register_commands(commands, plugin_module, plugin_state, command_table)
    end
  end

  @doc """
  Unregisters all commands for a plugin module.
  """
  @spec unregister_plugin_commands(module(), command_table()) ::
          {:ok, command_table()} | :ok
  def unregister_plugin_commands(plugin_module, command_table) do
    case Map.get(command_table, plugin_module) do
      nil -> :ok
      _commands -> {:ok, Map.delete(command_table, plugin_module)}
    end
  end

  @doc """
  Finds and executes a command by name with timeout support.
  """
  @spec execute_command(String.t(), list(), command_table()) ::
          term() | {:error, term()}
  def execute_command(command_name, args, command_table) do
    case find_command(command_name, command_table) do
      {:ok, {handler, metadata}} ->
        execute_with_timeout(handler, args, metadata)

      {:error, reason} = error ->
        Raxol.Core.Runtime.Log.error(
          "Failed to execute command #{command_name}: #{inspect(reason)}"
        )

        error
    end
  end

  @doc """
  Searches all namespaces for a command by name.
  """
  @spec find_command(String.t(), command_table()) ::
          {:ok, {term(), command_metadata()}} | {:error, :not_found}
  def find_command(command_name, command_table) do
    Enum.find_value(command_table, {:error, :not_found}, fn {_namespace, commands} ->
      find_in_namespace(commands, command_name)
    end)
  end

  defp find_in_namespace(commands, command_name) do
    case Enum.find(commands, fn {name, _, _} -> name == command_name end) do
      nil -> nil
      {_name, handler, metadata} -> {:ok, {handler, metadata}}
    end
  end

  # --- Private ---

  defp check_command_conflicts(commands, command_table) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      name = extract_command_name(command)

      if command_exists?(name, command_table) do
        {:halt, {:error, {:command_exists, name}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp extract_command_name(%{name: name}), do: name
  defp extract_command_name({name, _, _}), do: name

  defp command_exists?(name, command_table) do
    Enum.any?(command_table, fn {_, commands} ->
      Enum.any?(commands, fn {cmd_name, _, _} -> cmd_name == name end)
    end)
  end

  defp register_commands(commands, plugin_module, plugin_state, command_table) do
    new_commands =
      Enum.map(commands, fn command ->
        {name, handler, metadata} = extract_command_parts(command)
        {name, wrap_handler(handler, plugin_state), metadata}
      end)

    {:ok, Map.put(command_table, plugin_module, new_commands)}
  end

  defp extract_command_parts(%{
         name: name,
         handler: handler,
         metadata: metadata
       }),
       do: {name, handler, metadata}

  defp extract_command_parts(%{name: name, handler: handler}),
    do: {name, handler, %{}}

  defp extract_command_parts({name, handler, metadata}),
    do: {name, handler, metadata}

  defp wrap_handler(handler, plugin_state) do
    fn args, context ->
      handler.(args, Map.put(context, :plugin_state, plugin_state))
    end
  end

  defp get_plugin_commands(plugin_module) do
    case plugin_module.commands() do
      commands when is_list(commands) -> {:ok, commands}
      _ -> {:error, :invalid_commands}
    end
  end

  defp validate_commands(commands) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case validate_command(command) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_command(command) do
    with :ok <- validate_command_handler(command.handler) do
      validate_command_metadata(command.metadata)
    end
  end

  defp validate_command_handler(handler) when is_function(handler, 2), do: :ok
  defp validate_command_handler(_), do: {:error, :invalid_command_handler}

  defp validate_command_metadata(metadata) when is_map(metadata) do
    if valid_metadata_fields?(metadata),
      do: :ok,
      else: {:error, :invalid_metadata_fields}
  end

  defp validate_command_metadata(_), do: {:error, :invalid_metadata_fields}

  defp valid_metadata_fields?(metadata) do
    Enum.all?(metadata, fn
      {:description, value} -> is_binary(value)
      {:usage, value} -> is_binary(value)
      {:aliases, value} -> is_list(value) and Enum.all?(value, &is_binary/1)
      {:timeout, value} -> is_integer(value) and value > 0
      _ -> false
    end)
  end

  defp execute_with_timeout(handler, args, metadata) do
    timeout = Map.get(metadata, :timeout, 5000)

    context = %{
      timestamp: System.system_time(),
      metadata: metadata
    }

    task = Task.async(fn -> handler.(args, context) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      nil ->
        {:error, :command_timeout}

      {:exit, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "Command execution failed in Task",
          reason,
          nil,
          %{args: args, module: __MODULE__}
        )

        {:error, {:execution_failed, format_error_message(reason)}}
    end
  end

  defp format_error_message(reason) when is_binary(reason), do: reason
  defp format_error_message(%{message: msg}), do: msg
  defp format_error_message({:timeout, _}), do: "Command execution timeout"
  defp format_error_message(reason), do: inspect(reason)

  defp find_and_create_handler(commands, command_name) do
    case Enum.find(commands, fn {name, _, _} -> name == command_name end) do
      nil ->
        {:error, :not_found}

      {_name, {module, function, arity}, _metadata} ->
        handler = fn args, state -> apply(module, function, [args, state]) end
        {:ok, {module, handler, arity}}
    end
  end
end
