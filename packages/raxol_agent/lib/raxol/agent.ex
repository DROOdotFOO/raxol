defmodule Raxol.Agent do
  @moduledoc """
  Thin layer over `Raxol.Core.Runtime.Application` for building AI agents.

  Agents implement the same TEA callbacks (`init/1`, `update/2`, `view/1`)
  as any Raxol app. Input comes from LLMs, tools, or other agents instead
  of a keyboard. OTP provides supervision, crash isolation, and hot reload.

  `view/1` is optional -- headless agents skip rendering entirely.

  ## Example

      defmodule MyAgent do
        use Raxol.Agent

        def init(_context) do
          %{findings: [], status: :idle}
        end

        def update({:agent_message, _from, {:analyze, file}}, model) do
          {%{model | status: :working}, Directive.async(fn sender ->
            result = do_analysis(file)
            sender.({:analysis_done, result})
          end)}
        end

        def update({:command_result, {:analysis_done, result}}, model) do
          {%{model | findings: [result | model.findings], status: :idle}, []}
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      @behaviour Raxol.Core.Runtime.Application

      import Raxol.Core.Renderer.View, except: [view: 1]
      alias Raxol.Agent.Directive
      alias Raxol.Core.Events.Event

      def init(_), do: %{}
      def update(_, state), do: {state, []}
      def view(_model), do: nil
      def subscribe(_), do: []
      def subscriptions(_), do: []
      def handle_event(_), do: nil
      def handle_tick(model), do: {model, []}
      def handle_message(_, model), do: {model, []}
      def terminate(_, _), do: :ok

      @doc """
      Returns compaction config for automatic session history compaction.

      Override to customize token limits. Return `nil` to disable compaction.
      Agents that store message history in `model.history` get automatic
      compaction after each action in `Agent.Process`.

      ## Default Config

          %{max_tokens: 8_000, preserve_recent: 4, summary_max_tokens: 1_000}
      """
      def compaction_config do
        %{max_tokens: 8_000, preserve_recent: 4, summary_max_tokens: 1_000}
      end

      @doc """
      Returns a list of `Raxol.Agent.CommandHook` modules for this agent.

      Hooks intercept command execution with pre/post semantics.
      Return `[]` to disable hooks (default).
      """
      def command_hooks, do: []

      @doc """
      Returns a list of `Raxol.Agent.Sandbox` structs declaring the
      isolation dimensions that gate this agent's directives.

      Defaults to `[]` (no sandboxing). When non-empty, consumers
      using `Raxol.Agent.effective_hooks/1` get
      `Raxol.Agent.SandboxHook` prepended automatically to the
      `command_hooks/0` chain.
      """
      def sandbox, do: []

      @doc """
      Returns the `Raxol.Agent.ThreadLog` adapter (`{module, config}`
      or bare module) for durable audit, or `nil` to disable.

      When non-nil, consumers wire
      `Raxol.Agent.ThreadLogRouter.attach/3` at agent startup so
      every policy decision and sandbox denial lands as a durable
      event keyed on the agent's id.
      """
      def thread_log, do: nil

      @doc """
      Returns the cross-session memory provider for this agent, or `nil`.

      Override to return a `Raxol.Agent.Memory` provider module (e.g.
      `Raxol.Agent.Memory.Store.Ets`). When set, memory actions are exposed
      automatically and the agent should put
      `Raxol.Agent.Memory.provider_context(provider, agent_id)` under
      `context[:memory]` when invoking a Strategy or `Raxol.Agent.Stream`.
      Defaults to `nil` (memory disabled).
      """
      def memory_provider, do: nil

      @doc """
      Returns a list of Action modules available to this agent.

      Used by `Agent.Process` with a Strategy to determine which
      Actions can be invoked. Override to expose Actions as tools.
      Defaults to the memory actions when `memory_provider/0` is set,
      otherwise `[]`.
      """
      def available_actions do
        if memory_provider(), do: Raxol.Agent.Actions.Memory.actions(), else: []
      end

      defoverridable init: 1,
                     update: 2,
                     view: 1,
                     subscribe: 1,
                     subscriptions: 1,
                     handle_event: 1,
                     handle_tick: 1,
                     handle_message: 2,
                     terminate: 2,
                     compaction_config: 0,
                     command_hooks: 0,
                     sandbox: 0,
                     thread_log: 0,
                     memory_provider: 0,
                     available_actions: 0

      @doc false
      def async(fun), do: Directive.async(fun)

      @doc false
      def shell(command, opts \\ []), do: Directive.shell(command, opts)

      @doc false
      def send_agent(target, message), do: Directive.send_agent(target, message)

      @doc "Run an action synchronously. Returns `{:ok, result}` or `{:error, reason}`."
      @spec run_action(module(), map(), map()) ::
              {:ok, term()} | {:error, term()}
      def run_action(action_module, params, context \\ %{}) do
        action_module.call(params, context)
      end

      @doc "Run an action asynchronously. Result arrives as `{:command_result, {:action_result, module, result}}`."
      @spec run_action_async(module(), map(), map()) :: Directive.Async.t()
      def run_action_async(action_module, params, context \\ %{}) do
        Directive.async(fn sender ->
          case action_module.call(params, context) do
            {:ok, result} ->
              sender.({:action_result, action_module, result})

            {:ok, result, _commands} ->
              sender.({:action_result, action_module, result})

            {:error, reason} ->
              sender.({:action_error, action_module, reason})
          end
        end)
      end

      @doc "Run a pipeline asynchronously. Result arrives as `{:command_result, {:pipeline_result, result}}`."
      @spec run_pipeline_async([module()], map(), map()) :: Directive.Async.t()
      def run_pipeline_async(steps, params, context \\ %{}) do
        Directive.async(fn sender ->
          case Raxol.Agent.Action.Pipeline.run(steps, params, context) do
            {:ok, result, _commands} ->
              sender.({:pipeline_result, result})

            {:error, {step, reason}} ->
              sender.({:pipeline_error, step, reason})
          end
        end)
      end
    end
  end

  # --- Module-level helpers (callable without `use Raxol.Agent`) ----------

  @doc """
  Return the effective hook chain for `agent_module`: prepends
  `Raxol.Agent.SandboxHook` to `agent_module.command_hooks/0` when
  the agent declares a non-empty `sandbox/0`.

  Consumers wiring an agent into a runtime (Symphony's
  `Runners.RaxolAgent`, the Agent.Session helper, etc) should pass
  the result here as the hook list rather than reading
  `command_hooks/0` directly.

  Falls back to `[]` when `agent_module` doesn't export either
  callback (e.g. an agent built without `use Raxol.Agent`).
  """
  @spec effective_hooks(module()) :: [module()]
  def effective_hooks(agent_module) when is_atom(agent_module) do
    base = safe_call(agent_module, :command_hooks, [], [])
    sandboxes = safe_call(agent_module, :sandbox, [], [])

    case sandboxes do
      [] -> base
      _list -> [Raxol.Agent.SandboxHook | base]
    end
  end

  @doc """
  Return the normalized `Raxol.Agent.ThreadLog` adapter tuple from
  `agent_module.thread_log/0`, or `nil` when the agent doesn't
  declare one. Useful for `Raxol.Agent.ThreadLogRouter.attach/3`.
  """
  @spec thread_log_adapter(module()) :: {module(), map()} | nil
  def thread_log_adapter(agent_module) when is_atom(agent_module) do
    agent_module
    |> safe_call(:thread_log, [], nil)
    |> Raxol.Agent.ThreadLog.normalize()
  end

  defp safe_call(module, fun, args, default) do
    if function_exported?(module, fun, length(args)) do
      apply(module, fun, args)
    else
      default
    end
  end
end
