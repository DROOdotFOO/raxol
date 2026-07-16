defmodule Raxol.Agent.Strategy.ReAct do
  require Logger

  @moduledoc """
  ReAct (Reasoning + Acting) strategy.

  Sends the current context to an LLM with available Actions as tools.
  The LLM decides which tool to call, the strategy executes the Action,
  feeds the result back, and repeats until the LLM produces a final
  text answer or max iterations are reached.

  ## Required context keys

  - `:backend` -- AIBackend module (e.g. `Raxol.Agent.Backend.HTTP`)
  - `:backend_opts` -- keyword list for backend calls (api_key, model, etc.)
  - `:actions` -- list of Action modules available as tools

  ## Optional context keys

  - `:system_prompt` -- system message prepended to conversation
  - `:max_iterations` -- loop guard (default 10)
  """

  @behaviour Raxol.Agent.Strategy

  alias Raxol.Agent.Action.ToolConverter

  @default_max_iterations 10

  @impl true
  def execute({_action, params}, state, context) do
    prompt = Map.get(params, :prompt) || Map.get(params, "prompt") || inspect(params)
    max_iter = Map.get(context, :max_iterations, @default_max_iterations)

    with {:ok, backend} <- fetch_required(context, :backend) do
      backend_opts = Map.get(context, :backend_opts, [])
      actions = Map.get(context, :actions, [])
      system_prompt = Map.get(context, :system_prompt)

      tools = ToolConverter.to_tool_definitions(actions)
      opts = Keyword.merge(backend_opts, tools: tools)

      initial_messages =
        system_prompt
        |> build_initial_messages(prompt)
        |> maybe_enrich_memory(context, prompt)

      case run_loop(initial_messages, backend, opts, actions, context, max_iter, 0) do
        {:ok, answer, tool_results} ->
          new_state =
            state
            |> Map.put(:last_answer, answer)
            |> Map.put(:tool_results, tool_results)

          {:ok, new_state}

        {:error, _} = error ->
          error
      end
    end
  end

  defp maybe_enrich_memory(messages, context, query) do
    Raxol.Agent.Memory.Manager.enrich_messages(messages, Map.get(context, :memory), query)
  end

  # -- Loop ------------------------------------------------------------------

  defp run_loop(_messages, _backend, _opts, _actions, _context, max_iter, iteration)
       when iteration >= max_iter do
    {:error, :max_iterations_reached}
  end

  defp run_loop(messages, backend, opts, actions, context, max_iter, iteration) do
    case backend.complete(messages, opts) do
      {:ok, %{tool_calls: tool_calls}}
      when is_list(tool_calls) and tool_calls != [] ->
        {tool_messages, _tool_results} = execute_tool_calls(tool_calls, actions, context)

        assistant_msg = %{role: :assistant, content: format_tool_call_text(tool_calls)}
        updated_messages = messages ++ [assistant_msg | tool_messages]

        run_loop(updated_messages, backend, opts, actions, context, max_iter, iteration + 1)

      {:ok, %{content: answer}} ->
        tool_results = extract_accumulated_results(messages)
        {:ok, answer, tool_results}

      {:error, _} = error ->
        error
    end
  end

  # -- Tool execution --------------------------------------------------------

  defp execute_tool_calls(tool_calls, actions, context) do
    {msgs_rev, results_rev} =
      Enum.reduce(tool_calls, {[], []}, fn tool_call, {msgs, results} ->
        name = Map.get(tool_call, "name")

        case ToolConverter.dispatch_tool_call(tool_call, actions, context) do
          {:ok, result} ->
            msg = %{role: :user, content: "[Tool result for #{name}]: #{Jason.encode!(result)}"}
            {[msg | msgs], [{name, result} | results]}

          {:ok, result, _commands} ->
            msg = %{role: :user, content: "[Tool result for #{name}]: #{Jason.encode!(result)}"}
            {[msg | msgs], [{name, result} | results]}

          {:error, reason} ->
            Logger.debug(fn -> "tool #{name} failed: #{inspect(reason)}" end)
            msg = %{role: :user, content: ToolConverter.public_error(name, reason)}
            {[msg | msgs], [{name, {:error, reason}} | results]}
        end
      end)

    {Enum.reverse(msgs_rev), Enum.reverse(results_rev)}
  end

  # -- Message building ------------------------------------------------------

  defp build_initial_messages(nil, prompt) do
    [%{role: :user, content: prompt}]
  end

  defp build_initial_messages(system_prompt, prompt) do
    [
      %{role: :system, content: system_prompt},
      %{role: :user, content: prompt}
    ]
  end

  defp format_tool_call_text(tool_calls) do
    tool_calls
    |> Enum.map_join(", ", fn tc -> Map.get(tc, "name", "unknown") end)
    |> then(&"[Calling tools: #{&1}]")
  end

  defp extract_accumulated_results(messages) do
    messages
    |> Enum.filter(fn msg ->
      content = Map.get(msg, :content, "")
      is_binary(content) and String.starts_with?(content, "[Tool result for ")
    end)
    |> Enum.map(& &1.content)
  end

  defp fetch_required(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_required_context, key}}
    end
  end
end
