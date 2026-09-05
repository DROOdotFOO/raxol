defmodule Raxol.Symphony.Runners.Codex do
  @moduledoc """
  Codex app-server runner.

  Drives `codex app-server` (or any compatible binary configured via
  `codex.command`) inside the per-issue workspace. Speaks JSON-RPC 2.0 over
  stdio, performs the standard `initialize` -> `initialized` -> `thread/start`
  handshake once per run, and then issues one or more `turn/start` cycles
  while the issue stays in an active tracker state.

  Mirrors the Codex client used by the OpenAI Symphony Elixir reference
  impl, so workflows authored against upstream Codex run identically here.

  ## Continuation contract

  Same shape as `Runners.RaxolAgent`:

  - Each `run/3` invocation runs up to `agent.max_turns` back-to-back turns.
  - After each successful turn, the runner re-checks the tracker. If the
    issue is still active and turns remain, the next `turn/start` is sent
    over the same stdio session.
  - If the issue moves to a terminal state, the runner returns `:ok`.
  - On `turn/failed` / `turn/cancelled` / port exit / approval denial /
    timeout, returns `{:error, reason}` so the orchestrator can schedule
    a retry per `agent.max_retry_backoff_ms`.

  ## Workflow extension shape

      runner:
        kind: codex
      codex:
        command: codex app-server
        approval_policy: never
        thread_sandbox: workspace-write
        turn_sandbox_policy: {}
        turn_timeout_ms: 3600000
        read_timeout_ms: 5000

  When `approval_policy == "never"`, command-execution / file-change /
  exec-command / apply-patch approvals are auto-approved. Any other policy
  surfaces the approval to the orchestrator as
  `{:pause, :awaiting_approval, %{decision: ..., issue_id: ..., turn: ...,
  approvals_granted: ..., paused_at: ...}}`,
  which `Raxol.Symphony.Orchestrator` parks via `park_paused/4`. An
  operator drives the resolution with
  `Orchestrator.resume_run(pid, issue_id, decision)`, passing `:approved`
  or `:rejected` (the MCP surface sends them as strings; both spellings
  are accepted).

  A rejection ends THIS ATTEMPT with `{:error, :approval_rejected}`. Nothing
  can carry the "no" to Codex -- the paused session died with the pause -- so
  the agent cannot be talked out of asking. It does not end the run: the
  orchestrator treats a runner error as a failure, so it re-dispatches the
  issue after the usual backoff, uncapped, and the agent asks again. The
  re-dispatch also increments `attempt`, which the prompt reports, so the
  agent is told it is retrying a failed attempt when nothing failed.
  "Reject" is not a stop button; `Orchestrator.stop_run/2` is.

  An approval starts a FRESH Codex session, and the grant has to survive that
  respawn or the run cannot move: the new session replays from the top and
  hits the same approval point, so a grant covering only the dead session
  would leave the run asking the same question forever. The pause token
  carries `approvals_granted`, the number of approval points an operator has
  already cleared for this run. On an approval that count goes up by one and
  the fresh session answers that many requests before pausing on the next, so
  each resume clears exactly one more approval point and the run advances.

  The grant is positional, not bound to the action the operator read. A
  fresh session is free to propose different work, so request #n after the
  respawn is only usually the request #n that was approved. Closing that
  gap means holding the paused session open rather than respawning it.

  An `:awaiting_approval` run event is emitted at the moment of the pause
  and a `:resumed` event when the orchestrator dispatches the resumption.

  Tool calls (`item/tool/call`) currently respond with an "unsupported"
  result; dynamic-tool registration lands in a follow-up.
  """

  @behaviour Raxol.Symphony.Runner

  require Logger

  alias Raxol.Symphony.{Config, Issue, PromptBuilder, Tracker}
  alias Raxol.Symphony.Runners.Codex.{Auth, Session}

  @impl Raxol.Symphony.Runner
  def pause_reasons, do: [:awaiting_approval]

  @impl Raxol.Symphony.Runner
  def run(%Issue{} = issue, %Config{} = config, opts) do
    parent = Keyword.fetch!(opts, :parent)
    attempt = Keyword.get(opts, :attempt)
    workspace_path = Keyword.fetch!(opts, :workspace_path)
    host = Keyword.get(opts, :host)
    resume_value = Keyword.get(opts, :resume_value)
    resume_token = Keyword.get(opts, :resume_token)

    with :ok <- check_codex_installed(config),
         auth = Auth.resolve(config.codex),
         :ok <- Auth.emit(auth),
         :ok <- Auth.gate(config.codex, auth) do
      maybe_emit_resumed(parent, issue, resume_value, resume_token)

      resume_or_run(issue, config, approval_decision(resume_value), %{
        parent: parent,
        attempt: attempt,
        workspace_path: workspace_path,
        host: host,
        turn: 1,
        max_turns: config.agent.max_turns,
        auth_env: auth.env,
        granted_approvals: granted_approvals(resume_token)
      })
    end
  end

  # The MCP surface resumes with the raw JSON value, so the same decision
  # arrives as a string there and as an atom from the TUI. Anything else
  # carries no approval: the run starts over and pauses again, which is the
  # fail-closed answer for a decision we cannot read.
  defp approval_decision(decision) when decision in [:approved, "approved"], do: :approved
  defp approval_decision(decision) when decision in [:rejected, "rejected"], do: :rejected
  defp approval_decision(_), do: :none

  # How many approval points this run has already cleared. A token from
  # anywhere but our own `pause_for_approval/3` counts as none cleared, so a
  # malformed one costs a re-ask rather than a blanket grant.
  defp granted_approvals(%{approvals_granted: n}) when is_integer(n) and n >= 0, do: n
  defp granted_approvals(_), do: 0

  defp resume_or_run(_issue, _config, :rejected, _ctx), do: {:error, :approval_rejected}

  # The approval the operator just gave is the (n+1)th this run has cleared,
  # so the fresh session answers that many before it pauses again. Without
  # the increment every resume would stop at the same request.
  defp resume_or_run(issue, config, :approved, ctx),
    do: do_run(issue, config, %{ctx | granted_approvals: ctx.granted_approvals + 1})

  defp resume_or_run(issue, config, :none, ctx), do: do_run(issue, config, ctx)

  # Operator-driven resume: announce that the run is starting over with
  # the supplied decision. The orchestrator parks paused runs with the
  # original `resume_token` (the pause payload) so observers can
  # correlate which approval the decision applied to.
  defp maybe_emit_resumed(_parent, _issue, nil, _token), do: :ok

  defp maybe_emit_resumed(parent, %Issue{} = issue, resume_value, resume_token)
       when is_pid(parent) do
    send(
      parent,
      {:run_event, issue.id,
       %{
         event: :resumed,
         message: "resumed with decision=#{inspect(resume_value)}",
         payload: %{decision: resume_value, resume_token: resume_token},
         timestamp: DateTime.utc_now()
       }}
    )

    :ok
  end

  defp do_run(%Issue{} = issue, %Config{} = config, ctx) do
    policy = build_policy(config, ctx.granted_approvals)
    env = Map.get(ctx, :auth_env, [])

    case Session.start(ctx.workspace_path, config.codex.command, policy, env, Map.get(ctx, :host)) do
      {:ok, session} ->
        try do
          run_turns(session, issue, config, ctx)
        after
          Session.stop(session)
        end

      {:error, _} = err ->
        err
    end
  end

  defp run_turns(_session, %Issue{} = issue, %Config{} = _config, %{
         turn: turn,
         max_turns: max_turns
       })
       when turn > max_turns do
    Logger.info(
      "symphony.runners.codex.max_turns_reached issue=#{issue.identifier} turns=#{turn - 1}"
    )

    :ok
  end

  defp run_turns(session, %Issue{} = issue, %Config{} = config, ctx) do
    prompt = build_prompt(issue, config, ctx.turn, ctx.attempt)
    on_event = fn event -> forward_event(ctx.parent, issue.id, event) end

    case Session.run_turn(session, prompt, issue, on_event) do
      {:ok, next_session} ->
        continue_or_finish(next_session, issue, config, ctx)

      {:error, {:approval_required, decision}} ->
        pause_for_approval(decision, issue, ctx)

      {:error, _} = err ->
        err
    end
  end

  # Convert a non-auto-approve approval request from `Session.run_turn`
  # into an orchestrator-level pause. The token captures the decision
  # payload so an operator inspecting the snapshot sees exactly what
  # they are approving (e.g. the proposed shell command or file edit),
  # plus `approvals_granted`: the session spends its whole standing grant
  # before it pauses, so that count is exactly how many approval points
  # this run has cleared, and the next resume can carry it forward.
  defp pause_for_approval(decision, %Issue{} = issue, ctx) do
    Logger.info(
      "symphony.runners.codex.awaiting_approval issue=#{issue.identifier} " <>
        "turn=#{ctx.turn} decision=#{inspect(decision)}"
    )

    send(
      ctx.parent,
      {:run_event, issue.id,
       %{
         event: :awaiting_approval,
         message: approval_summary(decision),
         payload: decision,
         timestamp: DateTime.utc_now()
       }}
    )

    {:pause, :awaiting_approval,
     %{
       decision: decision,
       issue_id: issue.id,
       turn: ctx.turn,
       approvals_granted: ctx.granted_approvals,
       paused_at: DateTime.utc_now()
     }}
  end

  defp approval_summary(decision) when is_binary(decision),
    do: "awaiting operator approval (#{decision})"

  defp approval_summary(%{"type" => type}) when is_binary(type),
    do: "awaiting approval for #{type}"

  defp approval_summary(%{type: type}) when is_atom(type) or is_binary(type),
    do: "awaiting approval for #{type}"

  defp approval_summary(_), do: "awaiting operator approval"

  defp continue_or_finish(session, %Issue{} = issue, %Config{} = config, ctx) do
    case still_active?(issue, config) do
      {:active, refreshed} ->
        run_turns(session, refreshed, config, %{ctx | turn: ctx.turn + 1})

      :done ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp still_active?(%Issue{id: id}, %Config{} = config) do
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
        err
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp check_codex_installed(%Config{codex: %{command: command}})
       when is_binary(command) do
    case primary_executable(command) do
      nil ->
        {:error, :codex_not_installed}

      exe ->
        if System.find_executable(exe),
          do: :ok,
          else: {:error, :codex_not_installed}
    end
  end

  defp primary_executable(command) do
    command
    |> String.trim()
    |> String.split(~r/\s+/, parts: 2)
    |> List.first()
    |> case do
      "" -> nil
      nil -> nil
      exe -> exe
    end
  end

  defp build_policy(%Config{codex: codex}, granted_approvals) do
    approval_policy = codex.approval_policy || "never"

    %{
      approval_policy: approval_policy,
      thread_sandbox: codex.thread_sandbox || "workspace-write",
      turn_sandbox_policy: codex.turn_sandbox_policy || %{},
      read_timeout_ms: codex.read_timeout_ms,
      turn_timeout_ms: codex.turn_timeout_ms,
      auto_approve?: approval_policy == "never",
      granted_approvals: granted_approvals,
      dynamic_tools: []
    }
  end

  defp forward_event(parent, issue_id, event) when is_pid(parent) do
    send(parent, {:run_event, issue_id, event})
  end

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
          "symphony.runners.codex.prompt_build_failed issue=#{issue.identifier} reason=#{inspect(reason)}"
        )

        PromptBuilder.default_prompt()
    end
  end

  defp build_prompt(%Issue{} = issue, %Config{} = _config, turn, _attempt) do
    """
    Continuation guidance:

    - The previous Codex turn completed normally, but #{issue.identifier} is still in an active state.
    - This is continuation turn ##{turn}.
    - Resume from the current workspace state instead of restarting from scratch.
    - Focus on the remaining work and stop only when the issue reaches the next handoff state or is truly blocked.
    """
  end
end
