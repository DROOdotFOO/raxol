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
      %{
        agent_id: Map.get(context, :agent_id),
        agent_module: Map.get(context, :agent_module),
        action: action,
        reason: reason
      }
    )
  end
end
