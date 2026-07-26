defmodule Raxol.Agent.Stream do
  require Logger

  @moduledoc """
  Stream-first API for agent sessions.

  Wraps agent interactions as lazy Elixir Streams with natural backpressure.
  Each element is a typed event tuple. Compose with standard `Stream`/`Enum`
  functions.

  ## Quick Start

      # Stream text deltas from a prompt
      Raxol.Agent.Stream.run("Analyze mix.exs", opts)
      |> Raxol.Agent.Stream.text_deltas()
      |> Enum.each(&IO.write/1)

      # Collect final result
      {:ok, result} =
        Raxol.Agent.Stream.run("What is 2+2?", opts)
        |> Raxol.Agent.Stream.collect()

      # ReAct loop with tools
      Raxol.Agent.Stream.react("Count lines in mix.exs", opts)
      |> Stream.each(fn
        {:tool_use, %{name: name}} -> IO.puts("Calling \#{name}...")
        {:text_delta, text} -> IO.write(text)
        _ -> :ok
      end)
      |> Stream.run()

  ## Event Types

  - `{:text_delta, text}` -- streaming text chunk from LLM
  - `{:reasoning, text}` -- streaming chain-of-thought / thinking chunk
    (Anthropic thinking blocks, OpenAI reasoning); distinct from the
    answer text so the contract can seal it as its own reasoning block
  - `{:tool_use, %{name, arguments, id}}` -- LLM requesting a tool call
  - `{:tool_result, %{name, result}}` -- result from executing a tool
  - `{:turn_complete, %{content, usage, iteration}}` -- end of one ReAct turn
  - `{:done, %{content, tool_results, usage}}` -- final answer
  - `{:error, reason}` -- error during execution

  ## Options

  Common options for `run/2` and `react/2`:

  - `:executor` -- `Raxol.Agent.ExecutorConfig` selecting backend + model + auth
    (takes precedence over `:backend`)
  - `:backend` -- AIBackend module (default: `Raxol.Agent.Backend.Mock`); ignored
    when `:executor` is given
  - `:auto_provider` -- when `true` and no `:executor` is given, resolve one from
    the environment via `Raxol.Agent.Backend.Resolver` (the same op-ref ->
    provider-env -> `AI_API_KEY` onboarding the coding TUI and `mix raxol.setup`
    use). An optional `:provider` pins a specific one. Falls through to
    `:backend`/Mock when nothing resolves, so it never crashes an unconfigured
    caller. This is how a headless/embedded agent surface gets the same
    credential story without hand-rolling a resolver call.
  - `:backend_opts` -- keyword list passed to backend (api_key, model, etc.);
    merged over the executor's resolved opts
  - `:model` -- per-request model override (wins over `:executor`/`:backend_opts`)
  - `:system_prompt` -- system message (binary) prepended to the conversation.
    Applies to every entry form -- string prompts, pre-built `:messages`, and
    message-list prompts -- unless the list already carries an explicit
    system message (which then wins; never duplicated). Source specs like
    `:bonded` are resolved upstream by `Raxol.Agent.SystemPrompt`; this layer
    takes resolved text only, so no file I/O happens per turn.
  - `:messages` -- pre-built message list (overrides prompt)
  - `:stream` -- whether to use streaming backend (default: `true`)

  Additional options for `react/2`:

  - `:actions` -- list of Action modules available as tools
  - `:max_iterations` -- loop guard (default: 10)
  """

  alias Raxol.Agent.Action.ToolConverter

  @type event ::
          {:text_delta, String.t()}
          | {:reasoning, String.t()}
          | {:tool_use, tool_use()}
          | {:tool_result, tool_result()}
          | {:turn_complete, turn_info()}
          | {:done, done_info()}
          | {:error, term()}

  @type tool_use :: %{name: String.t(), arguments: map(), id: String.t() | nil}
  @type tool_result :: %{name: String.t(), result: map() | {:error, term()}}
  @type turn_info :: %{
          content: String.t(),
          usage: map(),
          iteration: non_neg_integer()
        }
  @type done_info :: %{
          content: String.t(),
          tool_results: [tool_result()],
          usage: map()
        }

  @default_max_iterations 10
  @react_timeout_ms 120_000

  # Config map passed through the react loop to avoid 9-arity functions.
  # Shape: %{backend: module, opts: keyword, actions: [module],
  #          context: map, max_iterations: pos_integer, caller: pid, ref: reference}

  # -- Public API --------------------------------------------------------------

  @doc """
  Stream a single LLM completion.

  Returns a lazy `Stream` of events. If the backend supports streaming,
  you get `{:text_delta, chunk}` events followed by `{:done, result}`.
  Otherwise falls back to a single `{:done, result}`.

  ## Examples

      Raxol.Agent.Stream.run("Hello", backend: Backend.Mock, backend_opts: [response: "Hi"])
      |> Enum.to_list()
      #=> [{:text_delta, "Hi"}, {:done, %{content: "Hi", ...}}]
  """
  @spec run(String.t() | [map()], keyword()) :: Enumerable.t()
  def run(prompt_or_messages, opts \\ []) do
    messages = build_messages(prompt_or_messages, opts)
    {backend, backend_opts} = resolve_backend(opts)
    do_completion(backend, messages, backend_opts, opts)
  end

  defp do_completion(backend, messages, backend_opts, opts) do
    use_streaming = Keyword.get(opts, :stream, true)

    if use_streaming and function_exported?(backend, :stream, 2) do
      stream_completion(backend, messages, backend_opts)
    else
      sync_completion(backend, messages, backend_opts)
    end
  end

  @doc """
  Stream a ReAct reasoning loop with tool use.

  The LLM sees available tools (from `:actions`) and can call them.
  Each iteration emits tool_use/tool_result events. Continues until
  the LLM produces a final text answer or `:max_iterations` is reached.

  ## Examples

      Raxol.Agent.Stream.react("Analyze mix.exs", [
        backend: Backend.Mock,
        backend_opts: [response: "The file looks good."],
        actions: [MyAction],
        max_iterations: 5
      ])
      |> Enum.to_list()
  """
  @spec react(String.t() | [map()], keyword()) :: Enumerable.t()
  def react(prompt_or_messages, opts \\ []) do
    messages = build_messages(prompt_or_messages, opts)
    {backend, backend_opts} = resolve_backend(opts)

    if Raxol.Agent.AIBackend.handles_tools_internally?(backend) do
      native_react(messages, backend, backend_opts, opts)
    else
      framework_react(messages, backend, backend_opts, opts)
    end
  end

  @doc """
  Whether the backend resolved from `opts` runs its own tool loop.

  Native / vendor-owns-loop backends (`handles_tools_internally? == true`)
  execute tools out-of-process over MCP, where the framework cannot thread run
  context -- `:tool_authorizer`, `:tool_call_hooks`, and app flags such as the
  cron `:in_cron` recursion guard -- into tool execution. A caller that exposes a
  context-guarded tool uses this to fail closed: withhold the tool on that path
  rather than hand over capability the guard cannot police. Resolution mirrors
  `react/2` (executor / auto_provider / `:backend`), so the answer matches the
  backend the turn will actually use.
  """
  @spec native_tool_loop?(keyword()) :: boolean()
  def native_tool_loop?(opts) do
    {backend, _backend_opts} = resolve_backend(opts)
    Raxol.Agent.AIBackend.handles_tools_internally?(backend)
  end

  # Vendor-owns-loop backends (native CLI harnesses) run their own tool loop with
  # Raxol's tools injected over MCP, so the framework just streams their output.
  defp native_react(messages, backend, backend_opts, opts) do
    context = Keyword.get(opts, :context, %{})

    messages
    |> maybe_enrich_memory(context)
    |> maybe_enrich_user_context(context)
    |> then(&do_completion(backend, &1, backend_opts, opts))
  end

  defp framework_react(messages, backend, backend_opts, opts) do
    actions = Keyword.get(opts, :actions, [])
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)
    context = Keyword.get(opts, :context, %{})

    messages =
      messages
      |> maybe_enrich_memory(context)
      |> maybe_enrich_user_context(context)

    tools = ToolConverter.to_tool_definitions(actions)
    tool_opts = Keyword.merge(backend_opts, tools: tools)

    caller = self()
    ref = make_ref()

    config = %{
      backend: backend,
      opts: tool_opts,
      actions: actions,
      context: context,
      max_iterations: max_iterations,
      caller: caller,
      ref: ref
    }

    pid =
      spawn_link(fn ->
        react_loop(messages, 0, config)
        send(caller, {:react_done, ref})
      end)

    Stream.resource(
      fn -> %{ref: ref, pid: pid, done: false} end,
      &receive_react_event/1,
      fn %{pid: p} ->
        if Process.alive?(p), do: Process.exit(p, :normal)
      end
    )
  end

  # -- Filter Helpers ----------------------------------------------------------

  @doc "Filter stream to only text delta events, unwrapping the text."
  @spec text_deltas(Enumerable.t()) :: Enumerable.t()
  def text_deltas(stream) do
    Stream.flat_map(stream, fn
      {:text_delta, text} -> [text]
      _ -> []
    end)
  end

  @doc "Filter stream to only tool use events."
  @spec tool_uses(Enumerable.t()) :: Enumerable.t()
  def tool_uses(stream) do
    Stream.filter(stream, &match?({:tool_use, _}, &1))
  end

  @doc "Filter stream to only tool result events."
  @spec tool_results(Enumerable.t()) :: Enumerable.t()
  def tool_results(stream) do
    Stream.filter(stream, &match?({:tool_result, _}, &1))
  end

  @doc """
  Collect all events and return the final content.

  Drains the stream and returns `{:ok, done_info}` or `{:error, reason}`.
  """
  @spec collect(Enumerable.t()) :: {:ok, done_info()} | {:error, term()}
  def collect(stream) do
    result =
      Enum.reduce(stream, nil, fn
        {:done, info}, _acc -> {:ok, info}
        {:error, reason}, _acc -> {:error, reason}
        _event, acc -> acc
      end)

    result || {:error, :no_result}
  end

  @doc """
  Collect text from a stream into a single string.

  Joins all text deltas. If no text deltas were emitted, falls back
  to the final content from the `:done` event.
  """
  @spec collect_text(Enumerable.t()) :: String.t()
  def collect_text(stream) do
    {text, fallback} =
      Enum.reduce(stream, {"", nil}, fn
        {:text_delta, chunk}, {acc, fb} -> {acc <> chunk, fb}
        {:done, %{content: c}}, {acc, _fb} -> {acc, c}
        _, acc -> acc
      end)

    case text do
      "" -> fallback || ""
      _ -> text
    end
  end

  # -- Private: Single Completion Stream --------------------------------------

  defp stream_completion(backend, messages, backend_opts) do
    case backend.stream(messages, backend_opts) do
      {:ok, inner_stream} ->
        normalize_backend_stream(inner_stream)

      {:error, reason} ->
        error_stream(reason)
    end
  end

  defp normalize_backend_stream(inner_stream) do
    Stream.transform(inner_stream, :running, fn
      {:chunk, text}, :running ->
        {[{:text_delta, text}], :running}

      # Reasoning/thinking tokens the backend surfaced (Anthropic thinking
      # blocks, OpenAI reasoning). Forwarded as a distinct event so the
      # contract can give reasoning its own durable item lifecycle rather
      # than folding it into the answer text — see `Contract.pump/3`.
      {:reasoning, text}, :running ->
        {[{:reasoning, text}], :running}

      # An honest wire-boundary marker (unparseable chunk / length
      # truncation) surfaced by `Backend.HTTP`. Non-fatal: forwarded without
      # halting the turn, so a single bad chunk never kills the stream.
      {:marker, text}, :running ->
        {[{:marker, text}], :running}

      {:done, response}, :running ->
        # `run/2` is the single-completion path -- there is no tool-execution
        # loop downstream of this stream (that is `react/2`). `Backend.HTTP`
        # accumulates streamed `tool_calls` onto the done response even here
        # (`finalize_tool_calls/1`); silently dropping them would strand a
        # model's claimed tool call with zero receipt while the turn still
        # reports a clean done -- a green-wash. Seal an honest
        # `:tool_unexecuted` marker per call instead: the vocabulary already
        # exists and `Contract.pump/3` already renders it as a visible ⚠
        # message -- this is its producer on the streaming run/2 path. The
        # `:done` payload's own shape is untouched (content/tool_results/usage)
        # so nothing reading it directly is disturbed.
        unexecuted_events =
          response
          |> Map.get(:tool_calls, [])
          |> Enum.map(&unexecuted_tool_call_event/1)

        done_event =
          {:done,
           %{content: response.content, tool_results: [], usage: response.usage}}

        {unexecuted_events ++ [done_event], :done}

      {:error, reason}, :running ->
        {[{:error, reason}], :done}

      _event, :done ->
        {:halt, :done}
    end)
  end

  defp unexecuted_tool_call_event(tool_call) do
    name =
      Map.get(tool_call, "name") || Map.get(tool_call, :name) || "unknown"

    {:tool_unexecuted, %{name: name, reason: :no_tool_loop}}
  end

  defp sync_completion(backend, messages, backend_opts) do
    Stream.resource(
      fn -> :pending end,
      fn
        :pending ->
          case backend.complete(messages, backend_opts) do
            {:ok, response} ->
              events = [
                {:text_delta, response.content},
                {:done,
                 %{
                   content: response.content,
                   tool_results: [],
                   usage: response.usage
                 }}
              ]

              {events, :done}

            {:error, reason} ->
              {[{:error, reason}], :done}
          end

        :done ->
          {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  defp error_stream(reason) do
    Stream.resource(
      fn -> :init end,
      fn
        :init -> {[{:error, reason}], :done}
        :done -> {:halt, :done}
      end,
      fn _ -> :ok end
    )
  end

  # -- Private: Stream.resource next_fun for react ----------------------------

  defp receive_react_event(%{done: true} = state), do: {:halt, state}

  defp receive_react_event(%{ref: ref} = state) do
    receive do
      {:react_event, ^ref, event} ->
        case event do
          {:done, _} -> {[event], %{state | done: true}}
          {:error, _} -> {[event], %{state | done: true}}
          _ -> {[event], state}
        end

      {:react_done, ^ref} ->
        {:halt, state}
    after
      @react_timeout_ms -> {[{:error, :timeout}], %{state | done: true}}
    end
  end

  # -- Private: ReAct Loop (runs in spawned process) --------------------------

  defp react_loop(_messages, iteration, %{max_iterations: max} = config)
       when iteration >= max do
    emit(config, {:error, :max_iterations_reached})
  end

  defp react_loop(messages, iteration, config) do
    case config.backend.complete(messages, config.opts) do
      {:ok, %{tool_calls: tool_calls} = response}
      when is_list(tool_calls) and tool_calls != [] ->
        handle_tool_turn(messages, iteration, config, response, tool_calls)

      {:ok, %{content: content} = response} ->
        accumulated = extract_tool_results(messages)

        emit(
          config,
          {:done,
           %{
             content: content,
             tool_results: accumulated,
             usage: Map.get(response, :usage, %{})
           }}
        )

      {:error, reason} ->
        emit(config, {:error, reason})
    end
  end

  defp handle_tool_turn(messages, iteration, config, response, tool_calls) do
    Enum.each(tool_calls, fn tc ->
      emit(
        config,
        {:tool_use,
         %{
           name: Map.get(tc, "name"),
           arguments: Map.get(tc, "arguments", %{}),
           id: Map.get(tc, "id")
         }}
      )
    end)

    tool_messages = execute_tools(tool_calls, config)

    emit(
      config,
      {:turn_complete,
       %{
         content: Map.get(response, :content, ""),
         usage: Map.get(response, :usage, %{}),
         iteration: iteration
       }}
    )

    assistant_msg = %{role: :assistant, content: format_tool_text(tool_calls)}
    next_messages = messages ++ [assistant_msg | tool_messages]

    react_loop(next_messages, iteration + 1, config)
  end

  defp emit(%{caller: caller, ref: ref}, event) do
    send(caller, {:react_event, ref, event})
  end

  # -- Private: Tool Execution ------------------------------------------------

  defp execute_tools(tool_calls, config) do
    Enum.map(tool_calls, fn tc ->
      name = Map.get(tc, "name")
      {result_map, msg} = dispatch_tool(name, tc, config)
      emit(config, {:tool_result, result_map})
      msg
    end)
  end

  defp dispatch_tool(name, tool_call, config) do
    case ToolConverter.dispatch_tool_call(
           tool_call,
           config.actions,
           config.context
         ) do
      {:ok, result} ->
        build_tool_response(name, result)

      {:ok, result, _commands} ->
        build_tool_response(name, result)

      {:error, reason} ->
        Logger.debug(fn -> "tool #{name} failed: #{inspect(reason)}" end)

        {%{name: name, result: {:error, reason}},
         %{role: :user, content: ToolConverter.public_error(name, reason)}}
    end
  end

  defp build_tool_response(name, result) do
    {%{name: name, result: result},
     %{
       role: :user,
       content: "[Tool result for #{name}]: #{Jason.encode!(result)}"
     }}
  end

  # -- Private: Extract results from message history --------------------------

  @tool_result_pattern ~r/\[Tool result for (.+?)\]: (.+)/

  defp extract_tool_results(messages) do
    Enum.flat_map(messages, &parse_tool_result_message/1)
  end

  defp parse_tool_result_message(%{content: "[Tool result for " <> _ = content})
       when is_binary(content) do
    case Regex.run(@tool_result_pattern, content) do
      [_, name, json] ->
        result =
          case Jason.decode(json) do
            {:ok, decoded} -> decoded
            _ -> json
          end

        [%{name: name, result: result}]

      _ ->
        []
    end
  end

  defp parse_tool_result_message(_), do: []

  # -- Private: Backend Resolution --------------------------------------------

  # Resolves the backend module + options from the caller's opts.
  #
  # Precedence: an `:executor` (ExecutorConfig) selects the backend + base opts;
  # otherwise `:backend` (default Mock) is used. Explicit `:backend_opts`
  # override the executor's resolved opts, and a top-level `:model` overrides
  # everything (the substrate for a `/model` mid-session switch).
  defp resolve_backend(opts) do
    {backend, base_opts} = backend_from_opts(opts)

    backend_opts =
      base_opts
      |> Keyword.merge(Keyword.get(opts, :backend_opts, []))
      |> maybe_override_model(Keyword.get(opts, :model))
      |> maybe_inject_actions(backend, opts)

    {backend, backend_opts}
  end

  # Native (vendor-owns-loop) backends expose Raxol's tools to the CLI over MCP,
  # so they need the Action modules in their opts to build the MCP config.
  defp maybe_inject_actions(backend_opts, backend, opts) do
    with true <- Raxol.Agent.AIBackend.handles_tools_internally?(backend),
         actions when is_list(actions) and actions != [] <-
           Keyword.get(opts, :actions) do
      Keyword.put_new(backend_opts, :actions, actions)
    else
      _ -> backend_opts
    end
  end

  defp backend_from_opts(opts) do
    case Keyword.get(opts, :executor) || resolve_executor(opts) do
      %Raxol.Agent.ExecutorConfig{} = executor ->
        case Raxol.Agent.Backend.Selector.select(executor) do
          {:ok, backend, executor_opts} -> {backend, executor_opts}
          {:error, _reason} -> {fallback_backend(opts), []}
        end

      _ ->
        {fallback_backend(opts), []}
    end
  end

  @doc false
  # Opt-in environment/1Password onboarding for any programmatic agent surface.
  # With `auto_provider: true` and no explicit `:executor`, resolve one through
  # the shared `Raxol.Agent.Backend.Resolver` — the SAME op-ref -> provider-env
  # (`ANTHROPIC_API_KEY`, ...) -> `AI_API_KEY`/`AI_BASE_URL` precedence the coding
  # TUI and `mix raxol.setup` use — so a surface gets the same credential story
  # for free instead of hand-rolling a resolver call. A resolution that finds no
  # credential returns `nil`, so `backend_from_opts/1` falls through to
  # `:backend`/Mock and the opt never crashes a caller with no provider set up.
  def resolve_executor(opts) do
    if Keyword.get(opts, :auto_provider, false) do
      resolver_opts =
        [
          harness: Keyword.get(opts, :provider),
          model: Keyword.get(opts, :model),
          api_key: Keyword.get(opts, :api_key),
          base_url: Keyword.get(opts, :base_url)
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)

      case Raxol.Agent.Backend.Resolver.resolve(resolver_opts) do
        {:ok, executor, _source} -> executor
        _ -> nil
      end
    end
  end

  defp fallback_backend(opts) do
    Keyword.get(opts, :backend, Raxol.Agent.Backend.Mock)
  end

  defp maybe_override_model(backend_opts, nil), do: backend_opts

  defp maybe_override_model(backend_opts, model),
    do: Keyword.put(backend_opts, :model, model)

  # -- Private: Message Building ----------------------------------------------

  defp build_messages(prompt, opts) when is_binary(prompt) do
    case Keyword.get(opts, :messages) do
      nil ->
        apply_system_prompt([%{role: :user, content: prompt}], opts)

      messages when is_list(messages) ->
        apply_system_prompt(messages, opts)
    end
  end

  defp build_messages(messages, opts) when is_list(messages),
    do: apply_system_prompt(messages, opts)

  # `:system_prompt` applies to EVERY message-entry form -- a system prompt
  # silently dropped because the caller happened to pass a pre-built list is
  # a trust bug (the operator believes a prompt governs the turn while the
  # backend never saw it). An explicit system message already present in the
  # list wins: the list is the more specific artifact, and we never inject a
  # duplicate.
  defp apply_system_prompt(messages, opts) do
    case Keyword.get(opts, :system_prompt) do
      nil ->
        messages

      sys when is_binary(sys) ->
        if Enum.any?(messages, &(Map.get(&1, :role) == :system)) do
          messages
        else
          [%{role: :system, content: sys} | messages]
        end
    end
  end

  defp maybe_enrich_memory(messages, context) do
    Raxol.Agent.Memory.Manager.enrich_messages(
      messages,
      Map.get(context, :memory),
      last_user_content(messages)
    )
  end

  defp maybe_enrich_user_context(messages, context) do
    Raxol.Agent.Memory.Manager.enrich_user_context(
      messages,
      Map.get(context, :user_context)
    )
  end

  defp last_user_content(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", fn msg ->
      if Map.get(msg, :role) == :user, do: Map.get(msg, :content)
    end)
  end

  defp format_tool_text(tool_calls) do
    names =
      Enum.map_join(tool_calls, ", ", fn tc ->
        Map.get(tc, "name", "unknown")
      end)

    "[Calling tools: #{names}]"
  end
end
