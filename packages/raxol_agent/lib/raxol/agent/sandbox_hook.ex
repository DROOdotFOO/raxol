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
  forbids (ADR-0036). The emitted reason keeps the shape and, for a simple
  command (`Raxol.Agent.Sandbox.Shell.simple_command?/1`), the program:
  `{:shell_denied, mode, "rm -rf x"}` becomes `{:shell_denied, mode, "rm"}`
  with a `command_digest` beside it, so an audit line still says `rm` was
  refused and a known command can be matched, while the arguments never leave
  the process. A command the shell would interpret first -- an env-assignment
  prefix, a pipeline, a substitution -- has no honest first token (`FOO=secret
  cmd` starts with the secret), so it is emitted as `{:shell_denied, mode,
  :non_simple}`. The `mode` is passed through `Raxol.Agent.Telemetry.bound/1`,
  so a predicate becomes `{:redacted, :function}`. A malformed-payload denial
  carries the whole tool payload and is reduced to its tag. Everything else is
  passed through `bound/1`. The caller's `{:deny, reason}` is untouched: the
  operator-facing message is not telemetry.
  """

  @behaviour Raxol.Agent.CommandHook

  alias Raxol.Agent.Directive.{Async, SendAgent, Shell}
  alias Raxol.Agent.Sandbox.Chain
  alias Raxol.Agent.Sandbox.Shell, as: ShellSandbox
  alias Raxol.Agent.Telemetry

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
      reason: {:shell_denied, Telemetry.bound(mode), program(command)},
      command_digest: Telemetry.digest(command)
    }
  end

  defp telemetry_reason({tag, _payload})
       when tag in [:shell_malformed_payload, :send_agent_malformed_payload],
       do: %{reason: tag}

  defp telemetry_reason(reason), do: %{reason: Telemetry.bound(reason)}

  # The first token names the program only when the command is simple in
  # `Raxol.Agent.Sandbox.Shell.simple_command?/1`'s sense. Otherwise it is an
  # arbitrary word the shell would interpret first, and the commonest such word
  # is an env assignment -- `PGPASSWORD=hunter2 psql` -- which is precisely the
  # shape a credential rides in, on precisely the commands a list mode always
  # denies. Those emit a shape tag; the digest still lets a known command be
  # matched. A simple command's first token is what `sh` would exec, so it is
  # a program path, but one carrying `=` is refused too rather than reasoned
  # about (`./deploy?token=...`). `bound/1` caps the name by bytes, the unit
  # `identifier?/1` measures in, and redacts rather than splits a long one.
  defp program(command) do
    name = ShellSandbox.binary_name(command)

    if ShellSandbox.simple_command?(command) and not String.contains?(name, "=") do
      Telemetry.bound(name)
    else
      :non_simple
    end
  end
end
