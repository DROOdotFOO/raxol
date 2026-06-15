defmodule Raxol.Agent.CommandHook do
  @moduledoc """
  Pre/post execution hooks for agent commands.

  Hooks can inspect, modify, or deny commands before and after execution.
  This enables audit logging, permission checks, rate limiting, and other
  cross-cutting concerns without modifying individual agent modules.

  ## Usage

  Define a hook module:

      defmodule MyAuditHook do
        @behaviour Raxol.Agent.CommandHook

        @impl true
        def pre_execute(command, context) do
          Logger.info("Executing: \#{inspect(command.type)}")
          {:ok, command}
        end

        @impl true
        def post_execute(command, result, context) do
          Logger.info("Result: \#{inspect(result)}")
          {:ok, result}
        end
      end

  Register hooks when starting an agent:

      Agent.Session.start_link(
        id: :my_agent,
        app_module: MyAgent,
        hooks: [MyAuditHook, MyPermissionHook]
      )

  ## Hook Results

  - `{:ok, command}` -- allow (optionally modified)
  - `{:deny, reason}` -- block execution, send denial as command result
  - `{:ok, result}` -- post-hook, optionally modify result
  """

  alias Raxol.Agent.Directive
  alias Raxol.Agent.Directive.{Async, SendAgent, Shell}
  alias Raxol.Core.Runtime.Command

  @type effect :: Command.t() | Directive.t()

  @type hook_context :: %{
          agent_id: term(),
          agent_module: module()
        }

  @type pre_result :: {:ok, effect()} | {:deny, term()}
  @type post_result :: {:ok, term()} | {:error, term()}

  @doc """
  Called before a command is executed.

  Return `{:ok, command}` to allow (optionally modify the command),
  or `{:deny, reason}` to block execution.
  """
  @callback pre_execute(command :: effect(), context :: hook_context()) ::
              pre_result()

  @doc """
  Called after a command has been executed.

  Return `{:ok, result}` to pass through (optionally modify the result).
  """
  @callback post_execute(
              command :: effect(),
              result :: term(),
              context :: hook_context()
            ) :: post_result()

  @optional_callbacks post_execute: 3

  @doc """
  Run a command through a chain of pre-execution hooks.

  Hooks are evaluated in order. The first `:deny` short-circuits the chain.
  Each hook may modify the command before passing it to the next.
  """
  @spec run_pre_hooks([module()], effect(), hook_context()) :: pre_result()
  def run_pre_hooks([], command, _context), do: {:ok, command}

  def run_pre_hooks([hook | rest], command, context) do
    case hook.pre_execute(command, context) do
      {:ok, command} -> run_pre_hooks(rest, command, context)
      {:deny, _reason} = denied -> denied
    end
  end

  @doc """
  Run a result through a chain of post-execution hooks.

  Hooks are evaluated in order. Each hook may modify the result.
  """
  @spec run_post_hooks([module()], effect(), term(), hook_context()) ::
          post_result()
  def run_post_hooks([], _command, result, _context), do: {:ok, result}

  def run_post_hooks([hook | rest], command, result, context) do
    if function_exported?(hook, :post_execute, 3) do
      case hook.post_execute(command, result, context) do
        {:ok, result} -> run_post_hooks(rest, command, result, context)
        {:error, _reason} = error -> error
      end
    else
      run_post_hooks(rest, command, result, context)
    end
  end

  @doc """
  Wrap a list of commands, applying pre/post hooks around each execution.

  Returns a new list of commands where hookable types (`:shell`, `:async`,
  `:system`, `:send_agent`) are wrapped to run hooks. Non-hookable types
  (`:none`, `:quit`, `:delay`, etc.) pass through unchanged.

  Denied commands are replaced with a `:none` command that sends a
  `{:command_denied, type, reason}` result back to the agent.
  """
  @spec wrap_commands([effect()], [module()], hook_context()) :: [effect()]
  def wrap_commands(commands, [], _context), do: commands

  def wrap_commands(commands, hooks, context) do
    Enum.map(commands, &maybe_wrap(&1, hooks, context))
  end

  @hookable_command_types [:shell, :async, :system, :send_agent, :task]

  defp maybe_wrap(%Command{type: type} = command, hooks, context)
       when type in @hookable_command_types do
    apply_hooks(command, hooks, context)
  end

  defp maybe_wrap(%Async{} = directive, hooks, context),
    do: apply_hooks(directive, hooks, context)

  defp maybe_wrap(%Shell{} = directive, hooks, context),
    do: apply_hooks(directive, hooks, context)

  defp maybe_wrap(%SendAgent{} = directive, hooks, context),
    do: apply_hooks(directive, hooks, context)

  defp maybe_wrap(effect, _hooks, _context), do: effect

  defp apply_hooks(effect, hooks, context) do
    case run_pre_hooks(hooks, effect, context) do
      {:ok, effect} -> wrap_with_post_hooks(effect, hooks, context)
      {:deny, reason} -> build_denial(effect, reason)
    end
  end

  defp build_denial(%Command{type: type}, reason) do
    Command.new(:async, fn sender ->
      sender.({:command_denied, type, reason})
    end)
  end

  defp build_denial(directive, reason) do
    type = effect_type(directive)

    Directive.async(fn sender ->
      sender.({:command_denied, type, reason})
    end)
  end

  defp effect_type(%Async{}), do: :async
  defp effect_type(%Shell{}), do: :shell
  defp effect_type(%SendAgent{}), do: :send_agent

  defp wrap_with_post_hooks(effect, hooks, context) do
    if Enum.any?(hooks, &function_exported?(&1, :post_execute, 3)) do
      do_wrap_post(effect, hooks, context)
    else
      effect
    end
  end

  defp do_wrap_post(%Command{type: :async} = command, hooks, context) do
    original_fun = command.data
    %{command | data: wrap_sender_fun(original_fun, command, hooks, context)}
  end

  defp do_wrap_post(%Command{type: :task} = command, hooks, context) do
    original_fun = command.data
    %{command | data: wrap_task_fun(original_fun, command, hooks, context)}
  end

  defp do_wrap_post(%Async{fun: fun} = directive, hooks, context) do
    %{directive | fun: wrap_sender_fun(fun, directive, hooks, context)}
  end

  defp do_wrap_post(effect, _hooks, _context), do: effect

  defp wrap_sender_fun(original_fun, effect, hooks, context) do
    fn sender ->
      original_fun.(build_wrapped_sender(sender, effect, hooks, context))
    end
  end

  defp build_wrapped_sender(sender, effect, hooks, context) do
    fn result ->
      case run_post_hooks(hooks, effect, result, context) do
        {:ok, modified} -> sender.(modified)
        {:error, reason} -> sender.({:hook_error, reason})
      end
    end
  end

  defp wrap_task_fun(original_fun, effect, hooks, context) do
    fn ->
      result = original_fun.()

      case run_post_hooks(hooks, effect, result, context) do
        {:ok, modified} -> modified
        {:error, reason} -> {:hook_error, reason}
      end
    end
  end
end
