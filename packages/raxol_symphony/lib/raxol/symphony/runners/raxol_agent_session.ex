defmodule Raxol.Symphony.Runners.RaxolAgentSession do
  @moduledoc """
  Symphony `Runner` impl that drives a full `Raxol.Agent.Session`
  (the TEA-pattern Agent SDK) per run.

  Differs from `Raxol.Symphony.Runners.RaxolAgent` (the
  `Stream.run`-based runner): this one wires the agent module
  through the full SDK lifecycle so `Raxol.Agent.CommandHook`
  hooks fire on directives the agent emits. The `SandboxHook`
  prepended by `Raxol.Agent.effective_hooks/1` enforces declared
  `sandbox/0` policies on every directive automatically.

  ## Required config

      runner:
        kind: raxol_agent_session
        agent:
          module: MyApp.MyAgent

  `agent.module` MUST be a `use Raxol.Agent` module (or one that
  otherwise exports the TEA callbacks Lifecycle requires).

  ## Contract between Symphony and the agent module

  Symphony sends a single seed message into the agent's mailbox:

      {:symphony_start, %{
        issue: %Raxol.Symphony.Issue{},
        prompt: rendered_template_string,
        attempt: integer_or_nil
      }}

  The agent's `update/2` handles this however it wants. To complete,
  the agent emits one of these to its `Raxol.Agent.SessionStreamer`
  topic (the session id is provided in the seed message's optional
  `session_id` field):

      Raxol.Agent.SessionStreamer.emit(session_id, {:done, info})
      Raxol.Agent.SessionStreamer.emit(session_id, {:error, reason})

  Stream events emitted as `{:text_delta, _}`, `{:tool_use, _}`,
  `{:tool_result, _}`, `{:turn_complete, _}` are forwarded to the
  parent as `{:run_event, issue.id, payload}` so the orchestrator
  surfaces them like the Stream-based runner does.

  ## Timeout

  If no `{:done, _}` or `{:error, _}` event arrives within
  `agent.session_timeout_ms` (default 60_000), the runner returns
  `{:error, :session_timeout}` and stops the Session. The
  orchestrator's failure-retry layer takes over.

  ## Pause/resume

  Not yet wired. The Session-side pause contract is a future
  follow-up; for now any pause-style return from this runner is
  treated as an abnormal exit.
  """

  @behaviour Raxol.Symphony.Runner

  require Logger

  alias Raxol.Symphony.{Config, Issue, PromptBuilder, Runner}

  @compile {:no_warn_undefined,
            [Raxol.Agent.Session, Raxol.Agent.SessionStreamer]}

  @default_timeout_ms 60_000

  @impl Runner
  def run(%Issue{} = issue, %Config{} = config, opts) do
    cond do
      not raxol_agent_loaded?() ->
        {:error, :raxol_agent_not_loaded}

      is_nil(agent_module(config)) ->
        {:error, :agent_module_required}

      true ->
        do_run(issue, config, opts)
    end
  end

  defp do_run(%Issue{} = issue, %Config{} = config, opts) do
    parent = Keyword.fetch!(opts, :parent)
    attempt = Keyword.get(opts, :attempt)
    module = agent_module(config)
    timeout_ms = session_timeout_ms(config)
    session_id = build_session_id(issue, attempt)

    Code.ensure_loaded(module)

    with :ok <- ensure_session_streamer(),
         :ok <- subscribe(session_id),
         {:ok, _pid} <- start_session(session_id, module) do
      try do
        seed_agent(session_id, issue, config, attempt)
        loop(session_id, issue.id, parent, timeout_ms)
      after
        unsubscribe(session_id)
        stop_session(session_id)
      end
    else
      {:error, reason} ->
        {:error, {:session_setup_failed, reason}}
    end
  end

  # -- Loop --

  defp loop(session_id, issue_id, parent, timeout_ms) do
    receive do
      {:session_event, ^session_id, {:done, _info}} ->
        :ok

      {:session_event, ^session_id, {:error, reason}} ->
        {:error, reason}

      {:session_event, ^session_id, event} ->
        send(parent, {:run_event, issue_id, event_payload(event)})
        loop(session_id, issue_id, parent, timeout_ms)
    after
      timeout_ms ->
        {:error, :session_timeout}
    end
  end

  defp event_payload({tag, info}) when is_atom(tag) and is_map(info) do
    Map.put(info, :event, tag)
  end

  defp event_payload({tag, info}) when is_atom(tag) do
    %{event: tag, info: info}
  end

  defp event_payload(other), do: %{event: :unknown, raw: other}

  # -- Session setup --

  defp ensure_session_streamer do
    case Process.whereis(Raxol.Agent.SessionStreamer) do
      nil ->
        case Raxol.Agent.SessionStreamer.start_link([]) do
          {:ok, _} -> :ok
          {:error, {:already_started, _}} -> :ok
          {:error, reason} -> {:error, {:session_streamer, reason}}
        end

      _pid ->
        :ok
    end
  end

  defp subscribe(session_id) do
    Raxol.Agent.SessionStreamer.subscribe(session_id)
    :ok
  catch
    :exit, reason -> {:error, {:subscribe, reason}}
  end

  defp unsubscribe(session_id) do
    Raxol.Agent.SessionStreamer.unsubscribe(session_id)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp start_session(session_id, module) do
    Raxol.Agent.Session.start_link(id: session_id, app_module: module)
  catch
    :exit, reason -> {:error, {:start_link, reason}}
  end

  defp stop_session(session_id) do
    case Registry.lookup(Raxol.Agent.Registry, session_id) do
      [{pid, _}] ->
        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

      [] ->
        :ok
    end
  end

  defp seed_agent(session_id, issue, config, attempt) do
    payload = %{
      issue: issue,
      prompt: build_prompt(issue, config, attempt),
      attempt: attempt,
      session_id: session_id
    }

    Raxol.Agent.Session.send_message(session_id, {:symphony_start, payload})
    :ok
  end

  # -- Helpers --

  defp agent_module(%Config{runner: %{agent: %{module: mod}}}) when is_atom(mod), do: mod
  defp agent_module(_), do: nil

  defp session_timeout_ms(%Config{runner: %{agent: agent}}) do
    case Map.get(agent, :session_timeout_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_timeout_ms
    end
  end

  defp build_session_id(%Issue{id: id}, attempt),
    do: "symphony-session-#{id}-#{attempt || 0}-#{:erlang.unique_integer([:positive])}"

  defp build_prompt(issue, config, attempt) do
    case PromptBuilder.build(issue, config.prompt_template, attempt) do
      {:ok, rendered} -> rendered
      _ -> PromptBuilder.default_prompt()
    end
  end

  defp raxol_agent_loaded?, do: Code.ensure_loaded?(Raxol.Agent.Session)
end
