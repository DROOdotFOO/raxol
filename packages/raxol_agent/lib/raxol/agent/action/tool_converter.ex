defmodule Raxol.Agent.Action.ToolConverter do
  require Logger

  @moduledoc """
  Converts Action modules to LLM tool definitions and dispatches tool calls.

  Use `to_tool_definitions/1` to generate the `tools` parameter for
  OpenAI/Anthropic API calls, then `dispatch_tool_call/3` to route
  the LLM's tool call response back to the matching Action module.
  """

  alias Raxol.Agent.Action.Dynamic
  alias Raxol.Agent.ToolCall.Hook
  alias Raxol.Agent.ToolPolicy

  @typedoc """
  A tool the loop can offer and dispatch: an Action module, or a
  `Raxol.Agent.Action.Dynamic` (a runtime-discovered tool, e.g. an MCP tool).
  """
  @type tool :: module() | Dynamic.t()

  @doc """
  Convert tools (Action modules and/or `Dynamic` tools) to LLM tool definitions.

  Returns a list of JSON Schema function tool definitions.
  """
  @spec to_tool_definitions([tool()]) :: [map()]
  def to_tool_definitions(tools) when is_list(tools) do
    Enum.map(tools, &tool_definition/1)
  end

  defp tool_definition(%Dynamic{} = tool), do: Dynamic.to_tool_definition(tool)
  defp tool_definition(module) when is_atom(module), do: module.to_tool_definition()

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
  returns `{:error, {:vetoed, reason}}` without invoking the Action. A hook
  contract violation (an invalid `before_call/2` return shape) returns
  `{:error, {:hook_error, reason}}`, distinct from a veto. Re-authorization
  runs whenever a hook transforms the `(action, params)` pair that is about
  to execute -- either the action module or the params (or both) differ from
  what was originally authorized -- so a hook cannot smuggle a param
  escalation (e.g. a fund-mover's amount) or a swapped action past the
  policy that guarded the original call (a denial returns `{:error,
  {:tool_denied, ...}}` and the transformed call never executes). A hook
  rewriting `:action` to a module outside the declared `action_modules` set
  is rejected with `{:error, {:tool_not_in_toolset, module}}`, and a rewrite
  to a module that isn't callable (does not export `call/2`) is rejected
  with `{:error, {:invalid_action, module}}` -- both checked before the
  authorizer even runs. Argument-limit validation (depth/keys/value size)
  also re-runs against a hook-transformed `params`, so a hook cannot inflate
  params past the ceiling the pre-hook check enforces; a violation returns
  the same `{:error, reason}` shape as the pre-hook check.

  Returns `{:ok, result}` or `{:error, reason}`.
  """
  @type effect :: Raxol.Agent.Directive.t()

  @spec dispatch_tool_call(map(), [tool()], map()) ::
          {:ok, map()} | {:ok, map(), [effect()]} | {:error, term()}
  def dispatch_tool_call(tool_call, tools, context \\ %{}) do
    name = Map.get(tool_call, "name") || Map.get(tool_call, :name)
    raw_args = Map.get(tool_call, "arguments") || Map.get(tool_call, :arguments, %{})

    with {:ok, tool} <- find_action(name, tools),
         {:ok, params} <- parse_arguments(raw_args, tool),
         :ok <- validate_arg_limits(params),
         :ok <- authorize_tool(tool, params, context) do
      run_hooked(tool, params, name, tool_call, tools, context)
    end
  end

  # Execution chokepoint: every LLM-initiated tool call passes through here
  # (the internal Pipeline/Direct/run_action* paths call Action.call/2 directly
  # but are agent-internal, never LLM-reachable). The `:tool_call_hooks`
  # pipeline (Raxol.Agent.ToolCall.Hook) runs immediately before the Action --
  # hooks may transform the call or veto it. Zero registered hooks takes the
  # fast path (behavior unchanged).
  defp run_hooked(tool, params, name, tool_call, tools, context) do
    case Hook.from_context(context) do
      [] ->
        invoke(tool, params, context)

      hooks ->
        call = %{
          action: tool,
          name: name,
          params: params,
          call_id: Map.get(tool_call, "id") || Map.get(tool_call, :id)
        }

        case Hook.run_before(hooks, call, context) do
          {:cont, final_call} ->
            run_authorized_call(tool, params, final_call, tools, context, hooks)

          {:halt, reason} ->
            {:error, {:vetoed, reason}}

          {:error, reason} ->
            Logger.error(fn -> "tool-call hook contract violation: #{inspect(reason)}" end)
            {:error, {:hook_error, reason}}
        end
    end
  end

  # A before_call hook may rewrite the call's `:action` and/or `:params`.
  # Four gates run on whatever `(action, params)` pair is actually about to
  # execute, in order:
  #
  #   1. `ensure_in_toolset/3` -- a swapped action must be a member of the
  #      declared `action_modules` set (checked first, so an out-of-set
  #      module never reaches `run_authorizer`, which calls
  #      `module.__action_meta__()` and would raise on a non-Action module).
  #   2. `assert_callable/1` -- the executing action must export `call/2`.
  #      `Hook.run_before/3` already rejects a non-atom `:action` as an
  #      invalid hook return, but an atom that passes toolset membership and
  #      is nonetheless not a callable Action (e.g. a module with no `call/2`)
  #      must not reach `action.call(...)` uncontained -- that would raise
  #      `UndefinedFunctionError` outside any rescue/catch and crash the
  #      (untrapped) react loop.
  #   3. `validate_arg_limits/1` -- re-checked against the (possibly
  #      hook-transformed) `params`, not just the original pre-hook params, so
  #      a hook cannot inflate params past the depth/key/size ceiling the
  #      pre-hook check exists to enforce.
  #   4. `reauthorize_if_transformed/5` -- re-runs the tool authorizer
  #      against the executing `(action, params)` pair unless it is
  #      byte-identical to what was already authorized pre-hook. This closes
  #      the param-escalation gap: a hook that keeps the same action but
  #      rewrites e.g. a transfer amount is re-authorized against the new
  #      amount, not cheap-skipped on action identity alone (U8 fund-movement
  #      approval builds on this).
  defp run_authorized_call(
         orig_tool,
         orig_params,
         %{action: action, params: params} = final_call,
         tools,
         context,
         hooks
       ) do
    with :ok <- ensure_in_toolset(orig_tool, action, tools),
         :ok <- assert_callable(action),
         :ok <- validate_arg_limits(params),
         :ok <- reauthorize_if_transformed(orig_tool, orig_params, action, params, context) do
      result = invoke(action, params, context)
      Hook.run_after(hooks, final_call, result, context)
    end
  end

  # The original module came from find_action/2, so it is in-set by
  # construction (repeated var = unchanged action -> skip). A swap must be a
  # member of the declared set.
  defp ensure_in_toolset(same, same, _tools), do: :ok

  defp ensure_in_toolset(_orig, new_tool, tools) do
    if new_tool in tools,
      do: :ok,
      else: {:error, {:tool_not_in_toolset, new_tool}}
  end

  defp assert_callable(%Dynamic{invoke: fun}) when is_function(fun, 2), do: :ok
  defp assert_callable(%Dynamic{}), do: {:error, {:invalid_action, :dynamic}}

  defp assert_callable(action) when is_atom(action) do
    if function_exported?(action, :call, 2),
      do: :ok,
      else: {:error, {:invalid_action, action}}
  end

  defp assert_callable(_other), do: {:error, {:invalid_action, :not_callable}}

  # Cheap-skip ONLY when the whole (action, params) pair is byte-identical to
  # what the pre-hook authorize_tool already cleared (repeated vars = equality).
  defp reauthorize_if_transformed(mod, params, mod, params, _context), do: :ok

  # Action OR params changed -> re-authorize the pair actually about to execute.
  defp reauthorize_if_transformed(_orig_mod, _orig_params, new_module, new_params, context),
    do: authorize_tool(new_module, new_params, context)

  # Security gate: consult a `(module, params, context) -> :ok | {:deny, reason}`
  # authorizer before running the Action so a prompt-injected LLM cannot invoke
  # a sensitive tool. When the context sets `:tool_authorizer`, use it; otherwise
  # apply the default policy, which denies Actions marked `sensitive: true`
  # (fund-movers) while allowing read-only tools. Set a `:tool_authorizer` to
  # override (e.g. `ToolPolicy.allow_all/0` for a trusted operator). See
  # `Raxol.Agent.ToolPolicy`.
  defp authorize_tool(tool, params, %{tool_authorizer: fun} = context)
       when is_function(fun, 3) do
    run_authorizer(fun, tool, params, context)
  end

  defp authorize_tool(tool, params, context) do
    run_authorizer(ToolPolicy.deny_sensitive(), tool, params, context)
  end

  defp run_authorizer(fun, tool, params, context) do
    case fun.(tool, params, context) do
      :ok -> :ok
      {:deny, reason} -> {:error, {:tool_denied, tool_name(tool), reason}}
    end
  end

  @doc """
  Stable, secret-free category string for an LLM-facing tool error.

  A hook, authorizer, or exception can supply arbitrary detail (wallet
  addresses, balances, internal messages) as the `reason` term. That detail
  must never reach the LLM prompt -- only a bounded, developer-authored
  category may. Callers that need the raw detail (logging, tests,
  programmatic error handling) should match on the `{:error, reason}` tuple
  directly; this function is only for the string fed back to the model.
  """
  @spec public_error(String.t(), term()) :: String.t()
  def public_error(name, {:vetoed, {:hook_raised, _hook, _msg}}),
    do: "[Tool error for #{name}]: blocked by policy (hook error)"

  def public_error(name, {:vetoed, {:hook_threw, _hook, _v}}),
    do: "[Tool error for #{name}]: blocked by policy (hook error)"

  def public_error(name, {:vetoed, {:hook_exited, _hook, _r}}),
    do: "[Tool error for #{name}]: temporarily unavailable"

  def public_error(name, {:hook_error, _detail}),
    do: "[Tool error for #{name}]: tool misconfigured"

  def public_error(name, {:vetoed, reason}) when is_atom(reason),
    do: "[Tool error for #{name}]: blocked by policy (#{reason})"

  def public_error(name, {:vetoed, _reason}),
    do: "[Tool error for #{name}]: blocked by policy"

  def public_error(name, {:tool_denied, _tool, reason}) when is_atom(reason),
    do: "[Tool error for #{name}]: denied (#{reason})"

  def public_error(name, {:tool_denied, _tool, _reason}),
    do: "[Tool error for #{name}]: denied"

  def public_error(name, {:tool_not_in_toolset, _mod}),
    do: "[Tool error for #{name}]: tool not available"

  def public_error(name, {:invalid_action, _mod}),
    do: "[Tool error for #{name}]: tool not available"

  def public_error(name, reason)
      when reason in [
             :arguments_not_object,
             :too_many_argument_keys,
             :argument_value_too_large,
             :arguments_too_deep
           ],
      do: "[Tool error for #{name}]: invalid arguments"

  # LSP failures are the model's to route around: each says whether to fix the
  # call, use a different tool, or stop asking. Server names and paths here
  # are configuration and the model's own arguments, not server output.
  def public_error(name, :lsp_not_available),
    do:
      "[Tool error for #{name}]: no language server is running for this " <>
        "session. Use grep and read_file instead."

  def public_error(name, :no_server),
    do:
      "[Tool error for #{name}]: no language server is configured for that " <>
        "file type. Use grep and read_file instead."

  def public_error(name, {:not_installed, command}),
    do:
      "[Tool error for #{name}]: the language server for that file type " <>
        "(#{command}) is not installed. Use grep and read_file instead."

  def public_error(name, :diagnostics_timeout),
    do:
      "[Tool error for #{name}]: the language server did not report on that " <>
        "file in time. This is not a clean bill of health — it may still be " <>
        "indexing. Retry, or verify another way."

  def public_error(name, :line_required),
    do: "[Tool error for #{name}]: that op needs a 1-based `line` (and usually `column`)."

  def public_error(name, :invalid_position),
    do: "[Tool error for #{name}]: `line` and `column` are 1-based and must be positive."

  def public_error(name, {:unknown_op, _op}),
    do:
      "[Tool error for #{name}]: unknown op. Use diagnostics, symbols, " <>
        "definition, references, or hover."

  def public_error(name, :rename_not_possible),
    do:
      "[Tool error for #{name}]: the language server will not rename that " <>
        "symbol from that position. Check the position points at the name itself."

  def public_error(name, {:rename_outside_workspace, _path}),
    do:
      "[Tool error for #{name}]: the rename would edit a file outside this " <>
        "workspace, so nothing was written."

  def public_error(name, :invalid_name),
    do: "[Tool error for #{name}]: that is not a usable symbol name."

  def public_error(name, {:rename_too_broad, count, max}),
    do:
      "[Tool error for #{name}]: that rename would edit #{count} files, over " <>
        "the limit of #{max}. Nothing was written. Check the position names " <>
        "the symbol you meant; if #{count} files is right, retry with " <>
        "`max_files` set to at least #{count}."

  # Names what DID land. A caller told only that a write failed cannot tell a
  # tree that was never touched from one that was half rewritten.
  def public_error(name, {:partial_write, written, reason}),
    do:
      "[Tool error for #{name}]: writing failed (#{inspect(reason)}) after " <>
        "#{length(written)} file(s) were already written: " <>
        "#{Enum.join(written, ", ")}. The rename is INCOMPLETE — those files " <>
        "carry the new name and the rest do not."

  # Edit failures are the model's to correct, so each says what to do next.
  # Line numbers and anchor hashes are the model's own arguments echoed back
  # plus the file's current shape at a line it already addressed: no content
  # and nothing it could not obtain with the read tools it already holds.
  def public_error(name, {:anchor_mismatch, line, expected, actual}),
    do:
      "[Tool error for #{name}]: line #{line} no longer holds the bytes you " <>
        "anchored (you sent #{expected}, it is now #{actual}). The file " <>
        "changed since you read it — read_file it again and redo the edit " <>
        "against the current anchors."

  def public_error(name, {:anchor_out_of_range, line, total}),
    do:
      "[Tool error for #{name}]: line #{line} is past the end of the file " <>
        "(#{total} lines). Re-read the file and use an anchor it printed."

  def public_error(name, {:range_inverted, from, to}),
    do:
      "[Tool error for #{name}]: `from` is line #{from} but `to` is line " <>
        "#{to}; the range must run forwards."

  def public_error(name, :malformed_anchor),
    do:
      "[Tool error for #{name}]: an anchor must be the `LINE:HASH` prefix " <>
        "read_file printed, copied verbatim (for example `12:a3f1c2`)."

  def public_error(name, :ambiguous_addressing),
    do:
      "[Tool error for #{name}]: pass either `from`/`to` anchors or " <>
        "`old_string`, not both."

  def public_error(name, :no_addressing),
    do:
      "[Tool error for #{name}]: nothing addressed. Pass `from` (the " <>
        "`LINE:HASH` prefix read_file printed) or `old_string`."

  def public_error(name, :no_match),
    do:
      "[Tool error for #{name}]: `old_string` was not found in the file. It " <>
        "must match the file byte for byte, including indentation. Read the " <>
        "file and edit by anchor instead."

  def public_error(name, {:not_unique, count}),
    do:
      "[Tool error for #{name}]: `old_string` matches #{count} places. " <>
        "Address one of them by anchor, or set `replace_all` to change all " <>
        "#{count}."

  def public_error(name, :no_change),
    do: "[Tool error for #{name}]: the replacement is identical to what is already there."

  def public_error(name, :enoent),
    do: "[Tool error for #{name}]: no such file or directory."

  def public_error(name, {:too_many_prompts, sent, max}),
    do:
      "[Tool error for #{name}]: #{sent} prompts is over the limit of " <>
        "#{max}. Nothing ran — send at most #{max} per call."

  def public_error(name, :ambiguous_prompt),
    do: "[Tool error for #{name}]: pass either `prompt` or `prompts`, not both."

  def public_error(name, :no_prompt),
    do: "[Tool error for #{name}]: pass `prompt` for one subtask or `prompts` for several."

  def public_error(name, :blank_prompt),
    do: "[Tool error for #{name}]: every entry in `prompts` must be a non-empty string."

  def public_error(name, :outside_cwd),
    do:
      "[Tool error for #{name}]: that path is outside the working directory " <>
        "this session is scoped to."

  def public_error(name, _other), do: "[Tool error for #{name}]: tool error"

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

  defp find_action(name, tools) do
    case Enum.find(tools, fn tool -> tool_name(tool) == name end) do
      nil -> {:error, {:unknown_tool, name}}
      tool -> {:ok, tool}
    end
  end

  # A tool is an Action module (atom) or a `Dynamic` (runtime-discovered).
  defp tool_name(%Dynamic{name: name}), do: name
  defp tool_name(module) when is_atom(module), do: module.__action_meta__().name

  defp invoke(%Dynamic{invoke: fun}, params, context), do: fun.(params, context)
  defp invoke(module, params, context) when is_atom(module), do: module.call(params, context)

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

  # A hook that rewrites `params` to a non-map is itself a contract
  # violation on the value dispatched to `Action.call/2`; reject it the same
  # way as an oversized/malformed argument tree rather than raising inside
  # `check_depth_and_size/3`'s map-only clauses.
  defp validate_arg_limits(_non_map), do: {:error, :arguments_not_object}

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
