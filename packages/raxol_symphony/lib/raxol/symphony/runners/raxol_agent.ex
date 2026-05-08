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

  ## Compile-time optionality

  `raxol_agent` is an optional dep. If the consumer app does not include it,
  this runner returns `{:error, :raxol_agent_not_loaded}` at runtime.
  """

  @behaviour Raxol.Symphony.Runner

  require Logger

  alias Raxol.Symphony.{Config, Issue, PromptBuilder, Tracker}

  # raxol_agent is optional; the EventForwarder helper landed in 2.5+.
  # Builds against earlier versions fall through to `legacy_forward/3`.
  @compile {:no_warn_undefined, Raxol.Agent.EventForwarder}

  @impl true
  def run(%Issue{} = issue, %Config{} = config, opts) do
    if raxol_agent_loaded?() do
      do_run(issue, config, opts)
    else
      {:error, :raxol_agent_not_loaded}
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

    if Code.ensure_loaded?(Raxol.Agent.EventForwarder) do
      Raxol.Agent.EventForwarder.to_parent(stream, ctx.parent, issue.id)
    else
      legacy_forward(stream, ctx.parent, issue.id)
    end
  end

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
