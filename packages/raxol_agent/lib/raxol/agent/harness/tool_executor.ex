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
  `Raxol.Agent.Stream` uses, PLUS the ones this loop adds:

    * `{:reasoning, text}` — the model's chain-of-thought for THIS round
      (surfaced from `response.reasoning`), emitted before the round's
      tool/text so pump seals it as a durable ∴ block ahead of them; a
      think→tool→think→answer turn produces one per thinking phase, in true
      order. Blank thinking seals nothing.
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
    * `{:marker, text}` — an honest wire-boundary notice (a length-truncated
      round that still produced partial answer text), emitted after that
      answer so pump seals it as a durable ⚠ block qualifying it
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
  alias Raxol.Agent.Actions.Fs
  alias Raxol.Agent.Actions.Workspace
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
      {:deny, option_id, reason}`, blocking; the harness parks it. Left
      unwired, the default is FAIL-CLOSED: with `gate?: true` (the default)
      an unwired approval seam denies every consequential call rather than
      silently auto-allowing it — the opposite default would make turning
      the gate on without wiring an answerer a silent auto-approval of
      `run_shell` and friends, exactly the posture `ToolClassifier` exists to
      prevent. The auto-allow default is reserved for `gate?: false`, where
      it is provably never invoked (a `--yolo` run never reaches the gate at
      all) — it exists only so the two are visibly paired, not because it is
      reachable.
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

    gate? = Keyword.get(opts, :gate?, true)

    config = %{
      backend: backend,
      opts: backend_opts,
      actions: actions,
      tool_context: tool_context,
      max_iterations: max_iterations,
      gate?: gate?,
      await_decision: Keyword.get(opts, :await_decision, default_await_decision(gate?)),
      # `stream: true` drives each round off `backend.stream/2` instead of the
      # blocking `complete/2` -- reasoning + answer text are forwarded to the
      # tail LIVE (the ShadowStream preview + streaming answer), and the final
      # `tool_calls` come off the stream's `:done`. Default off: every existing
      # caller/test keeps the blocking path unchanged.
      stream?: Keyword.get(opts, :stream, false)
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
      &stop_loop/1
    )
  end

  # Consumption ending early (the operator navigates away, the parent turn
  # is torn down, an exception unwinds the enumeration) must not leave the
  # spawned loop parked forever. A plain `Process.exit(p, :normal)` sent by
  # any process OTHER than `p` itself is a no-op -- the receiving process is
  # not trapping exits, and an externally-sent `:normal` exit signal is
  # simply discarded in that case, never terminating it. `p` may be blocked
  # for up to `@loop_timeout_ms` inside a parked `GenServer.call` (an
  # operator who never answers an approval), so nothing else reaps it either.
  # `:kill` is the untrappable signal that actually terminates a non-trapping
  # process no matter what it is blocked on. `p` was started via `spawn_link`
  # from THIS process, so it must be unlinked first -- killing a still-linked
  # process would deliver the same fatal exit signal back to the (also
  # non-trapping) caller and take it down too.
  defp stop_loop(%{pid: p}) do
    if Process.alive?(p) do
      Process.unlink(p)
      Process.exit(p, :kill)
    end
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

  # Streaming round (`stream: true`): reasoning + answer text are forwarded to
  # the tail LIVE as they arrive; the terminal response (content + tool_calls)
  # comes off the stream's `:done`, then runs the SAME branch logic as the
  # blocking path via `dispatch_response/5`.
  defp loop(messages, iteration, %{config: %{stream?: true} = config} = st) do
    case drain_round(config, messages, st) do
      {:ok, response} ->
        dispatch_response(messages, iteration, st, response, streamed: true)

      # Backend can't start a stream this round (e.g. Mock, or Req absent) ->
      # fall back to the blocking path. `stream: true` is a PREFERENCE, not a
      # hard requirement, so a non-streaming backend still works.
      {:stream_unavailable, _reason} ->
        run_blocking(messages, iteration, config, st)

      {:error, reason} ->
        emit(st, {:error, reason})
    end
  end

  # Blocking round (default): the whole response lands at once from
  # `complete/2`.
  defp loop(messages, iteration, %{config: config} = st) do
    run_blocking(messages, iteration, config, st)
  end

  defp run_blocking(messages, iteration, config, st) do
    case config.backend.complete(messages, config.opts) do
      {:ok, response} ->
        dispatch_response(messages, iteration, st, response, streamed: false)

      {:error, reason} ->
        emit(st, {:error, reason})
    end
  end

  # Drain the backend stream, forwarding reasoning/text/marker deltas to the
  # caller as they arrive; return the terminal `:done` response (accumulated
  # content + tool_calls). Halts on the first `:done`/`:error`.
  defp drain_round(config, messages, st) do
    case config.backend.stream(messages, config.opts) do
      {:ok, stream} ->
        Enum.reduce_while(stream, {:error, :stream_ended_without_done}, fn
          {:reasoning, text}, acc ->
            emit(st, {:reasoning, text})
            {:cont, acc}

          {:chunk, text}, acc ->
            emit(st, {:text_delta, text})
            {:cont, acc}

          {:marker, text}, acc ->
            emit(st, {:marker, text})
            {:cont, acc}

          {:done, response}, _acc ->
            {:halt, {:ok, response}}

          {:error, reason}, _acc ->
            {:halt, {:error, reason}}

          _other, acc ->
            {:cont, acc}
        end)

      {:error, reason} ->
        {:stream_unavailable, reason}
    end
  end

  # One response -> the tool round or the answer round. On the STREAMED path
  # reasoning/text/marker were already forwarded live, so they are not
  # re-emitted here; only tool handling / the `:done` seal remain. On the
  # BLOCKING path they are emitted here, after the fact.
  #
  # Ordering (blocking answer round): reasoning (its own ∴ block), then the
  # answer text, then — for a length-truncated round — an honest ⚠ marker
  # AFTER the partial answer it qualifies (pump's first-appearance fold).
  defp dispatch_response(
         messages,
         iteration,
         st,
         %{tool_calls: tool_calls} = response,
         opts
       )
       when is_list(tool_calls) and tool_calls != [] do
    # This round's thinking seals FIRST, ahead of the tool it reasoned toward
    # (`Contract.pump/3` sequences it as a ∴ block before the tool_use item).
    unless opts[:streamed], do: emit_reasoning(st, response)
    handle_tools(messages, iteration, st, response, tool_calls)
  end

  defp dispatch_response(
         _messages,
         _iteration,
         st,
         %{content: content} = response,
         opts
       ) do
    unless opts[:streamed] do
      emit_reasoning(st, response)

      if is_binary(content) and content != "" do
        emit(st, {:text_delta, content})
      end

      maybe_emit_truncation(st, response)
    end

    emit(
      st,
      {:done,
       %{
         content: content || "",
         tool_results: [],
         usage: usage(response),
         model: billed_model(response)
       }}
    )
  end

  # A response with neither a non-empty `tool_calls` NOR a `:content` key
  # (an empty/malformed provider reply -- e.g. `tool_calls: []` and no
  # content) matches neither clause above; without this catch-all it is a
  # `FunctionClauseError` that kills the spawned loop before `{:executor_done,
  # _}` ever fires, relying on an unstated invariant that `:content` is
  # always present. Coerce to an honest empty answer instead -- the round
  # still seals a `:done` receipt rather than hanging or crashing.
  defp dispatch_response(messages, iteration, st, response, opts)
       when is_map(response) do
    dispatch_response(
      messages,
      iteration,
      st,
      Map.put_new(response, :content, ""),
      opts
    )
  end

  # The model's chain-of-thought for this round, surfaced from
  # `response.reasoning` (the LongCat/DeepSeek `reasoning_content`, OpenRouter
  # `reasoning` channel that `Backend.HTTP.complete/2` now exposes). Emitting
  # it here is the whole fix: the live loop parsed reasoning and then dropped
  # it, so thinking was invisible on the harness. On the complete/2 path
  # there is no per-token reasoning stream, so the ∴ block lands when the
  # round's response does (not live-typed) — but once landed it is a durable,
  # peekable transcript fact like every other item. Blank thinking seals
  # nothing.
  defp emit_reasoning(st, response) do
    reasoning = Map.get(response, :reasoning)

    if is_binary(reasoning) and String.trim(reasoning) != "" do
      emit(st, {:reasoning, reasoning})
    end
  end

  # A round the provider cut off at the token limit (`finish_reason: length`)
  # but that still produced SOME answer text: disclose the truncation with an
  # honest ⚠ marker so a partial answer is never mistaken for a whole one.
  # (A length-truncated round with an EMPTY answer never reaches here —
  # `Backend.HTTP` returns it as `{:error, marker}`, handled by the loop's
  # error clause.) The marker text rides in metadata so the honest token
  # count from the wire boundary is preserved verbatim.
  defp maybe_emit_truncation(st, %{metadata: %{marker: marker}})
       when is_binary(marker) and marker != "" do
    emit(st, {:marker, marker})
  end

  defp maybe_emit_truncation(_st, _response), do: :ok

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
         model: billed_model(response),
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
          {:tool_result, %{name: "unknown", result: {:error, :missing_tool_name}}}
        )

        %{role: :user, content: "[Tool error]: tool call had no name"}

      config.gate? and ToolClassifier.consequential?(name) ->
        gated_run(tc, name, arguments, st)

      # An outside-cwd read is not destructive but IS a boundary cross: it
      # escalates to the operator like an edit does, rather than refusing
      # outright. Gate off (--yolo) keeps the hard sandbox — auto-allowing an
      # escape would widen the blast radius exactly when the operator opted
      # out of questions.
      config.gate? and name == "read_file" and
          Fs.outside_cwd?(read_path(arguments), tool_ctx(st)) ->
        gated_run(tc, name, arguments, st)

      true ->
        execute(tc, name, st)
    end
  end

  defp read_path(arguments) when is_map(arguments),
    do: Map.get(arguments, "path") || Map.get(arguments, :path)

  defp read_path(_arguments), do: nil

  defp gated_run(tc, name, arguments, %{config: config} = st) do
    request_id =
      "appr-" <> Integer.to_string(System.unique_integer([:positive]))

    options = [@allow_option, @deny_option]

    # Compute the proposed change BEFORE asking, so the approval shows the
    # operator the CONSEQUENCES of the answer (the ± diff), not truncated
    # args. `preview` also captures the target's content hash -- the
    # staleness anchor verified below.
    preview = tool_preview(name, arguments, tool_ctx(st))

    emit(
      st,
      {:approval_requested, approval_payload(request_id, name, arguments, options, preview)}
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
          {:approval_decided, %{request_id: request_id, option_id: option_id, decision: :allow}}
        )

        apply_after_allow(tc, name, preview, st)

      {:deny, option_id, reason} ->
        emit(
          st,
          {:approval_decided, %{request_id: request_id, option_id: option_id, decision: :deny}}
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

  # The proposed before/after image for the tools that mutate a file --
  # computed WITHOUT writing, so the approval can render a diff instead of raw
  # args. `edit_file` ALWAYS yields a `{:ok, diff}` image: an exact-unique
  # target gives the faithful full-file diff (`match: :exact`); a missing or
  # non-unique target degrades to the proposed hunk with an honest
  # `match: :not_found`/`:ambiguous` signal (never `:none`, so the operator
  # always sees SOMETHING to approve). `write_file` yields `{:ok, diff}`
  # unless the path itself is rejected (outside cwd / too large), which stays
  # `:none`. Every other tool has no diff to show.
  # The preview resolves paths with the SAME context the execution will —
  # a preview against one sandbox root and a write against another would
  # break the label-vs-binding guarantee.
  defp tool_preview("write_file", args, ctx),
    do: preview_or_none(Workspace.preview_write(arg(args, "path"), arg(args, "content"), ctx))

  defp tool_preview("edit_file", args, ctx),
    do:
      preview_or_none(
        Workspace.preview_edit(
          arg(args, "path"),
          arg(args, "old_string"),
          arg(args, "new_string"),
          ctx
        )
      )

  defp tool_preview(_name, _args, _ctx), do: :none

  defp tool_ctx(%{config: %{tool_context: ctx}}) when is_map(ctx), do: ctx
  defp tool_ctx(_st), do: %{}

  defp preview_or_none({:ok, diff}), do: {:ok, diff}
  defp preview_or_none(_error), do: :none

  defp arg(args, key) when is_map(args), do: Map.get(args, key)
  defp arg(_args, _key), do: nil

  # The approval payload: the base fields plus, when a diff was previewed,
  # the `{path, old, new, language}` image the harness block renders as ±
  # rows (`base_hash` stays here in the executor -- it is the staleness
  # anchor, not something the operator needs to see). `preview_match` tells
  # the surface whether this is a faithful image (`:exact`) or a best-effort
  # hunk whose target was not located (`:not_found`/`:ambiguous`), so it can
  # render an honest "target not located -- proposed change shown" note.
  defp approval_payload(request_id, name, arguments, options, {:ok, diff}) do
    %{
      request_id: request_id,
      tool_name: name,
      action: name,
      args: arguments,
      options: options,
      diff: true,
      path: diff.path,
      old: diff.old,
      new: diff.new,
      language: diff.language,
      preview_match: diff.match
    }
  end

  defp approval_payload(request_id, name, arguments, options, :none) do
    %{
      request_id: request_id,
      tool_name: name,
      action: name,
      args: arguments,
      options: options
    }
  end

  # Execute an ALLOWED tool -- but first, for a previewed edit/write, verify
  # the target still hashes to what it did at approval time. If it drifted,
  # NEVER silently apply something other than what was approved: emit an
  # honest stale result and ask the model to re-run (which re-previews the
  # current diff). This is the label-vs-binding guarantee made real.
  # An exact / write preview carries a real `base_hash`: verify the target
  # still hashes to what it did at approval time before applying.
  defp apply_after_allow(
         tc,
         name,
         {:ok, %{path: path, base_hash: base_hash}},
         st
       ) do
    case Workspace.verify_unchanged(path, base_hash, tool_ctx(st)) do
      :ok ->
        execute(tc, name, st)

      {:error, :stale} ->
        emit(
          st,
          {:tool_result, %{name: name, result: {:error, :stale_approval}}}
        )

        %{
          role: :user,
          content:
            "[Tool #{name} NOT applied]: #{path} changed after you approved the diff — re-run to review the current change"
        }
    end
  end

  # A best-effort preview (the edit target could not be located, or was
  # ambiguous) carries NO `base_hash` — there is no faithful image to anchor a
  # staleness check to. Don't verify; attempt execution directly. `do_edit`
  # STILL requires an exact-unique match, so a genuinely missing/ambiguous
  # target fails loudly there rather than silently applying — the operator is
  # never served something other than what the preview implied.
  defp apply_after_allow(tc, name, {:ok, %{match: match}}, st)
       when match in [:not_found, :ambiguous] do
    execute(tc, name, st)
  end

  # A preview-less tool (`:none`) or any other shape: nothing to verify,
  # execute directly (its own execution surfaces any error honestly). An
  # approved OUTSIDE-CWD read carries the one-shot unconfined context —
  # granted strictly by the allow decision for THIS call, never ambient.
  defp apply_after_allow(tc, "read_file" = name, _no_preview, st) do
    if Fs.outside_cwd?(read_path(Map.get(tc, "arguments", %{})), tool_ctx(st)) do
      execute(tc, name, st, %{allow_outside_cwd: true})
    else
      execute(tc, name, st)
    end
  end

  defp apply_after_allow(tc, name, _no_preview, st), do: execute(tc, name, st)

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

  defp execute(tc, name, st, extra_context \\ %{})

  defp execute(tc, name, %{config: config} = st, extra_context) do
    tool_context =
      case {config.tool_context, extra_context} do
        {ctx, extra} when map_size(extra) == 0 -> ctx
        {ctx, extra} when is_map(ctx) -> Map.merge(ctx, extra)
        {_nil, extra} -> extra
      end

    case ToolConverter.dispatch_tool_call(
           tc,
           config.actions,
           tool_context
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

  # `gate?: false` (--yolo) never routes through `gated_run/4` -- `run_one/2`
  # only calls `gated_run/4` when `config.gate?` is true (or for the
  # outside-cwd read escalation, itself gate?-guarded), so this branch is
  # provably dead code, not a live auto-allow. `gate?: true` (the default,
  # and every explicit opt-in) with no `:await_decision` wired gets the
  # fail-closed default instead -- see `stream/2`'s moduledoc.
  defp default_await_decision(false), do: &default_allow/2
  defp default_await_decision(_gate?), do: &default_deny/2

  defp default_allow(_request_id, _meta), do: {:allow, "allow"}

  defp default_deny(_request_id, _meta),
    do: {:deny, "deny", :no_await_decision_configured}

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

  # The BILLED model: with no :model configured the backend substitutes its own
  # default and reports here what it actually charged for.
  defp billed_model(response) do
    response |> Map.get(:metadata, %{}) |> Map.get(:model)
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
