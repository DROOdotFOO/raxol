defmodule Raxol.Agent.Harness.ToolExecutor do
  require Logger

  @moduledoc """
  The live harness's tool-execution loop: the seam that was missing.

  The bonded system prompt tells the model it has `read`/`write`/`edit`/
  `bash`/`glob`/`grep` tools, but the shipped demo drove a bare
  `Raxol.Agent.Stream.run/2` — a completion stream that emits text and
  nothing else. When the model emitted a tool call, it went unanswered and
  the turn died. This module closes that: model emits a tool call → the
  call is executed (gated by approval where consequential) → the result is
  fed back → the loop continues until the model produces a text-only
  answer.

  ## Why `complete/2`, not `stream/2`

  `Raxol.Agent.Backend.HTTP.stream/2` surfaces ONLY text deltas — it drops
  every provider tool-call delta on the floor (verified: the Anthropic
  `input_json_delta` and OpenAI `tool_calls` deltas are never accumulated
  into the `{:done, _}` response). So a tool call is UNOBSERVABLE on the
  streaming path. `complete/2`, by contrast, parses tool calls for both
  providers into `response.tool_calls`. This loop therefore drives the tool
  rounds with `complete/2` (the `Raxol.Agent.Stream.react/2` precedent) —
  an honest consequence is that a tool-bearing turn's text arrives
  per-round, not per-token. Closing the SSE tool-delta gap so streaming and
  tools coexist is a separate, larger change (out of scope here, disclosed).

  ## The event vocabulary (fed to `Raxol.Agent.Contract.pump/3`)

  Returns a lazy `Stream` whose elements are the same event tuples
  `Raxol.Agent.Stream` uses, PLUS three this loop adds:

    * `{:text_delta, text}` — the final text answer (one chunk per round)
    * `{:tool_use, %{name, arguments, id}}` — a tool the model called
    * `{:approval_requested, %{request_id, tool_name, args, options, action}}`
      — a consequential tool is holding for a keyboard answer
    * `{:approval_decided, %{request_id, option_id, decision}}` — the answer
      folded back (releases the harness approval block's frontier)
    * `{:tool_result, %{name, result}}` — the receipt (bytes/exit code/diff)
    * `{:tool_unexecuted, %{name, reason}}` — a tool call that was RECOGNIZED
      but never produced a result (the honesty marker: a claim of action
      with no receipt is never silent)
    * `{:turn_complete, info}` / `{:done, info}` / `{:error, reason}`

  `Raxol.Agent.Contract.pump/3` maps every one of these onto a durable
  contract event, so the harness surface renders them (tool ⚙ blocks,
  approval blocks, ± diff blocks) with no surface change: the events ARE the
  contract.

  ## Approval is EVENT-then-await

  For a consequential tool (see `Raxol.Agent.Harness.ToolClassifier`) the
  loop emits `{:approval_requested, _}` FIRST — so `pump` sequences it into
  the id stream and the surface paints the approval block that holds the
  frontier — and only THEN blocks on the injected `:await_decision` fun. The
  answer (routed keyboard → `Raxol.Agent.Harness.SessionInbox`) unblocks it;
  the loop emits `{:approval_decided, _}` and either runs the tool or feeds
  the model an honest denial. The await fun is a pure seam: the inbox
  implements it as a parked `GenServer.call`; a test passes a plain fun; a
  `--yolo` run disables gating entirely (`gate?: false`) and every
  consequential run is disclosed after the fact by the embedder.
  """

  alias Raxol.Agent.Action.ToolConverter
  alias Raxol.Agent.Harness.ToolClassifier

  @default_max_iterations 10

  # The two option ids the harness approval block offers; the surface
  # resolves a keyboard answer (y/n or a numbered pick) to one of these and
  # routes it back as the decision's `option_id`. `kind` is what the loop
  # reads to decide allow vs deny — never the id string alone.
  @allow_option %{option_id: "allow", name: "Allow", kind: :allow_once}
  @deny_option %{option_id: "deny", name: "Deny", kind: :reject_once}

  @type decision :: {:allow, String.t()} | {:deny, String.t(), term()}
  @type await_fun :: (String.t(), map() -> decision())

  @doc """
  Build the lazy tool-execution stream for `prompt`.

  Options:

    * `:backend` / `:backend_opts` — the AI backend (as for
      `Raxol.Agent.Stream`); tool definitions are injected automatically.
    * `:actions` — Action modules exposed as tools.
    * `:system_prompt` — resolved system prompt text (binary), prepended.
    * `:max_iterations` — loop guard (default 10).
    * `:gate?` — whether consequential tools require approval (default
      `true`). `false` is `--yolo`: no approval events, tools run directly.
    * `:await_decision` — `(request_id, meta) -> {:allow, option_id} |
      {:deny, option_id, reason}`, blocking; the harness parks it. Default
      auto-allows (used only when `gate?: false`, or in tests).
    * `:shell_tool_ref_sink` — arity-1 fun threaded into the tool context so
      `run_shell` can publish its live `%{port, os_pid}` for interrupts.
    * `:context` — extra Action context merged under the above.
  """
  @spec stream(String.t(), keyword()) :: Enumerable.t()
  def stream(prompt, opts \\ []) when is_binary(prompt) do
    backend = Keyword.get(opts, :backend, Raxol.Agent.Backend.Mock)
    actions = Keyword.get(opts, :actions, [])
    max_iterations = Keyword.get(opts, :max_iterations, @default_max_iterations)

    tools = ToolConverter.to_tool_definitions(actions)

    backend_opts =
      opts
      |> Keyword.get(:backend_opts, [])
      |> Keyword.put(:tools, tools)

    tool_context =
      opts
      |> Keyword.get(:context, %{})
      |> maybe_put(
        :shell_tool_ref_sink,
        Keyword.get(opts, :shell_tool_ref_sink)
      )

    config = %{
      backend: backend,
      opts: backend_opts,
      actions: actions,
      tool_context: tool_context,
      max_iterations: max_iterations,
      gate?: Keyword.get(opts, :gate?, true),
      await_decision: Keyword.get(opts, :await_decision, &default_allow/2)
    }

    messages = build_messages(prompt, Keyword.get(opts, :system_prompt))

    caller = self()
    ref = make_ref()

    pid =
      spawn_link(fn ->
        loop(messages, 0, %{config: config, caller: caller, ref: ref})
        send(caller, {:executor_done, ref})
      end)

    Stream.resource(
      fn -> %{ref: ref, pid: pid, done: false} end,
      &receive_event/1,
      fn %{pid: p} -> if Process.alive?(p), do: Process.exit(p, :normal) end
    )
  end

  # -- stream plumbing (mirrors Stream.react's spawned-loop pattern) ----------

  @loop_timeout_ms 300_000

  defp receive_event(%{done: true} = state), do: {:halt, state}

  defp receive_event(%{ref: ref} = state) do
    receive do
      {:executor_event, ^ref, event} ->
        case event do
          {:done, _} -> {[event], %{state | done: true}}
          {:error, _} -> {[event], %{state | done: true}}
          _ -> {[event], state}
        end

      {:executor_done, ^ref} ->
        {:halt, state}
    after
      @loop_timeout_ms -> {[{:error, :timeout}], %{state | done: true}}
    end
  end

  defp emit(%{caller: caller, ref: ref}, event),
    do: send(caller, {:executor_event, ref, event})

  # -- the loop (runs in the spawned process) ---------------------------------

  defp loop(_messages, iteration, %{config: %{max_iterations: max}} = st)
       when iteration >= max do
    emit(st, {:error, :max_iterations_reached})
  end

  defp loop(messages, iteration, %{config: config} = st) do
    case config.backend.complete(messages, config.opts) do
      {:ok, %{tool_calls: tool_calls} = response}
      when is_list(tool_calls) and tool_calls != [] ->
        handle_tools(messages, iteration, st, response, tool_calls)

      {:ok, %{content: content} = response} ->
        if is_binary(content) and content != "" do
          emit(st, {:text_delta, content})
        end

        emit(
          st,
          {:done,
           %{content: content || "", tool_results: [], usage: usage(response)}}
        )

      {:error, reason} ->
        emit(st, {:error, reason})
    end
  end

  defp handle_tools(messages, iteration, st, response, tool_calls) do
    assistant_msg = %{
      role: :assistant,
      content: assistant_text(response, tool_calls)
    }

    tool_messages =
      Enum.map(tool_calls, fn tc -> run_one(tc, st) end)

    emit(
      st,
      {:turn_complete,
       %{
         content: Map.get(response, :content, "") || "",
         usage: usage(response),
         iteration: iteration
       }}
    )

    next = messages ++ [assistant_msg | tool_messages]
    loop(next, iteration + 1, st)
  end

  # One tool call end-to-end: announce it (tool_use), gate it if
  # consequential, execute or refuse, and always emit a tool_result — a
  # recognized call NEVER ends without a receipt.
  defp run_one(tc, %{config: config} = st) do
    name = Map.get(tc, "name")
    arguments = Map.get(tc, "arguments", %{})
    id = Map.get(tc, "id")

    emit(st, {:tool_use, %{name: name, arguments: arguments, id: id}})

    cond do
      is_nil(name) ->
        # A tool call the provider sent with no name is unexecutable — mark
        # it honestly rather than silently dropping it.
        emit(st, {:tool_unexecuted, %{name: nil, reason: :missing_tool_name}})

        emit(
          st,
          {:tool_result,
           %{name: "unknown", result: {:error, :missing_tool_name}}}
        )

        %{role: :user, content: "[Tool error]: tool call had no name"}

      config.gate? and ToolClassifier.consequential?(name) ->
        gated_run(tc, name, arguments, st)

      true ->
        execute(tc, name, st)
    end
  end

  defp gated_run(tc, name, arguments, %{config: config} = st) do
    request_id =
      "appr-" <> Integer.to_string(System.unique_integer([:positive]))

    options = [@allow_option, @deny_option]

    emit(
      st,
      {:approval_requested,
       %{
         request_id: request_id,
         tool_name: name,
         action: name,
         args: arguments,
         options: options
       }}
    )

    decision =
      await(config.await_decision, request_id, %{
        tool_name: name,
        args: arguments,
        options: options
      })

    case decision do
      {:allow, option_id} ->
        emit(
          st,
          {:approval_decided,
           %{request_id: request_id, option_id: option_id, decision: :allow}}
        )

        execute(tc, name, st)

      {:deny, option_id, reason} ->
        emit(
          st,
          {:approval_decided,
           %{request_id: request_id, option_id: option_id, decision: :deny}}
        )

        emit(
          st,
          {:tool_result, %{name: name, result: {:error, {:denied, reason}}}}
        )

        %{
          role: :user,
          content: "[Tool #{name} denied by the operator]: #{inspect(reason)}"
        }
    end
  end

  defp await(fun, request_id, meta) when is_function(fun, 2) do
    fun.(request_id, meta)
  rescue
    error ->
      Logger.warning("approval await raised: #{inspect(error)}")
      {:deny, "deny", :await_error}
  catch
    kind, value ->
      Logger.warning("approval await threw: #{inspect({kind, value})}")
      {:deny, "deny", :await_error}
  end

  defp execute(tc, name, %{config: config} = st) do
    case ToolConverter.dispatch_tool_call(
           tc,
           config.actions,
           config.tool_context
         ) do
      {:ok, result} ->
        emit_result(st, name, result)

      {:ok, result, _commands} ->
        emit_result(st, name, result)

      {:error, reason} ->
        emit(st, {:tool_result, %{name: name, result: {:error, reason}}})
        %{role: :user, content: ToolConverter.public_error(name, reason)}
    end
  end

  defp emit_result(st, name, result) do
    emit(st, {:tool_result, %{name: name, result: result}})

    %{
      role: :user,
      content: "[Tool result for #{name}]: #{safe_encode(result)}"
    }
  end

  # -- helpers ----------------------------------------------------------------

  defp default_allow(_request_id, _meta), do: {:allow, "allow"}

  defp build_messages(prompt, nil), do: [%{role: :user, content: prompt}]

  defp build_messages(prompt, system) when is_binary(system) do
    [%{role: :system, content: system}, %{role: :user, content: prompt}]
  end

  defp assistant_text(response, tool_calls) do
    case Map.get(response, :content) do
      text when is_binary(text) and text != "" ->
        text

      _ ->
        names =
          Enum.map_join(tool_calls, ", ", &(Map.get(&1, "name") || "unknown"))

        "[Calling tools: #{names}]"
    end
  end

  defp usage(response), do: Map.get(response, :usage, %{})

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp safe_encode(result) do
    Jason.encode!(result)
  rescue
    _ -> inspect(result)
  end
end
