defmodule Raxol.Agent.SandboxHook do
  @moduledoc """
  `Raxol.Agent.CommandHook` implementation that consults an agent's
  declared `sandbox/0` list before allowing a directive to fire.

  ## How it works

  The hook reads the agent's sandbox list via `context.agent_module`
  at pre-execute time -- callbacks defined on the agent module are
  the source of truth. For each directive type it can authorize
  (`Async`, `Shell`, `SendAgent`), it builds the action atom and
  payload shape expected by `Raxol.Agent.Sandbox.Chain.authorize/4`
  and walks the chain.

  ## Wiring

  Consumers prepend this module to the agent's `command_hooks/0`
  list at startup. The `Raxol.Agent.effective_hooks/1` helper does
  the prepending automatically:

      hooks = Raxol.Agent.effective_hooks(MyAgent)
      Raxol.Agent.Session.start_link(
        id: :my_agent,
        app_module: MyAgent,
        hooks: hooks
      )

  When the agent declares no `sandbox/0` (returns `[]`), the chain
  walk is trivially `:ok` and the hook is a no-op pass-through.

  ## Telemetry

  On deny, emits `[:raxol, :agent, :sandbox, :denied]` with
  metadata `%{agent_id, agent_module, action, reason}` so
  `Raxol.Agent.ThreadLogRouter` (or any other handler) can route
  the denial as durable audit.

  The `reason` on the wire is not the `reason` the caller receives. A
  denial's reason names what was refused, and for a shell command that is the
  command line -- a tool argument, the thing a model is most likely to have
  embedded a secret in, and the one class of value the metadata contract
  forbids (ADR-0036). The emitted reason keeps the shape and the program:
  `{:shell_denied, mode, command}` becomes `{:shell_denied, mode, program}`
  with a `command_digest` beside it, so an audit line still says `rm` was
  refused and a known command can be matched, while the arguments never leave
  the process. A malformed-payload denial carries the whole tool payload and
  is reduced to its tag. Everything else is passed through
  `Raxol.Agent.Telemetry.bound/1`. The caller's `{:deny, reason}` is untouched:
  the operator-facing message is not telemetry.
  """

  @behaviour Raxol.Agent.CommandHook

  alias Raxol.Agent.Directive.{Async, SendAgent, Shell}
  alias Raxol.Agent.Sandbox.Chain

  @impl true
  def pre_execute(%Shell{command: command, opts: opts}, context) do
    decide(
      :shell,
      %{command: command, opts: opts},
      %Shell{command: command, opts: opts},
      context
    )
  end

  def pre_execute(%SendAgent{target_id: target_id, message: message}, context) do
    decide(
      :send_agent,
      %{target_id: target_id, message: message},
      %SendAgent{target_id: target_id, message: message},
      context
    )
  end

  def pre_execute(%Async{fun: fun}, context) do
    decide(:async, %{fun: fun}, %Async{fun: fun}, context)
  end

  def pre_execute(other, _context), do: {:ok, other}

  defp decide(action, payload, command, context) do
    sandboxes = fetch_sandboxes(context)

    case Chain.authorize(sandboxes, action, payload, sandbox_ctx(context)) do
      :ok ->
        {:ok, command}

      {:deny, reason} = denied ->
        emit_denied(context, action, reason)
        denied
    end
  end

  defp fetch_sandboxes(%{agent_module: nil}), do: []

  defp fetch_sandboxes(%{agent_module: module}) when is_atom(module) do
    if function_exported?(module, :sandbox, 0) do
      module.sandbox() || []
    else
      []
    end
  end

  defp fetch_sandboxes(_), do: []

  defp sandbox_ctx(%{agent_id: agent_id, agent_module: agent_module}) do
    %{agent_id: agent_id, agent_module: agent_module}
  end

  defp sandbox_ctx(_), do: %{}

  defp emit_denied(context, action, reason) do
    :telemetry.execute(
      [:raxol, :agent, :sandbox, :denied],
      %{},
      Map.merge(
        %{
          agent_id: Map.get(context, :agent_id),
          agent_module: Map.get(context, :agent_module),
          action: action
        },
        telemetry_reason(reason)
      )
    )
  end

  defp telemetry_reason({:shell_denied, mode, command}) when is_binary(command) do
    %{
      reason: {:shell_denied, mode, program(command)},
      command_digest: Raxol.Agent.Telemetry.digest(command)
    }
  end

  defp telemetry_reason({tag, _payload})
       when tag in [:shell_malformed_payload, :send_agent_malformed_payload],
       do: %{reason: tag}

  defp telemetry_reason(reason), do: %{reason: Raxol.Agent.Telemetry.bound(reason)}

  # The first whitespace-delimited token, which is the program for the common
  # shapes (`rm -rf x`, `git push`); an env-assignment or sudo prefix makes
  # this the prefix instead, which is still an honest, bounded name of what
  # was attempted. Capped at the identifier size so a pathological token
  # cannot ride through as "the program".
  defp program(command) do
    command
    |> String.trim_leading()
    |> String.split(~r/\s/, parts: 2)
    |> hd()
    |> String.slice(0, Raxol.Agent.Telemetry.max_identifier_bytes())
  end
end
