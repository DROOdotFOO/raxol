defmodule Raxol.Agent.ClientProtocol.TurnRunner do
  @moduledoc """
  The production `:turn_runner` for `Raxol.AgentClientProtocol.Session` —
  wraps the real streaming stack (`Raxol.Agent.Stream.run/2` / `react/2`,
  backend selected per `Raxol.Agent.ExecutorConfig` through
  `Raxol.Agent.Backend.Selector`) and streams the turn into the ACP session
  via `Raxol.AgentClientProtocol.Ctx.post_update/2`:

    * `{:text_delta, text}`  → `agent_message_chunk`
    * `{:tool_use, tu}`      → `tool_call` (status `:in_progress`, `raw_input`)
    * `{:tool_result, tr}`   → `tool_call_update` (status `:completed`/`:failed`,
      `raw_output`)
    * `{:done, _}`           → `{:stop, :end_turn}` (the Session renders the
      one `PromptResponse`)
    * `{:error, reason}`     → an error return the Session folds to an
      internal-error `session/prompt` response (`normalize_root_result/1`).

  `new/1` returns the arity-2 fun (`(session_pid, prompt_req) -> {:stop, _}`)
  that `Session.start_link/1` takes as `:turn_runner`; the fun runs inside the
  Session's supervised root `Task`.

  ## Package placement (dependency direction, disclosed)

  The runner needs `Raxol.Agent.Stream` + `Raxol.Agent.Interrupt`, so it lives
  in `raxol_agent` and reaches ACROSS to `raxol_agent_client_protocol` (a leaf
  package depending only on `jason`) — the reverse direction would make the
  protocol package depend on the whole agent framework. Per the repo's
  cross-package convention the ACP modules are referenced with
  `@compile {:no_warn_undefined, ...}` + a `Code.ensure_loaded?/1` guard
  (`available?/0`); `raxol_agent`'s own mix.exs carries the package only as a
  dev/test path dep, so production embedders opt in by adding
  `:raxol_agent_client_protocol` themselves. `new/1` fails loud (at wiring
  time, not mid-turn) when the package is absent.

  ## Cancellation: the Session contract × the Interrupt laws

  The Session's documented runner contract (session.ex, "Turn runner seam"):
  the runner "MAY receive/peek `:acp_cancel` between steps to wind down
  gracefully (the 30s backstop kills it otherwise)". That backstop is
  `Process.exit(pid, :kill)` — a **BEAM** kill, which is exactly the
  orphaning failure `Raxol.Agent.Interrupt` exists to prevent (its
  effectiveness law: killing the BEAM owner "leaves the OS process alive and
  orphans it"). So this runner never lets the backstop be the kill mechanism:

    1. The backend stream is consumed by a dedicated **pump** process
       (`spawn_link` + monitor, exits trapped) that forwards each event as a
       message; the root task therefore sits in a `receive` that always has
       `:acp_cancel` armed — even mid-chunk against a HUNG backend, the
       cancel is seen immediately, not "between chunks".
    2. On `:acp_cancel` the pump is killed FIRST and already-queued stream
       events are flushed unposted — no event can race past the fence.
    3. `Raxol.Agent.Interrupt.interrupt/3` (or the injected `:interrupt`
       double) runs the staged OS-pgroup kill IMMEDIATELY. The `tool_ref` is
       tool-less (`port`/`os_pid` nil) for a mid-provider-stream interrupt;
       a shell-tool embedder threads the live Port/os_pid via the
       `:tool_ref` option.
    4. The kill-complete fence is emitted (below), then the runner returns
       `{:stop, :cancelled}` — only now does the Session's drain gate close
       and render the **exactly-one** cancelled `PromptResponse`.

  ### Post-kill quiescence vs. the cancelled PromptResponse (ordering)

  Interrupt's quiescence law: after kill-complete, no tool/output event for
  the turn may ever appear. Here that is structural: the root task is the
  only process that posts updates, the pump is dead and its queue flushed
  before the fence, and the fence post is the last `post_update` before the
  return. Session I3 (updates and the reply share one Connection FIFO lane)
  then orders the fence strictly before the cancelled response on the wire —
  so the observable sequence is always
  `... updates → fence → cancelled PromptResponse → nothing`.

  ### The fence encoding (ACP has no native kill-fence event)

  Chosen encoding, by honesty:

    * **A tool call was announced on the turn** → one final `tool_call_update`
      for that tool (`status: :failed` — true: the tool was killed), with the
      machine-readable fence riding the `SessionNotification`'s `_meta`
      envelope under `#{inspect("raxol.dev/interrupt")}` (`fence_meta_key/0`):
      `%{"fence" => "interrupt_killed" | "interrupt_kill_failed", "turnId",
      "osPid", "killed", "confirmedDead"}` — built from the Interrupt
      OUTCOME, so the rider never claims a kill the OS observation didn't
      establish (`interrupt_kill_failed` is reported as itself).
    * **Tool-less turn** (mid-provider-stream cancel) → NO synthetic update:
      every `SessionUpdate` variant would fabricate agent content, and
      nothing OS-level was killed. The cancelled `PromptResponse` itself is
      the turn-over fence (quiescence still holds: pump dead, queue flushed,
      nothing posts after it).
    * A **cooperative short-circuit** (the tool exited inside the grace
      window — no kill stage in `outcome.stages`) emits no kill fence either:
      there was no kill to fence.

  ## Options for `new/1`

  Streaming (forwarded to `Raxol.Agent.Stream`): `:executor` (an
  `ExecutorConfig`, see `detect_executor/0`), `:backend`, `:backend_opts`,
  `:model`, `:system_prompt`, `:messages`, `:stream`, `:context`, and —
  selecting `react/2` (tool loop) over `run/2` — `:actions`,
  `:max_iterations`.

  `:system_prompt` takes either a literal binary (passed through unchanged)
  or a `Raxol.Agent.SystemPrompt` source spec (`:bonded`, `{:file, path}`,
  `{:text, binary}`, `:none`). A source spec is resolved ONCE at `new/1`
  (wiring time, cached — no file read per turn), its identity logged at
  debug, and an unresolvable source raises here rather than failing
  silently mid-turn: a system prompt the operator believes is live but the
  backend never received is a trust bug.

  Cancellation seams: `:interrupt` (module implementing the
  `Raxol.Agent.Interrupt` behaviour, or an arity-3 fun; default
  `Raxol.Agent.Interrupt`), `:interrupt_sink` (the staged kill's durable-emit
  arity-2 fun; default logs each stage at debug), `:tool_ref` (arity-0 fun
  returning a map merged over the tool-less base `tool_ref` — the seam a
  shell-tool embedder uses to hand the live `port`/`os_pid` to the staged
  kill).
  """

  require Logger

  alias Raxol.Agent.Stream, as: AgentStream

  # Cross-package: raxol_agent_client_protocol is an optional peer (dev/test
  # path dep only — see mix.exs). Struct patterns below therefore use map
  # patterns; construction goes through the remote `new/…` constructors.
  @compile {:no_warn_undefined,
            [
              Raxol.AgentClientProtocol.Ctx,
              Raxol.AgentClientProtocol.Schema.ContentBlock,
              Raxol.AgentClientProtocol.Schema.ContentChunk,
              Raxol.AgentClientProtocol.Schema.ToolCall,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdate,
              Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields,
              Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification,
              Raxol.AgentClientProtocol.Error
            ]}

  @error_mod Raxol.AgentClientProtocol.Error
  # A runaway reason must not become an unbounded JSON-RPC frame.
  @error_detail_limit 2_000

  @ctx Raxol.AgentClientProtocol.Ctx
  @content_block Raxol.AgentClientProtocol.Schema.ContentBlock
  @content_chunk Raxol.AgentClientProtocol.Schema.ContentChunk
  @tool_call Raxol.AgentClientProtocol.Schema.ToolCall
  @tool_call_update Raxol.AgentClientProtocol.Schema.ToolCallUpdate
  @tcu_fields Raxol.AgentClientProtocol.Schema.ToolCallUpdateFields
  @session_notification Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  @fence_meta_key "raxol.dev/interrupt"
  @kill_stages [:interrupt_killed, :interrupt_kill_failed]

  @stream_opt_keys [
    :executor,
    :backend,
    :backend_opts,
    :model,
    :system_prompt,
    :messages,
    :stream,
    :context,
    :actions,
    :max_iterations
  ]

  @typedoc "The fun shape `Raxol.AgentClientProtocol.Session` takes as `:turn_runner`."
  @type runner :: (pid(), map() -> {:stop, atom()} | {:error, term()})

  @doc "The `_meta` key the kill-complete fence rider is published under."
  @spec fence_meta_key() :: String.t()
  def fence_meta_key, do: @fence_meta_key

  @doc "Whether the optional `raxol_agent_client_protocol` package is present."
  @spec available?() :: boolean()
  def available?, do: Code.ensure_loaded?(@ctx)

  @doc """
  Build the arity-2 turn-runner fun for `Session.start_link/1`'s
  `:turn_runner`. Raises at wiring time when `raxol_agent_client_protocol`
  is not on the code path (never mid-turn). See the moduledoc for options.
  """
  @spec new(keyword()) :: runner()
  def new(opts \\ []) when is_list(opts) do
    unless available?() do
      raise ArgumentError,
            "Raxol.Agent.ClientProtocol.TurnRunner requires the " <>
              ":raxol_agent_client_protocol package on the code path " <>
              "(add it to your deps to use the ACP turn runner)"
    end

    opts = resolve_system_prompt!(opts)

    fn session, req -> run_turn(session, req, opts) end
  end

  # `:system_prompt` source specs resolve at wiring time -- fail loud here,
  # never silently mid-turn. Literal binaries pass through (back-compat).
  defp resolve_system_prompt!(opts) do
    case Keyword.get(opts, :system_prompt) do
      nil ->
        opts

      text when is_binary(text) ->
        opts

      source ->
        case Raxol.Agent.SystemPrompt.resolve(source) do
          {:ok, :none} ->
            Keyword.delete(opts, :system_prompt)

          {:ok, %{text: text} = resolved} ->
            Logger.debug(fn ->
              "acp turn_runner system prompt: " <>
                Raxol.Agent.SystemPrompt.identity_line(resolved)
            end)

            Keyword.put(opts, :system_prompt, text)

          {:error, reason} ->
            raise ArgumentError,
                  "TurnRunner :system_prompt source #{inspect(source)} " <>
                    "failed to resolve: #{inspect(reason)}"
        end
    end
  end

  @doc """
  Environment-driven `ExecutorConfig` detection — the same convention
  `mix raxol.harness` uses (`Mix.Tasks.Raxol.Harness.detect_backend/0`),
  as a library helper:

    * `LM_STUDIO=true|1` → the `:lm_studio` harness (local LM Studio,
      OpenAI-compatible), model `AI_MODEL` or `"local-model"`;
    * `AI_API_KEY` (+ optional `AI_BASE_URL`, a conventional trailing `/v1`
      stripped) → the `:openai` harness for any OpenAI-compatible provider,
      model `AI_MODEL` or `"gpt-4o-mini"`;
    * otherwise `nil` — `Raxol.Agent.Stream` then falls back to
      `Raxol.Agent.Backend.Mock`.

  Explicit, not implicit: `new/1` never calls this on its own — pass
  `executor: TurnRunner.detect_executor()` when env-driven selection is
  wanted.
  """
  @spec detect_executor() :: Raxol.Agent.ExecutorConfig.t() | nil
  def detect_executor do
    cond do
      System.get_env("LM_STUDIO") in ["true", "1"] ->
        Raxol.Agent.ExecutorConfig.new(
          harness: :lm_studio,
          model: System.get_env("AI_MODEL") || "local-model",
          opts: base_url_opts()
        )

      key = System.get_env("AI_API_KEY") ->
        Raxol.Agent.ExecutorConfig.new(
          harness: :openai,
          model: System.get_env("AI_MODEL") || "gpt-4o-mini",
          auth: %{api_key: key},
          opts: base_url_opts()
        )

      true ->
        nil
    end
  end

  defp base_url_opts do
    case System.get_env("AI_BASE_URL") do
      nil ->
        []

      url ->
        # Backend.HTTP's :openai provider appends /v1/chat/completions itself.
        [base_url: url |> String.trim_trailing("/") |> String.trim_trailing("/v1")]
    end
  end

  # -- the turn body (runs inside the Session's supervised root Task) ----------

  defp run_turn(session, req, opts) do
    # Trap exits: the pump is LINKED (so a root crash can never leak a
    # streaming process) and killed with :kill on every exit path; the trapped
    # {:EXIT, pump, _} is dropped in the loop — the monitor drives the logic.
    Process.flag(:trap_exit, true)

    turn_id = "acp-turn-" <> Integer.to_string(System.unique_integer([:positive]))
    prompt = prompt_text(req)
    parent = self()
    # The permission gate can only be built HERE: it closes over this turn's
    # session pid and session id, neither of which exists when the launcher
    # assembles turn_opts. Injected unless the caller already supplied an
    # authorizer, so a test (or an embedder with its own policy) can override.
    opts = with_permission_gate(opts, session, session_id(req))

    # The stream is BUILT inside the pump, not here: Stream.react/2 spawns its
    # loop eagerly with `caller = self()`, so building it in the root task
    # would wire react events into the root's mailbox while the pump starves.
    # Built in the pump, both the backend's streaming process and the react
    # loop are rooted under (linked to) the pump — one `:kill` on cancel tears
    # the whole chain down.
    pump =
      spawn_link(fn ->
        prompt
        |> build_stream(opts)
        |> Enum.each(fn event -> send(parent, {:acp_turn_event, self(), event}) end)
      end)

    mref = Process.monitor(pump)

    loop(%{
      session: session,
      session_id: session_id(req),
      turn_id: turn_id,
      pump: pump,
      mref: mref,
      opts: opts,
      tool_ids: %{},
      open_tools: %{}
    })
  end

  @doc false
  # Put the ACP permission gate in the agent context under `:tool_authorizer`,
  # unless one is already there. Anything else in `:context` survives (the cwd
  # and jail markers ride there too), so this composes rather than replaces.
  @spec with_permission_gate(keyword(), GenServer.server(), String.t()) :: keyword()
  def with_permission_gate(opts, session, session_id) do
    context = Keyword.get(opts, :context, %{})

    if Map.has_key?(context, :tool_authorizer) do
      opts
    else
      gate = Raxol.Agent.ClientProtocol.Permission.authorizer(session, session_id)
      Keyword.put(opts, :context, Map.put(context, :tool_authorizer, gate))
    end
  end

  defp build_stream(prompt, opts) do
    stream_opts = Keyword.take(opts, @stream_opt_keys)

    case Keyword.get(opts, :actions, []) do
      [] -> AgentStream.run(prompt, stream_opts)
      _actions -> AgentStream.react(prompt, stream_opts)
    end
  end

  # The receive loop. The outer zero-timeout receive gives :acp_cancel
  # priority over already-queued stream events; the inner (blocking) receive
  # keeps :acp_cancel armed while waiting — a hung backend never delays the
  # interrupt (the hung pull is parked in the pump, not here).
  defp loop(%{pump: pump, mref: mref} = state) do
    receive do
      :acp_cancel -> cancel(state)
    after
      0 ->
        receive do
          :acp_cancel ->
            cancel(state)

          {:acp_turn_event, ^pump, event} ->
            handle_event(event, state)

          {:DOWN, ^mref, :process, _pid, reason} ->
            handle_pump_down(reason, state)

          {:EXIT, ^pump, _reason} ->
            # Trapped link exit; the :DOWN clause is the single authority.
            loop(state)
        end
    end
  end

  # -- stream events ------------------------------------------------------------

  defp handle_event({:text_delta, text}, state) when is_binary(text) do
    # The Session's streaming guard #1 rejects empty chunks; skip them here so
    # a backend's empty first delta never produces guard noise.
    if text != "" do
      post(state, {:agent_message_chunk, @content_chunk.new(@content_block.from_string(text))})
    end

    loop(state)
  end

  # `Raxol.Agent.Stream.tool_result/0` carries only `name` — no `id` (the
  # backend's tool-call id never survives `Stream`'s own result mapping, see
  # `build_tool_response/2`) — so exact id correlation is not data this
  # runner has access to. What IS available, and what a same-named parallel
  # tool_call pair (two `read_file` calls in one batch) needs to not corrupt,
  # is CALL ORDER: `Stream.react/2` emits every `tool_use` in a batch before
  # executing any of them, then executes + emits each `tool_result`
  # sequentially in the SAME order (`execute_tools/2`'s `Enum.map/2`). A
  # per-name FIFO queue therefore pairs each result with the correct
  # announcement even when two in-flight calls share a name — a single
  # `tool_ids[name] = id` slot (the prior shape) collapsed the second
  # `tool_use` over the first, so BOTH results pointed at the last id.
  defp handle_event({:tool_use, %{name: name} = tu}, state) do
    id = tool_use_id(tu)

    tool_call = %{
      @tool_call.new(id, name || "tool")
      | status: :in_progress,
        raw_input: Map.get(tu, :arguments, %{})
    }

    post(state, {:tool_call, tool_call})

    loop(%{
      state
      | tool_ids: push_tool_id(state.tool_ids, name, id),
        open_tools: Map.put(state.open_tools, id, name)
    })
  end

  defp handle_event({:tool_result, %{name: name, result: result}}, state) do
    {id, tool_ids} = pop_tool_id(state.tool_ids, name)

    {status, raw_output} =
      case result do
        {:error, reason} -> {:failed, %{"error" => inspect(reason)}}
        map when is_map(map) -> {:completed, map}
        other -> {:completed, %{"value" => inspect(other)}}
      end

    fields = %{@tcu_fields.new() | status: status, raw_output: raw_output}
    post(state, {:tool_call_update, @tool_call_update.new(id, fields)})

    loop(%{
      state
      | tool_ids: tool_ids,
        open_tools: Map.delete(state.open_tools, id)
    })
  end

  defp handle_event({:turn_complete, _info}, state), do: loop(state)

  defp handle_event({:done, _info}, state) do
    stop_pump(state)
    {:stop, :end_turn}
  end

  defp handle_event({:error, reason}, state) do
    stop_pump(state)
    {:error, turn_error(:turn_stream_error, reason)}
  end

  defp handle_event(_other, state), do: loop(state)

  defp handle_pump_down(:normal, _state) do
    # Stream ended without a {:done, _} (defensive: run/react always emit one).
    {:stop, :end_turn}
  end

  defp handle_pump_down(reason, _state) do
    {:error, turn_error(:turn_stream_crashed, reason)}
  end

  # Say what broke, twice, because the two audiences are different and both
  # were getting nothing.
  #
  # This used to return an opaque `{:turn_stream_error, reason}` tuple, which
  # the Session folded to a bare `Error.internal_error()` — reason discarded —
  # and nothing logged it. A provider answering "your credit balance is too
  # low" surfaced to an editor as -32603 with no data, and to a benchmark
  # harness as a non-zero exit with an empty stderr. Diagnosing it meant
  # driving the agent stream by hand.
  #
  # `Logger.error` reaches the operator (this surface reroutes logs to stderr
  # before the transport binds, so it lands beside the wire without corrupting
  # it, and a harness captures it). The `data` payload reaches the peer, which
  # is what an editor renders.
  @doc false
  @spec turn_error(atom(), term()) :: struct()
  def turn_error(tag, reason) do
    detail =
      reason
      |> inspect(limit: :infinity, printable_limit: :infinity)
      |> String.slice(0, @error_detail_limit)

    Logger.error("[acp] #{tag}: #{detail}")

    @error_mod.with_data(@error_mod.internal_error(), %{
      "reason" => detail,
      "tag" => Atom.to_string(tag)
    })
  end

  # -- cancellation ---------------------------------------------------------------

  defp cancel(state) do
    # 1. Stop the event source FIRST: no stream event may race past the fence.
    stop_pump(state)
    flush_pump_events(state.pump)

    # 2. The staged OS-pgroup kill, immediately — never the 30s BEAM backstop.
    outcome = run_interrupt(state)

    # 3. The kill-complete fence (see moduledoc for the encoding decision),
    #    posted on the Session's FIFO lane so I3 orders it strictly before...
    maybe_post_fence(state, outcome)

    # 4. ...the exactly-one cancelled PromptResponse the Session renders once
    #    this return drains the turn group.
    {:stop, :cancelled}
  end

  defp stop_pump(%{pump: pump, mref: mref}) do
    Process.demonitor(mref, [:flush])
    Process.exit(pump, :kill)
    :ok
  end

  defp flush_pump_events(pump) do
    receive do
      {:acp_turn_event, ^pump, _event} -> flush_pump_events(pump)
      {:EXIT, ^pump, _reason} -> flush_pump_events(pump)
    after
      0 -> :ok
    end
  end

  # Deliberately catches broadly (`rescue` + `catch :exit`, not just
  # `:error`/`:throw`): this runs on the cancel path, and the whole point of
  # that path (see moduledoc) is that it MUST reach the kill-complete fence
  # and `{:stop, :cancelled}` no matter what the injected `:interrupt`
  # implementation does — letting a raise/throw/exit from a THIRD-PARTY
  # double propagate here would abort the cancel sequence itself, stranding
  # the Session's drain gate with no cancelled reply ever rendered (worse
  # than a swallowed exception: an actual hang). What review flagged as
  # "hides real defects" is answered by telemetry, not by narrowing the
  # catch: every failure branch below fires
  # `[:raxol, :agent, :acp_turn_runner, :interrupt_failed]` with a `:stage`
  # tag distinguishing exactly which branch fired (`:rescue`, `:catch`,
  # `:sink_failure`, `:error`) — a genuine defect in a production
  # `Raxol.Agent.Interrupt` impl is now a measurable signal, not silence,
  # while the cancel sequence still completes honestly either way.
  defp run_interrupt(state) do
    tool_ref = build_tool_ref(state)
    sink = Keyword.get(state.opts, :interrupt_sink, &default_sink/2)
    impl = Keyword.get(state.opts, :interrupt, Raxol.Agent.Interrupt)

    case do_interrupt(impl, tool_ref, sink, reason: :acp_cancel, actor: "acp-client") do
      {:ok, outcome} ->
        outcome

      {:error, {:sink_failure, error, outcome}} ->
        # The kill already happened; the outcome still carries the OS truth.
        Logger.warning("acp turn_runner: interrupt sink failure: #{inspect(error)}")
        interrupt_failure_telemetry(:sink_failure, error)
        outcome

      {:error, reason} ->
        Logger.warning("acp turn_runner: interrupt failed: #{inspect(reason)}")
        interrupt_failure_telemetry(:error, reason)
        nil
    end
  rescue
    error ->
      Logger.warning("acp turn_runner: interrupt raised: #{inspect(error)}")
      interrupt_failure_telemetry(:rescue, error)
      nil
  catch
    kind, value ->
      Logger.warning("acp turn_runner: interrupt threw: #{inspect({kind, value})}")
      interrupt_failure_telemetry(:catch, {kind, value})
      nil
  end

  defp interrupt_failure_telemetry(stage, detail) do
    :telemetry.execute(
      [:raxol, :agent, :acp_turn_runner, :interrupt_failed],
      %{},
      %{stage: stage, detail: detail}
    )
  end

  defp do_interrupt(impl, tool_ref, sink, opts) when is_function(impl, 3),
    do: impl.(tool_ref, sink, opts)

  defp do_interrupt(impl, tool_ref, sink, opts) when is_atom(impl),
    do: impl.interrupt(tool_ref, sink, opts)

  defp build_tool_ref(state) do
    base = %{turn_id: state.turn_id, port: nil, os_pid: nil}

    case Keyword.get(state.opts, :tool_ref) do
      fun when is_function(fun, 0) ->
        case fun.() do
          %{} = extra -> Map.merge(base, extra)
          _other -> base
        end

      _none ->
        base
    end
  end

  defp default_sink(type, payload) do
    Logger.debug(fn -> "acp turn_runner interrupt stage #{type}: #{inspect(payload)}" end)
    :ok
  end

  # The kill-complete fence: only when a kill stage actually landed AND at
  # least one tool call is still open on this turn (the honest carrier).
  # Tool-less turns and cooperative short-circuits emit nothing — see the
  # moduledoc. `open_tools` (populated on `tool_use`, cleared on the matching
  # `tool_result`) tracks every announced-but-not-yet-resulted call, not just
  # the most recent one: `Stream.react/2` announces a whole batch of
  # `tool_use` events before executing any of them, so more than one call can
  # be genuinely in flight when the cancel lands — a single `current_tool`
  # slot silently dropped the fence for every tool but the last announced.
  # Every open tool gets its own terminal `tool_call_update`, all carrying
  # the SAME outcome-derived rider (one OS-level kill, fenced once per
  # announced call).
  defp maybe_post_fence(%{open_tools: open_tools} = state, %{stages: stages} = outcome)
       when map_size(open_tools) > 0 do
    case Enum.find(stages, &(&1 in @kill_stages)) do
      nil ->
        :ok

      fence_stage ->
        rider = fence_rider(fence_stage, state, outcome)

        Enum.each(open_tools, fn {tool_id, _name} ->
          fields = %{@tcu_fields.new() | status: :failed}
          update = @tool_call_update.new(tool_id, fields)
          notif = @session_notification.new(state.session_id, {:tool_call_update, update})
          notif = %{notif | _meta: %{@fence_meta_key => rider}}
          _ = @ctx.post_update(state.session, notif)
        end)

        :ok
    end
  end

  defp maybe_post_fence(_state, _outcome), do: :ok

  defp fence_rider(fence_stage, state, outcome) do
    %{
      "fence" => Atom.to_string(fence_stage),
      "turnId" => state.turn_id,
      "osPid" => Map.get(outcome, :os_pid),
      "killed" => Map.get(outcome, :killed?, false),
      "confirmedDead" => Map.get(outcome, :confirmed_dead?, false)
    }
  end

  # -- update emission -------------------------------------------------------------

  defp post(state, update) do
    notif = @session_notification.new(state.session_id, update)
    # While this root task is alive the turn cannot have drained (the drain
    # gate waits on this very process), so {:error, :turn_over} is unreachable
    # here; {:error, :empty_chunk} is prevented by the text_delta guard above.
    _ = @ctx.post_update(state.session, notif)
    :ok
  end

  # -- request plumbing --------------------------------------------------------------

  defp session_id(%{session_id: session_id}) when is_binary(session_id), do: session_id
  defp session_id(_req), do: ""

  # PromptRequest.prompt is a list of ContentBlock variants; text blocks are
  # `{:text, %TextContent{}}` (map pattern across the package boundary). A
  # bare-binary prompt (test doubles) passes through.
  defp prompt_text(%{prompt: blocks}) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      {:text, %{text: text}} when is_binary(text) -> [text]
      _other -> []
    end)
    |> Enum.join("\n")
  end

  defp prompt_text(%{prompt: prompt}) when is_binary(prompt), do: prompt
  defp prompt_text(_req), do: ""

  defp tool_use_id(%{id: id}) when is_binary(id) and id != "", do: id
  defp tool_use_id(_tu), do: generated_tool_id()

  defp generated_tool_id,
    do: "tool-" <> Integer.to_string(System.unique_integer([:positive]))

  # -- per-name FIFO id correlation ---------------------------------------------
  #
  # `tool_ids` maps a tool name to the QUEUE of announced ids awaiting a
  # result, oldest first. `push_tool_id/3` appends (a later `tool_use` for the
  # same name queues behind, never overwrites); `pop_tool_id/2` takes the
  # oldest (the result whose execution order is first, per `execute_tools/2`).
  defp push_tool_id(tool_ids, name, id) do
    Map.update(tool_ids, name, [id], &(&1 ++ [id]))
  end

  # An empty/absent queue (a result for a tool never announced, or one
  # already drained) still returns a usable id rather than crashing the
  # runner mid-turn — the same honest fallback the prior single-slot shape
  # used (`generated_tool_id/0`), just never reachable via a queue collision.
  defp pop_tool_id(tool_ids, name) do
    case Map.get(tool_ids, name) do
      [id | rest] ->
        tool_ids =
          if rest == [], do: Map.delete(tool_ids, name), else: Map.put(tool_ids, name, rest)

        {id, tool_ids}

      _empty_or_absent ->
        {generated_tool_id(), tool_ids}
    end
  end
end
