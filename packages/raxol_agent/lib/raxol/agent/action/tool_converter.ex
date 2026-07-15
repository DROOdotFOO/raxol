defmodule Raxol.Agent.Action.ToolConverter do
  @moduledoc """
  Converts Action modules to LLM tool definitions and dispatches tool calls.

  Use `to_tool_definitions/1` to generate the `tools` parameter for
  OpenAI/Anthropic API calls, then `dispatch_tool_call/3` to route
  the LLM's tool call response back to the matching Action module.
  """

  alias Raxol.Agent.ToolCall.Hook
  alias Raxol.Agent.ToolPolicy

  @doc """
  Convert action modules to tool definitions for LLM API calls.

  Returns a list of JSON Schema function tool definitions.
  """
  @spec to_tool_definitions([module()]) :: [map()]
  def to_tool_definitions(action_modules) when is_list(action_modules) do
    Enum.map(action_modules, fn module ->
      module.to_tool_definition()
    end)
  end

  # Max nesting depth for LLM-supplied argument maps
  @max_arg_depth 4
  # Max total keys across all nesting levels
  @max_arg_keys 64
  # Max byte size for string argument values
  @max_arg_value_bytes 10_000

  @doc """
  Dispatch an LLM tool call to the matching action module.

  The `tool_call` map should have `"name"` and `"arguments"` keys
  (standard OpenAI/Anthropic function calling format). Arguments can
  be a string (JSON) or a pre-parsed map with string keys.

  Validates argument depth, key count, and value sizes before dispatch
  to prevent resource exhaustion from malformed LLM output.

  Dispatch order: find action -> parse arguments -> validate limits ->
  `:tool_authorizer` (see `Raxol.Agent.ToolPolicy`) -> `:tool_call_hooks`
  pipeline (see `Raxol.Agent.ToolCall.Hook`) -> `Action.call/2`. A hook veto
  returns `{:error, {:vetoed, reason}}` without invoking the Action.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @type effect :: Raxol.Agent.Directive.t()

  @spec dispatch_tool_call(map(), [module()], map()) ::
          {:ok, map()} | {:ok, map(), [effect()]} | {:error, term()}
  def dispatch_tool_call(tool_call, action_modules, context \\ %{}) do
    name = Map.get(tool_call, "name") || Map.get(tool_call, :name)
    raw_args = Map.get(tool_call, "arguments") || Map.get(tool_call, :arguments, %{})

    with {:ok, module} <- find_action(name, action_modules),
         {:ok, params} <- parse_arguments(raw_args, module),
         :ok <- validate_arg_limits(params),
         :ok <- authorize_tool(module, params, context) do
      run_hooked(module, name, params, tool_call, context)
    end
  end

  # Execution chokepoint: every LLM tool call passes through here. The
  # `:tool_call_hooks` pipeline (Raxol.Agent.ToolCall.Hook) runs immediately
  # before the Action -- hooks may transform the call or veto it. Zero
  # registered hooks takes the fast path (behavior unchanged).
  defp run_hooked(module, name, params, tool_call, context) do
    case Hook.from_context(context) do
      [] ->
        module.call(params, context)

      hooks ->
        call = %{
          action: module,
          name: name,
          params: params,
          call_id: Map.get(tool_call, "id") || Map.get(tool_call, :id)
        }

        case Hook.run_before(hooks, call, context) do
          {:cont, final_call} ->
            result = final_call.action.call(final_call.params, context)
            Hook.run_after(hooks, final_call, result, context)

          {:halt, reason} ->
            {:error, {:vetoed, reason}}
        end
    end
  end

  # Security gate: consult a `(module, params, context) -> :ok | {:deny, reason}`
  # authorizer before running the Action so a prompt-injected LLM cannot invoke
  # a sensitive tool. When the context sets `:tool_authorizer`, use it; otherwise
  # apply the default policy, which denies Actions marked `sensitive: true`
  # (fund-movers) while allowing read-only tools. Set a `:tool_authorizer` to
  # override (e.g. `ToolPolicy.allow_all/0` for a trusted operator). See
  # `Raxol.Agent.ToolPolicy`.
  defp authorize_tool(module, params, %{tool_authorizer: fun} = context)
       when is_function(fun, 3) do
    run_authorizer(fun, module, params, context)
  end

  defp authorize_tool(module, params, context) do
    run_authorizer(ToolPolicy.deny_sensitive(), module, params, context)
  end

  defp run_authorizer(fun, module, params, context) do
    case fun.(module, params, context) do
      :ok -> :ok
      {:deny, reason} -> {:error, {:tool_denied, module.__action_meta__().name, reason}}
    end
  end

  @doc """
  Build a tool result message for feeding back to the LLM.

  Encodes the result as a JSON string suitable for the `tool` role message.
  """
  @spec format_tool_result(String.t(), map()) :: map()
  def format_tool_result(tool_call_id, result) when is_map(result) do
    %{
      role: "tool",
      tool_call_id: tool_call_id,
      content: Jason.encode!(result)
    }
  end

  # -- Private ---------------------------------------------------------------

  defp find_action(name, action_modules) do
    case Enum.find(action_modules, fn mod -> mod.__action_meta__().name == name end) do
      nil -> {:error, {:unknown_tool, name}}
      module -> {:ok, module}
    end
  end

  defp parse_arguments(args, _action_module) when is_map(args) do
    {:ok, atomize_keys(args)}
  end

  defp parse_arguments(args, _action_module) when is_binary(args) do
    case Jason.decode(args) do
      {:ok, map} when is_map(map) -> {:ok, atomize_keys(map)}
      {:ok, _} -> {:error, :arguments_not_object}
      {:error, _} = err -> err
    end
  end

  defp parse_arguments(_args, _action_module), do: {:ok, %{}}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {k, v} when is_binary(k) -> {safe_to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp safe_to_existing_atom(str) do
    String.to_existing_atom(str)
  rescue
    ArgumentError -> str
  end

  defp validate_arg_limits(params) when is_map(params) do
    case check_depth_and_size(params, 0, 0) do
      {:ok, _key_count} -> :ok
      {:error, _} = err -> err
    end
  end

  defp check_depth_and_size(_value, depth, _keys) when depth > @max_arg_depth do
    {:error, :arguments_too_deep}
  end

  defp check_depth_and_size(map, depth, keys) when is_map(map) do
    new_keys = keys + map_size(map)
    if new_keys > @max_arg_keys, do: throw({:error, :too_many_argument_keys})

    Enum.reduce_while(map, {:ok, new_keys}, fn {_k, v}, {:ok, acc_keys} ->
      case check_depth_and_size(v, depth + 1, acc_keys) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  catch
    {:error, _} = err -> err
  end

  defp check_depth_and_size(list, depth, keys) when is_list(list) do
    Enum.reduce_while(list, {:ok, keys}, fn v, {:ok, acc_keys} ->
      case check_depth_and_size(v, depth + 1, acc_keys) do
        {:ok, updated} -> {:cont, {:ok, updated}}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp check_depth_and_size(str, _depth, keys) when is_binary(str) do
    if byte_size(str) > @max_arg_value_bytes do
      {:error, :argument_value_too_large}
    else
      {:ok, keys}
    end
  end

  defp check_depth_and_size(_value, _depth, keys), do: {:ok, keys}
end
