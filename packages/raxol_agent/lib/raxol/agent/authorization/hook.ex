defmodule Raxol.Agent.Authorization.Hook do
  @moduledoc """
  Composes the ALLOW/ASK/DENY engine into the `Raxol.Agent.CommandHook` chain.

  This is the integration seam: where `Raxol.Agent.PermissionHook` is deny-only,
  this hook evaluates the authorization engine at the `:tool_call` phase for each
  directive and maps the decision to a hook result:

    * ALLOW -> `{:ok, command}` (commit labels)
    * DENY  -> `{:deny, reason}` (commit prior-ALLOW labels)
    * ASK   -> resolved synchronously via a `:prompter` (the same pattern
      PermissionHook uses); on approve `{:ok, command}` + release escrow, on deny
      `{:deny, {:ask_denied, prompts}}`. With no prompter, a pending ASK is denied
      `{:deny, {:requires_approval, prompts}}`.

  Configure per process (like PermissionHook) with `configure/1`; the engine
  `State` (labels, approvals) is held in the process dictionary and threaded
  across calls. When not configured, the hook is a neutral no-op so it composes
  safely with other hooks.
  """

  @behaviour Raxol.Agent.CommandHook

  alias Raxol.Agent.Authorization.Engine
  alias Raxol.Agent.Directive.{Async, SendAgent, Shell}

  @config_key {__MODULE__, :config}

  @doc """
  Configure the hook for the current process.

  Options: `:policies`, `:labels`, `:monotonic`, `:route`, and `:prompter`
  (`(decision, context) -> :approve | :deny`).
  """
  @spec configure(keyword()) :: :ok
  def configure(opts) do
    config = %{
      policies: Keyword.get(opts, :policies, []),
      state:
        Engine.new(
          labels: Keyword.get(opts, :labels, %{}),
          monotonic: Keyword.get(opts, :monotonic, %{})
        ),
      prompter: Keyword.get(opts, :prompter),
      route: Keyword.get(opts, :route, :default)
    }

    Process.put(@config_key, config)
    :ok
  end

  @doc "Remove the hook configuration for the current process."
  @spec clear() :: :ok
  def clear do
    Process.delete(@config_key)
    :ok
  end

  @doc "The current label snapshot for the configured process (or `%{}`)."
  @spec labels() :: map()
  def labels do
    case Process.get(@config_key) do
      nil -> %{}
      %{state: state} -> state.labels
    end
  end

  @impl true
  def pre_execute(command, context) do
    case Process.get(@config_key) do
      nil -> {:ok, command}
      config -> authorize(command, context, config)
    end
  end

  # -- Internals --------------------------------------------------------------

  defp authorize(command, context, config) do
    ctx = Map.merge(context, %{directive: command, type: directive_type(command)})

    decision =
      Engine.evaluate(config.policies, :tool_call, ctx, config.state, route: config.route)

    handle(decision, command, ctx, config)
  end

  defp handle(%{action: :allow} = decision, command, _ctx, config) do
    put_state(config, Engine.commit(decision, config.state))
    {:ok, command}
  end

  defp handle(%{action: :deny} = decision, _command, _ctx, config) do
    put_state(config, Engine.commit(decision, config.state))
    {:deny, decision.reason}
  end

  defp handle(%{action: :ask} = decision, command, ctx, config) do
    committed = Engine.commit(decision, config.state)
    prompts = Enum.map(decision.asks, & &1.prompt)

    case approve?(decision, ctx, config.prompter) do
      true ->
        put_state(config, Engine.approve(decision, committed))
        {:ok, command}

      false ->
        put_state(config, committed)
        {:deny, denial_reason(config.prompter, prompts)}
    end
  end

  defp approve?(_decision, _ctx, nil), do: false

  defp approve?(decision, ctx, prompter) when is_function(prompter, 2) do
    case prompter.(decision, ctx) do
      :approve -> true
      true -> true
      _ -> false
    end
  end

  defp denial_reason(nil, prompts), do: {:requires_approval, prompts}
  defp denial_reason(_prompter, prompts), do: {:ask_denied, prompts}

  defp put_state(config, state), do: Process.put(@config_key, %{config | state: state})

  defp directive_type(%Shell{}), do: :shell
  defp directive_type(%SendAgent{}), do: :send_agent
  defp directive_type(%Async{}), do: :async
  defp directive_type(_other), do: :unknown
end
