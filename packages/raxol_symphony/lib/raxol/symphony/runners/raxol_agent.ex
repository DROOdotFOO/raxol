defmodule Raxol.Symphony.Runners.RaxolAgent do
  @moduledoc """
  Default Symphony runner: drives a coding agent via the `raxol_agent` Stream
  API.

  Implements SPEC s7.1's continuation contract:

  - Each `run/3` invocation runs up to `agent.max_turns` back-to-back turns.
  - After each successful turn, the runner re-checks the tracker. If the
    issue remains in an active state and turns remain, it starts another turn
    with a continuation prompt.
  - If the issue moves to a terminal/non-active state, the runner returns
    `:ok` and the orchestrator handles cleanup.

  Stream events are forwarded to the orchestrator parent as
  `{:run_event, issue.id, event_map}` so the orchestrator can update token
  counters and surface progress to UI consumers.

  ## Workflow extension shape

      runner:
        kind: raxol_agent
        agent:
          backend: anthropic        # mock | anthropic | openai | ollama | kimi
          model: claude-sonnet-4-6
          api_key: $ANTHROPIC_API_KEY
          base_url: https://api.anthropic.com
          max_tokens: 4096
          system_prompt: "You are a software engineer..."
          # actions: list of fully-qualified action modules (Phase 4: ignored;
          # tool use lands in a later phase together with hook integration)
          pause_detector: {MyApp.PauseDetector, :detect}
          tracker_cache: {Raxol.Agent.Cache.Ets, %{table: :tracker_cache}}
          tracker_cache_ttl_ms: 30_000

  ## Tracker result caching

  Optional: set `agent.tracker_cache` to a `{module, config}` tuple
  (or a bare `Raxol.Agent.Cache`-impl module) and the runner will
  cache `still_active?` results between turn boundaries. Cache key is
  `{:tracker, issue.id}`; default TTL is 30s, overridden by
  `agent.tracker_cache_ttl_ms`. The cache is opt-in: leaving
  `tracker_cache` unset preserves the existing per-turn-boundary
  query behavior.

  Trade-off: with caching enabled, a tracker state change during the
  TTL window is not seen until the TTL expires. Use a short TTL for
  fast-moving issue queues; use no cache (default) when freshness
  matters more than HTTP cost.

  ## Pause detection

  When `agent.pause_detector` is set, the runner consults the detector
  on every event in the agent stream. The detector signature is:

      detect(event :: term()) ::
        :continue
        | {:pause, interrupt_reason :: atom(), resume_token :: term()}

  Returning `:continue` falls through to the normal forwarding path.
  Returning `{:pause, reason, token}` halts stream consumption and
  bubbles up as a `{:pause, ...}` return from `run/3`; the orchestrator
  then parks the run (see `Raxol.Symphony.Orchestrator.handle_worker_exit`).

  Detection is bypassed when `agent.pause_detector` is `nil`, falling
  back to the legacy `EventForwarder.to_parent/3` path with no overhead.

  ## Compile-time optionality

  `raxol_agent` is an optional dep. If the consumer app does not include it,
  this runner returns `{:error, :raxol_agent_not_loaded}` at runtime.
  """

  @behaviour Raxol.Symphony.Runner

  require Logger

  alias Raxol.Symphony.{Config, Issue, PromptBuilder, Tracker}
  alias Raxol.Symphony.Runners.RaxolAgent.AgentWorkflow
  alias Raxol.Workflow.Compiled

  # raxol_agent is optional; the EventForwarder helper landed in 2.5+.
  # Builds against earlier versions fall through to `legacy_forward/3`.
  @compile {:no_warn_undefined, Raxol.Agent.EventForwarder}

  @impl true
  def run(%Issue{} = issue, %Config{} = config, opts) do
    cond do
      not raxol_agent_loaded?() ->
        {:error, :raxol_agent_not_loaded}

      workflow_mode?(config) ->
        run_via_workflow(issue, config, opts)

      true ->
        do_run(issue, config, opts)
    end
  end

  # --- Workflow-envelope path (Phase 6) ---

  defp workflow_mode?(%Config{runner: %{agent: agent}}) do
    Map.get(agent, :workflow_mode) == true
  end

  defp workflow_mode?(_), do: false

  defp run_via_workflow(%Issue{} = issue, %Config{} = config, opts) do
    resume_token = Keyword.get(opts, :resume_token)
    resume_value = Keyword.get(opts, :resume_value)
    max_turns = config.agent.max_turns

    with {:ok, backend, backend_opts} <- resolve_backend(config),
         {:ok, compiled} <-
           AgentWorkflow.compile(max_turns, workflow_compile_opts(config)) do
      case resume_token do
        %{workflow_run_id: run_id} when not is_nil(run_id) and not is_nil(resume_value) ->
          compiled
          |> Compiled.resume(run_id, resume_value)
          |> translate_workflow_result(issue)

        _ ->
          run_id = generate_workflow_run_id(issue, opts)
          state = build_workflow_state(issue, config, opts, backend, backend_opts)

          compiled
          |> Compiled.invoke(state, run_id: run_id)
          |> translate_workflow_result(issue)
      end
    end
  end

  defp workflow_compile_opts(%Config{runner: %{agent: agent}}) do
    # The workflow runtime's Compiled.resume/4 requires a Saver
    # (otherwise it returns {:error, :no_saver_configured, _}). Default
    # to a shared in-memory ETS table; consumers wanting BEAM-restart
    # durability override via agent.workflow_saver, typically to
    # `{Raxol.Workflow.Checkpoint.Saver.Dets, %{name: ...}}` or the
    # Postgrex equivalent.
    saver =
      Map.get(agent, :workflow_saver) ||
        {Raxol.Workflow.Checkpoint.Saver.Ets,
         %{table: :raxol_symphony_agent_workflow}}

    [saver: saver]
  end

  defp build_workflow_state(issue, config, opts, backend, backend_opts) do
    parent = Keyword.fetch!(opts, :parent)
    attempt = Keyword.get(opts, :attempt)

    %{
      issue: issue,
      config: config,
      parent: parent,
      attempt: attempt,
      backend: backend,
      backend_opts: backend_opts,
      system_prompt: agent_string(config, :system_prompt),
      pause_detector: agent_pause_detector(config),
      turn: 1,
      max_turns: config.agent.max_turns,
      last_events: [],
      pause_request: nil,
      last_resume_value: nil,
      run_result: nil,
      next_step: nil,
      # Optional tracker-result cache. `agent.tracker_cache` is a
      # `{module, config}` tuple (or `nil` for no caching) and
      # `agent.tracker_cache_ttl_ms` controls expiry. See
      # `__workflow_still_active__/1`.
      tracker_cache: agent_tracker_cache(config),
      tracker_cache_ttl_ms: agent_tracker_cache_ttl_ms(config),
      # Module-function refs the workflow nodes call. Kept in state so
      # the multi-node AgentWorkflow.run_turn/1 and after_turn/3 don't
      # have to depend on this module directly (which would create a
      # compile cycle).
      turn_body_fn: &__MODULE__.__workflow_collect_turn__/1,
      still_active_fn: &__MODULE__.__workflow_still_active__/1
    }
  end

  defp generate_workflow_run_id(%Issue{id: id}, opts) do
    attempt = Keyword.get(opts, :attempt) || 0
    "agent-#{id}-#{attempt}-#{:erlang.unique_integer([:positive])}"
  end

  defp translate_workflow_result({:ok, state, _meta}, _issue) do
    case Map.get(state, :run_result) do
      {:error, reason} -> {:error, reason}
      _ -> :ok
    end
  end

  defp translate_workflow_result({:interrupted, run_id, _state, reason}, issue) do
    {:pause, reason,
     %{
       workflow_run_id: run_id,
       issue_id: issue.id,
       paused_via: :workflow
     }}
  end

  defp translate_workflow_result({:error, reason, _state}, _issue) do
    {:error, reason}
  end

  defp translate_workflow_result({:error, reason}, _issue) do
    {:error, reason}
  end

  # --- Multi-node helpers (Phase 7) ---
  #
  # Called from `AgentWorkflow.run_turn/1`. Runs one turn and returns
  # `{events_list, pause_request_or_nil}`. The detector is consulted
  # per event; the FIRST event that yields `{:pause, ...}` queues the
  # pause but stream consumption continues -- pausing fires at the
  # turn boundary inside `:after_turn_N`, so the LLM turn is never
  # re-run on resume.

  @doc false
  def __workflow_collect_turn__(state) do
    prompt = build_prompt(state.issue, state.config, state.turn, state.attempt)

    stream =
      stream_module().run(prompt,
        backend: state.backend,
        backend_opts: state.backend_opts,
        system_prompt: state.system_prompt
      )

    collect_with_detector(stream, state.parent, state.issue.id, state.pause_detector)
  end

  defp collect_with_detector(stream, parent, issue_id, detector) do
    Enum.reduce(stream, {[], nil}, fn event, {events, pause_acc} ->
      send(parent, {:run_event, issue_id, legacy_payload(event)})
      payload = legacy_payload(event)
      events = [payload | events]

      pause_acc =
        case pause_acc do
          nil ->
            case apply_detector(detector, event) do
              {:pause, reason, token} when is_atom(reason) ->
                {:pause, reason, token}

              _ ->
                nil
            end

          existing ->
            existing
        end

      {events, pause_acc}
    end)
    |> then(fn {events, pause_acc} -> {Enum.reverse(events), pause_acc} end)
  end

  @doc false
  def __workflow_still_active__(%{tracker_cache: nil} = state) do
    still_active?(state.issue, state.config)
  end

  def __workflow_still_active__(%{tracker_cache: cache, issue: issue, config: config} = state) do
    key = {:tracker, issue.id}

    case Raxol.Agent.Cache.get(cache, key) do
      {:ok, cached} ->
        cached

      :miss ->
        result = still_active?(issue, config)
        ttl = Map.get(state, :tracker_cache_ttl_ms, 30_000)
        :ok = Raxol.Agent.Cache.put(cache, key, result, ttl)
        result
    end
  end

  defp do_run(%Issue{} = issue, %Config{} = config, opts) do
    parent = Keyword.fetch!(opts, :parent)
    attempt = Keyword.get(opts, :attempt)

    with {:ok, backend, backend_opts} <- resolve_backend(config) do
      run_turns(
        issue,
        config,
        %{
          parent: parent,
          attempt: attempt,
          backend: backend,
          backend_opts: backend_opts,
          system_prompt: agent_string(config, :system_prompt),
          pause_detector: agent_pause_detector(config),
          turn: 1,
          max_turns: config.agent.max_turns
        }
      )
    end
  end

  defp run_turns(
         %Issue{} = issue,
         %Config{} = config,
         %{turn: turn, max_turns: max} = ctx
       )
       when turn > max do
    Logger.info(
      "symphony.runners.raxol_agent.max_turns_reached issue=#{issue.identifier} turns=#{ctx.turn - 1}"
    )

    _ = config
    :ok
  end

  defp run_turns(%Issue{} = issue, %Config{} = config, ctx) do
    prompt = build_prompt(issue, config, ctx.turn, ctx.attempt)

    case run_one_turn(issue, prompt, ctx) do
      :ok -> continue_or_finish(issue, config, ctx)
      {:pause, _reason, _token} = pause -> pause
      {:error, reason} -> {:error, reason}
    end
  end

  defp continue_or_finish(%Issue{} = issue, %Config{} = config, ctx) do
    case still_active?(issue, config) do
      {:active, refreshed} ->
        run_turns(refreshed, config, %{ctx | turn: ctx.turn + 1})

      :done ->
        :ok

      {:error, _reason} ->
        # Tracker unavailable -- end this run; the orchestrator will retry.
        :ok
    end
  end

  defp run_one_turn(%Issue{} = issue, prompt, ctx) do
    stream =
      stream_module().run(prompt,
        backend: ctx.backend,
        backend_opts: ctx.backend_opts,
        system_prompt: ctx.system_prompt
      )

    cond do
      ctx.pause_detector ->
        forward_with_detector(stream, ctx.parent, issue.id, ctx.pause_detector)

      Code.ensure_loaded?(Raxol.Agent.EventForwarder) ->
        Raxol.Agent.EventForwarder.to_parent(stream, ctx.parent, issue.id)

      true ->
        legacy_forward(stream, ctx.parent, issue.id)
    end
  end

  # Pause-detector aware stream enumeration. Forwards every event the
  # same way `legacy_forward/3` does, but on each iteration also
  # consults the detector. If the detector returns `{:pause, _, _}`,
  # we stop pulling the stream and bubble the pause tuple up to
  # `run_turns/3` -> `run/3`, which the orchestrator parks via its
  # `:run_paused` handler.
  defp forward_with_detector(stream, parent, issue_id, detector) do
    Enum.reduce_while(stream, {:error, :no_done}, fn event, _acc ->
      send(parent, {:run_event, issue_id, legacy_payload(event)})

      case apply_detector(detector, event) do
        {:pause, reason, token} when is_atom(reason) ->
          {:halt, {:pause, reason, token}}

        _ ->
          case event do
            {:done, _info} -> {:halt, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
            _ -> {:cont, {:error, :no_done}}
          end
      end
    end)
    |> case do
      :ok -> :ok
      {:pause, _, _} = pause -> pause
      {:error, reason} -> {:error, reason}
    end
  end

  defp apply_detector({mod, fun}, event) when is_atom(mod) and is_atom(fun) do
    apply(mod, fun, [event])
  end

  defp apply_detector(fun, event) when is_function(fun, 1) do
    fun.(event)
  end

  defp apply_detector(_, _), do: :continue

  # Fallback for builds where raxol_agent < 2.5 is loaded.
  defp legacy_forward(stream, parent, issue_id) do
    Enum.reduce_while(stream, {:error, :no_done}, fn event, _acc ->
      send(parent, {:run_event, issue_id, legacy_payload(event)})

      case event do
        {:done, _info} -> {:halt, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        _ -> {:cont, {:error, :no_done}}
      end
    end)
    |> case do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp legacy_payload({:text_delta, text}),
    do: %{event: :text_delta, message: text, timestamp: DateTime.utc_now()}

  defp legacy_payload({:tool_use, %{name: name} = info}),
    do: %{
      event: :tool_use,
      message: "tool_use: #{name}",
      payload: info,
      timestamp: DateTime.utc_now()
    }

  defp legacy_payload({:tool_result, info}),
    do: %{event: :tool_result, payload: info, timestamp: DateTime.utc_now()}

  defp legacy_payload({:turn_complete, info}),
    do: %{
      event: :turn_completed,
      usage: Map.get(info, :usage, %{}),
      timestamp: DateTime.utc_now()
    }

  defp legacy_payload({:done, info}),
    do: %{
      event: :turn_completed,
      usage: Map.get(info, :usage, %{}),
      timestamp: DateTime.utc_now()
    }

  defp legacy_payload({:error, reason}),
    do: %{
      event: :turn_failed,
      message: inspect(reason),
      timestamp: DateTime.utc_now()
    }

  defp still_active?(%Issue{id: id} = issue, %Config{} = config) do
    case Tracker.fetch_issue_states_by_ids(config, [id]) do
      {:ok, [%Issue{} = refreshed]} ->
        cond do
          Issue.terminal?(refreshed, config.tracker.terminal_states) ->
            :done

          Issue.active?(refreshed, config.tracker.active_states) ->
            {:active, refreshed}

          true ->
            :done
        end

      {:ok, []} ->
        :done

      {:error, _} = err ->
        # Conservative: if we can't tell, end this run rather than loop.
        _ = issue
        err
    end
  end

  # -- Backend resolution -----------------------------------------------------

  defp resolve_backend(%Config{runner: %{agent: agent}} = _config) do
    case agent_kind(agent) do
      "mock" ->
        {:ok, mock_backend(), backend_opts_for_mock(agent)}

      kind when kind in ~w(anthropic openai ollama kimi) ->
        case http_backend() do
          nil -> {:error, :http_backend_unavailable}
          mod -> {:ok, mod, backend_opts_for_http(kind, agent)}
        end

      other ->
        {:error, {:unsupported_backend, other}}
    end
  end

  defp agent_kind(agent) do
    agent
    |> Map.get(:backend, "mock")
    |> to_string()
    |> String.downcase()
  end

  defp backend_opts_for_mock(agent) do
    Keyword.new(
      response: Map.get(agent, :response, "mock response"),
      latency_ms: Map.get(agent, :latency_ms, 0)
    )
  end

  defp backend_opts_for_http(provider, agent) do
    base =
      [
        provider: String.to_atom(provider),
        api_key: Config.resolve_value(Map.get(agent, :api_key)),
        model: Map.get(agent, :model),
        max_tokens: Map.get(agent, :max_tokens, 4096),
        timeout: Map.get(agent, :timeout_ms, 60_000)
      ]
      |> maybe_put(:base_url, Map.get(agent, :base_url))

    Enum.reject(base, fn {_, v} -> is_nil(v) end)
  end

  defp maybe_put(kw, _key, nil), do: kw
  defp maybe_put(kw, key, value), do: Keyword.put(kw, key, value)

  defp agent_string(%Config{runner: %{agent: agent}}, key) do
    case Map.get(agent, key) do
      nil -> nil
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp agent_pause_detector(%Config{runner: %{agent: agent}}) do
    Map.get(agent, :pause_detector)
  end

  defp agent_tracker_cache(%Config{runner: %{agent: agent}}) do
    Raxol.Agent.Cache.normalize(Map.get(agent, :tracker_cache))
  end

  defp agent_tracker_cache(_), do: nil

  defp agent_tracker_cache_ttl_ms(%Config{runner: %{agent: agent}}) do
    Map.get(agent, :tracker_cache_ttl_ms, 30_000)
  end

  defp agent_tracker_cache_ttl_ms(_), do: 30_000

  # -- Prompt building (Liquid via PromptBuilder) -----------------------------

  defp build_prompt(
         %Issue{} = issue,
         %Config{prompt_template: template},
         1,
         attempt
       ) do
    case PromptBuilder.build(issue, template, attempt) do
      {:ok, rendered} ->
        rendered

      {:error, reason} ->
        Logger.warning(
          "symphony.runners.raxol_agent.prompt_build_failed issue=#{issue.identifier} reason=#{inspect(reason)}"
        )

        PromptBuilder.default_prompt()
    end
  end

  defp build_prompt(%Issue{} = issue, %Config{} = _config, turn, _attempt) do
    """
    Continuation guidance:

    - The previous agent turn completed normally, but the issue #{issue.identifier} is still in an active state.
    - This is continuation turn ##{turn}.
    - Resume from the current workspace state instead of restarting from scratch.
    - Focus on the remaining work and stop only when the issue reaches the next handoff state or is truly blocked.
    """
  end

  # -- raxol_agent module loading -------------------------------------------

  defp raxol_agent_loaded? do
    Code.ensure_loaded?(stream_module())
  end

  defp stream_module, do: Raxol.Agent.Stream
  defp mock_backend, do: Raxol.Agent.Backend.Mock

  defp http_backend do
    if Code.ensure_loaded?(Raxol.Agent.Backend.HTTP),
      do: Raxol.Agent.Backend.HTTP,
      else: nil
  end
end
