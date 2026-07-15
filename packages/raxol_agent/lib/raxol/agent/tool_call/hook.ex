defmodule Raxol.Agent.ToolCall.Hook do
  @moduledoc """
  Ordered interception pipeline around LLM tool-call execution.

  Every LLM-initiated tool call is dispatched through
  `Raxol.Agent.Action.ToolConverter.dispatch_tool_call/3` (the react loop in
  `Raxol.Agent.Stream`, `Raxol.Agent.Strategy.ReAct`, and the Vfs/Payments
  helpers all funnel through it). This module is the hookable seam at that
  chokepoint: an ordered list of hook modules runs immediately before the
  Action is invoked, and each hook can observe, transform, or veto the call.

  This is the interception point assumed by upcoming harness units:
  reserve-budget-before-call (SpendGate) and blast-radius approval gates
  register here rather than wrapping the loop themselves.

  ## Contract

      defmodule MyGate do
        @behaviour Raxol.Agent.ToolCall.Hook

        @impl true
        def before_call(call, _context) do
          if allowed?(call), do: {:cont, call}, else: {:halt, :budget_exceeded}
        end
      end

  - `before_call(call, context)` returns `{:cont, call}` to allow (the call
    may be transformed -- later hooks and the final execution see the
    modified call) or `{:halt, reason}` to veto.
  - `after_call(call, result, context)` (optional) may transform the result.
    It receives the final (possibly transformed) call and the full result
    term (`{:ok, output}`, `{:ok, output, commands}`, or `{:error, reason}`).

  ## Registration

  Hooks are an ordered list under the `:tool_call_hooks` key of the agent
  context (the same context that carries `:tool_authorizer`):

      Raxol.Agent.Stream.react(prompt,
        actions: [MyAction],
        context: %{tool_call_hooks: [SpendGate, AuditHook]}
      )

  Hooks run in declared order. The first `{:halt, reason}` stops the chain:
  the Action is **not** executed and `{:error, {:vetoed, reason}}` flows back
  exactly like a failed tool call -- the react loop emits a
  `{:tool_result, %{name: name, result: {:error, {:vetoed, reason}}}}` event,
  the LLM sees a `[Tool error for ...]` message, and the loop continues. No
  new event plumbing: the existing tool-error path carries the veto reason.

  With zero registered hooks the dispatch path is unchanged (fast path).

  ## Failure containment

  A hook that raises inside `before_call/2` is treated as a veto, not a
  pipeline escape: the chain halts with
  `{:halt, {:hook_raised, hook_module, message}}` and the tool call becomes
  `{:error, {:vetoed, {:hook_raised, hook_module, message}}}`. A return value
  that is neither `{:cont, call}` nor `{:halt, reason}` halts with
  `{:halt, {:invalid_hook_return, hook_module, value}}`. A raise inside
  `after_call/3` is contained and the result passes through unchanged. The
  react loop never crashes because of a misbehaving hook.

  ## Relationship to existing hook machinery

  - `Raxol.Agent.CommandHook` wraps *Directive* execution (`Async`/`Shell`/
    `SendAgent` commands returned from `update/2`). Different subject and
    lifecycle; this module mirrors its idiom (module-based hooks, ordered
    list, first denial short-circuits, optional post callback) on the
    tool-call path.
  - `Raxol.Agent.ToolPolicy` is the boolean allow/deny authorizer on the same
    dispatch path. It runs *before* this pipeline and cannot transform calls;
    use it for static policy, use a `ToolCall.Hook` for stateful gates
    (reservations, approvals) and call rewriting.
  """

  @typedoc "A tool call about to be executed."
  @type call :: %{
          action: module(),
          name: String.t(),
          params: map(),
          call_id: term()
        }

  @type context :: map()

  @type result ::
          {:ok, map()}
          | {:ok, map(), [Raxol.Agent.Directive.t()]}
          | {:error, term()}

  @doc """
  Called before the Action is executed.

  Return `{:cont, call}` to allow (optionally transformed -- later hooks see
  the modified call), or `{:halt, reason}` to veto the call.
  """
  @callback before_call(call(), context()) :: {:cont, call()} | {:halt, term()}

  @doc """
  Optional: called after the Action has executed.

  Receives the final call and the full result term; returns the (possibly
  transformed) result.
  """
  @callback after_call(call(), result(), context()) :: result()

  @optional_callbacks after_call: 3

  @context_key :tool_call_hooks

  @doc "Read the ordered hook list from an agent context (`[]` when unset)."
  @spec from_context(map()) :: [module()]
  def from_context(context) when is_map(context),
    do: Map.get(context, @context_key, [])

  def from_context(_context), do: []

  @doc """
  Run a call through the before-call pipeline in declared order.

  The first `{:halt, reason}` short-circuits the chain. Each hook may
  transform the call before passing it to the next. A raising hook halts the
  chain with `{:hook_raised, hook, message}`.
  """
  @spec run_before([module()], call(), context()) ::
          {:cont, call()} | {:halt, term()}
  def run_before([], call, _context), do: {:cont, call}

  def run_before([hook | rest], call, context) do
    case invoke_before(hook, call, context) do
      {:cont, call} -> run_before(rest, call, context)
      {:halt, _reason} = halted -> halted
    end
  end

  @doc """
  Run a result through the after-call pipeline in declared order.

  Hooks that don't export `after_call/3` are skipped. A raising hook is
  contained: the result passes through unchanged.
  """
  @spec run_after([module()], call(), result(), context()) :: result()
  def run_after(hooks, call, result, context) do
    Enum.reduce(hooks, result, fn hook, acc ->
      invoke_after(hook, call, acc, context)
    end)
  end

  defp invoke_before(hook, call, context) do
    case hook.before_call(call, context) do
      {:cont, %{action: _, name: _, params: _} = call} -> {:cont, call}
      {:halt, reason} -> {:halt, reason}
      other -> {:halt, {:invalid_hook_return, hook, other}}
    end
  rescue
    error -> {:halt, {:hook_raised, hook, Exception.message(error)}}
  end

  defp invoke_after(hook, call, result, context) do
    if function_exported?(hook, :after_call, 3) do
      hook.after_call(call, result, context)
    else
      result
    end
  rescue
    _error -> result
  end
end
