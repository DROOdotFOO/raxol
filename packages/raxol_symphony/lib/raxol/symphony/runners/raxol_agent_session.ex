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

  The agent signals a pause by emitting:

      Raxol.Agent.SessionStreamer.emit(session_id, {:paused, %{
        reason: :awaiting_buyer_payment,
        token: %{...arbitrary runner-side context...}
      }})

  The runner returns `{:pause, reason, token}` where `token` carries
  the `session_id` so the orchestrator's later `resume_run/3` call
  can re-attach to the same live Session. The Session runs as a
  supervised subtree under `Raxol.Agent.DynSup` (via
  `Raxol.Agent.Session.Supervisor`), so it survives the worker exit
  that follows the pause return.

  On resume the runner sends:

      {:symphony_resume, %{resume_value: rv, session_id: id}}

  into the same Session's mailbox and loops for events as before.
  If the Session is no longer in the Registry (e.g. the BEAM
  restarted), resume returns `{:error, :session_not_found}` and
  the orchestrator's retry-on-error path kicks in.

  ## Prompt caching

  Optional: set `agent.prompt_cache` to a `{module, config}` tuple
  (or a bare `Raxol.Agent.Cache`-impl module) and the runner will
  cache the rendered prompt across fresh runs. The cache key is
  `{:prompt, issue.id}` -- a stable per-issue slot. The stored value
  is `{fingerprint, rendered}`, where `fingerprint` is
  `sha256({issue, prompt_template, attempt})`. The TTL defaults to
  300s, overridden by `agent.prompt_cache_ttl_ms`.

  Unlike `RaxolAgent`'s `tracker_cache` (which caches a network
  `still_active?` check and so trades freshness for HTTP cost), this
  cache is **self-invalidating**, but the freshness check lives in the
  stored fingerprint rather than in the key. The rendered prompt is a
  pure function of `{issue, template, attempt}` (the whole `%Issue{}`
  is fingerprinted, so the check can never drift from what the template
  renders -- and note `attempt` DOES affect the render, since
  `PromptBuilder` exposes it as the `{{ attempt }}` Liquid variable).
  On a `get`, a fingerprint mismatch (any change to the issue content,
  template, or attempt -- including the initial `attempt: nil` dispatch
  versus its `attempt: 1` continuation) is treated as a miss and the
  entry is re-rendered and overwritten. A stale render is therefore
  **never served**. It is opt-in and **off by default**
  (`prompt_cache` unset preserves the existing per-run render).

  ### Bounding

  Keying on the stable `issue.id` (not on the fingerprint) is what
  makes the cache bounded, via three cooperating mechanisms:

    * **Overwrite on the freshness miss.** A fingerprint mismatch
      re-renders and `put`s under the same key, so an issue holds at
      most one row at a time. The initial `attempt: nil` render is
      reclaimed by the overwrite its first `attempt: 1` continuation
      performs -- it is not a permanent orphan.
    * **Read-once delete on the exact hit.** A continuation re-dispatch
      of an unchanged issue at an unchanged attempt (the hit case:
      consecutive `attempt: 1` continuations render the same prompt)
      reads the entry and **deletes it on that read**, so a continued
      issue oscillates between one and zero rows.
    * **Terminal flush.** `flush_prompt_cache/2` deletes an issue's row
      by `issue.id`. The orchestrator calls it at *every* site an issue
      leaves the run set for good: a retry that finds it terminal, gone,
      or no longer active; a user `stop_run` (whether it was running or
      paused); and a reconcile-kill. This reclaims the single row a
      one-shot issue (completes on first dispatch, no continuation reads
      it), or an odd-length continuation chain, leaves behind. Because
      the key is `issue.id` alone, this works even though the issue's
      content (and thus its fingerprint) has changed by the time it is
      observed terminal.

  Together these give a true `O(issues currently in-flight)` bound, not
  `O(issues ever processed)`: every path that drops an issue's claim also
  flushes its row (the shared `remove_running` helper is *not* flushed
  in-place, because the stall path reuses it before re-dispatching; the
  terminal callers flush at their own call sites instead), so no row
  outlives the run that wrote it. The TTL is therefore not a correctness
  backstop for that bound -- a row whose issue has moved on is never
  `get` again, so `Cache.Ets`'s lazy expiry (only a same-key `get`
  reclaims a stale entry) could not fire for it in any case. The TTL's
  sole job is to cap the staleness of a row that is rewritten in place
  while its issue is still in-flight. There is no background sweeper.

  ### Relationship to `PromptBuilder`'s template memo

  This layers ON TOP of `PromptBuilder`'s parsed-template memo, it does
  not duplicate it. The two cache different stages of the same pipeline:

    * `PromptBuilder` memoizes the **parsed Liquid AST**, keyed by the
      template string. That is shared across *every* issue using a given
      `WORKFLOW.md` and always on -- it removes the re-parse cost.
    * This `prompt_cache` memoizes the **fully rendered prompt**. It
      removes the per-issue variable substitution too, but only for the
      narrow hit case above.

  So on a continuation re-dispatch of an unchanged issue, the parse is
  skipped by `PromptBuilder` and the render is skipped here. The render
  is CPU-bound (not a network call) and the AST is already memoized, so
  this second layer's marginal win is small -- which is exactly why it is
  off by default and worth enabling only for high-churn continuation
  queues where the render cost is measured to matter.
  """

  @behaviour Raxol.Symphony.Runner

  alias Raxol.Symphony.{Config, Issue, PromptBuilder, Runner}

  @compile {:no_warn_undefined,
            [
              Raxol.Agent.Cache,
              Raxol.Agent.Session,
              Raxol.Agent.Session.Supervisor,
              Raxol.Agent.SessionStreamer
            ]}

  @default_timeout_ms 60_000
  @default_prompt_cache_ttl_ms 300_000

  @impl Runner
  def run(%Issue{} = issue, %Config{} = config, opts) do
    resume_token = Keyword.get(opts, :resume_token)
    resume_value = Keyword.get(opts, :resume_value)

    cond do
      not raxol_agent_loaded?() ->
        {:error, :raxol_agent_not_loaded}

      is_nil(agent_module(config)) ->
        {:error, :agent_module_required}

      resume_token_present?(resume_token) ->
        resume_run(issue, config, opts, resume_token, resume_value)

      true ->
        fresh_run(issue, config, opts)
    end
  end

  defp resume_token_present?(%{session_id: id}) when is_binary(id), do: true
  defp resume_token_present?(_), do: false

  defp fresh_run(%Issue{} = issue, %Config{} = config, opts) do
    parent = Keyword.fetch!(opts, :parent)
    attempt = Keyword.get(opts, :attempt)
    module = agent_module(config)
    timeout_ms = session_timeout_ms(config)
    session_id = build_session_id(issue, attempt)

    Code.ensure_loaded(module)

    with :ok <- ensure_session_streamer(),
         :ok <- subscribe(session_id),
         {:ok, _pid} <- start_session(session_id, module) do
      seed_agent(session_id, issue, config, attempt)

      case loop(session_id, issue.id, parent, timeout_ms) do
        :ok ->
          finalize(session_id, :ok)

        {:error, _} = err ->
          finalize(session_id, err)

        {:pause, _, _} = pause ->
          # Session keeps running under DynSup; runner detaches only.
          unsubscribe(session_id)
          pause
      end
    else
      {:error, reason} ->
        unsubscribe(session_id)
        stop_session(session_id)
        {:error, {:session_setup_failed, reason}}
    end
  end

  defp resume_run(
         %Issue{} = issue,
         %Config{} = config,
         opts,
         resume_token,
         resume_value
       ) do
    parent = Keyword.fetch!(opts, :parent)
    timeout_ms = session_timeout_ms(config)
    %{session_id: session_id} = resume_token

    case Registry.lookup(Raxol.Agent.Registry, session_id) do
      [] ->
        {:error, :session_not_found}

      [{_pid, _}] ->
        with :ok <- ensure_session_streamer(),
             :ok <- subscribe(session_id) do
          send_resume(session_id, resume_value)

          case loop(session_id, issue.id, parent, timeout_ms) do
            :ok ->
              finalize(session_id, :ok)

            {:error, _} = err ->
              finalize(session_id, err)

            {:pause, _, _} = pause ->
              unsubscribe(session_id)
              pause
          end
        else
          {:error, reason} -> {:error, {:session_setup_failed, reason}}
        end
    end
  end

  defp finalize(session_id, result) do
    unsubscribe(session_id)
    stop_session(session_id)
    result
  end

  # -- Loop --

  defp loop(session_id, issue_id, parent, timeout_ms) do
    receive do
      {:session_event, ^session_id, {:done, _info}} ->
        :ok

      {:session_event, ^session_id, {:error, reason}} ->
        {:error, reason}

      {:session_event, ^session_id, {:paused, info}} ->
        reason = Map.get(info, :reason, :awaiting_external)
        token = Map.get(info, :token, %{})
        full_token = Map.put(token, :session_id, session_id)
        {:pause, reason, full_token}

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
    # Start the session as a supervised SUBTREE (EmitBridge -> Lifecycle ->
    # Session, `:rest_for_one`) under `Raxol.Agent.DynSup`, not as a bare
    # Session child. The tree still survives the worker exit that follows a
    # `{:pause, ...}` return, but -- unlike a bare Session -- it cannot
    # deadlock: a bare `Raxol.Agent.Session` starts its own EmitBridge under the
    # SAME `Raxol.Agent.DynSup` during init, which blocks forever behind the
    # in-progress start (a DynamicSupervisor runs a child's init synchronously
    # inside its own call). The subtree owns the bridge as a sibling instead.
    # `id` and `session_id` are pinned equal so registration, `send_message`,
    # `subscribe`, and `stop_session` all key on the runner's `session_id`.
    case Raxol.Agent.Session.Supervisor.start_session(module,
           id: session_id,
           session_id: session_id
         ) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:start_child, reason}}
    end
  catch
    :exit, reason -> {:error, {:start_child, reason}}
  end

  defp send_resume(session_id, resume_value) do
    Raxol.Agent.Session.send_message(session_id, {
      :symphony_resume,
      %{session_id: session_id, resume_value: resume_value}
    })

    :ok
  end

  defp stop_session(session_id) do
    # Tears down the whole subtree (session -> lifecycle -> bridge), draining
    # the durable tail first. Best-effort: a missing/already-gone session is a
    # no-op, and a dying supervisor mid-teardown must not fail finalize.
    Raxol.Agent.Session.Supervisor.stop_session(session_id)
    :ok
  catch
    :exit, _ -> :ok
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

  defp agent_module(%Config{runner: %{agent: %{module: mod}}})
       when is_atom(mod), do: mod

  defp agent_module(_), do: nil

  defp session_timeout_ms(%Config{runner: %{agent: agent}}) do
    case Map.get(agent, :session_timeout_ms) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_timeout_ms
    end
  end

  defp build_session_id(%Issue{id: id}, attempt),
    do:
      "symphony-session-#{id}-#{attempt || 0}-#{:erlang.unique_integer([:positive])}"

  @doc """
  Removes any prompt-cache row for `issue_id`.

  A no-op when no `prompt_cache` is configured. The orchestrator calls
  this when an issue leaves the run set (terminal or dropped) so a
  one-shot render -- written on the issue's only dispatch and never
  read by a continuation -- does not linger. Keying on `issue.id`
  alone (not the freshness fingerprint) means this reclaims the row
  even though the issue's content, and thus its fingerprint, has
  changed by the time it is observed terminal.
  """
  @spec flush_prompt_cache(Config.t(), term()) :: :ok
  def flush_prompt_cache(%Config{} = config, issue_id) do
    Raxol.Agent.Cache.delete(agent_prompt_cache(config), prompt_cache_key(issue_id))
  end

  # Renders the seed prompt, optionally through the opt-in prompt cache.
  defp build_prompt(issue, config, attempt),
    do: render_cached(agent_prompt_cache(config), issue, config, attempt)

  # No cache configured (the default): render directly, unchanged behaviour.
  defp render_cached(nil, issue, config, attempt),
    do: render_prompt(issue, config, attempt)

  # Cache configured: reuse the memoized render, or compute and store it.
  # The key is the stable `issue.id`; freshness is guarded by a fingerprint
  # stored alongside the render, so the cache stays bounded per issue (see the
  # "Prompt caching" moduledoc section).
  defp render_cached(cache, issue, config, attempt) do
    key = prompt_cache_key(issue.id)
    fingerprint = prompt_fingerprint(issue, config.prompt_template, attempt)

    case Raxol.Agent.Cache.get(cache, key) do
      {:ok, {^fingerprint, cached}} ->
        # Exact hit (unchanged issue + template + attempt). Read-once: the
        # continuation re-dispatch is the only reader, so flush the row as it
        # is consumed. A continued issue thus oscillates between one and zero
        # rows instead of lingering.
        Raxol.Agent.Cache.delete(cache, key)
        cached

      _miss_or_stale ->
        # Miss, or a stale fingerprint (issue/template/attempt changed --
        # e.g. the initial `attempt: nil` row seen by an `attempt: 1`
        # continuation). Re-render and overwrite under the same key, so the
        # prior row is reclaimed and a stale render is never served.
        rendered = render_prompt(issue, config, attempt)

        :ok =
          Raxol.Agent.Cache.put(
            cache,
            key,
            {fingerprint, rendered},
            agent_prompt_cache_ttl_ms(config)
          )

        rendered
    end
  end

  defp render_prompt(issue, config, attempt) do
    case PromptBuilder.build(issue, config.prompt_template, attempt) do
      {:ok, rendered} -> rendered
      _ -> PromptBuilder.default_prompt()
    end
  end

  defp prompt_cache_key(issue_id), do: {:prompt, issue_id}

  # The rendered prompt is a pure function of (issue, template, attempt), so
  # the whole `%Issue{}` is fingerprinted rather than a hand-listed subset:
  # any field change -> a new fingerprint, with zero risk of drifting out of
  # sync with what the template renders. A fingerprint mismatch only costs a
  # re-render (never a stale prompt) -- the safe direction for a
  # self-invalidating cache.
  defp prompt_fingerprint(%Issue{} = issue, template, attempt) do
    :crypto.hash(
      :sha256,
      :erlang.term_to_binary({issue, template, attempt}, [:deterministic])
    )
  end

  # `config.runner` is always a map (`Config` builds it so), but `get_in`
  # tolerates a nil/blank runner or a missing `:agent`/key -- a single
  # total clause, so there is no provably-dead catch-all to warn on.
  defp agent_prompt_cache(%Config{runner: runner}),
    do: Raxol.Agent.Cache.normalize(get_in(runner, [:agent, :prompt_cache]))

  defp agent_prompt_cache_ttl_ms(%Config{runner: runner}),
    do:
      get_in(runner, [:agent, :prompt_cache_ttl_ms]) ||
        @default_prompt_cache_ttl_ms

  defp raxol_agent_loaded?, do: Code.ensure_loaded?(Raxol.Agent.Session)
end
