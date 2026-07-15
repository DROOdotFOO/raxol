defmodule Raxol.Agent.ToolCall.Hook do
  @moduledoc """
  Ordered interception pipeline around LLM tool-call execution.

  Every LLM-initiated tool call passes through
  `Raxol.Agent.Action.ToolConverter.dispatch_tool_call/3` (the react loop in
  `Raxol.Agent.Stream`, `Raxol.Agent.Strategy.ReAct`, and the Vfs/Payments
  helpers all funnel through it). This module is the hookable seam at that
  chokepoint: an ordered list of hook modules runs immediately before the
  Action is invoked, and each hook can observe, transform, or veto the call.
  (The internal `Pipeline`/`Direct`/`run_action*` paths call `Action.call/2`
  directly, but those are agent-internal and never LLM-reachable, so they
  legitimately sit outside this seam.)

  This is the interception point assumed by upcoming harness units:
  reserve-budget-before-call (SpendGate) and blast-radius approval gates
  register here rather than wrapping the loop themselves.

  ## Scope: framework-managed ReAct only (native-harness gap)

  This pipeline gates **only** the framework-managed ReAct/Stream.react loop.
  Backends whose `handles_tools_internally?/0` returns `true`
  (`Raxol.Agent.Backend.Native` -- the Claude Code / Cursor harnesses) route
  through `native_react` and drive their own tool loop inside the harness
  process; those calls **bypass** this seam entirely. Consequently
  `:tool_call_hooks` (and the future U7/U8 authorization/approval gates that
  build on them) apply to framework-driven tool calls, not to tool calls a
  native harness executes internally. U7/U8 authors: treat the native-harness
  path as out of scope for this chokepoint.

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

  A hook that escapes `before_call/2` by any means is treated as a veto, not a
  pipeline escape. All three escape kinds are contained so nothing propagates
  into the (untrapped) react loop:

    * `raise` halts with `{:halt, {:hook_raised, hook_module, message}}`
    * `throw/1` halts with `{:halt, {:hook_threw, hook_module, value}}`
    * `exit/1` halts with `{:halt, {:hook_exited, hook_module, reason}}`

  Each becomes `{:error, {:vetoed, {:hook_raised | :hook_threw | :hook_exited,
  hook_module, detail}}}`. A return value that is neither `{:cont, call}` nor
  `{:halt, reason}` halts with `{:halt, {:invalid_hook_return, hook_module,
  value}}`. A `raise`/`throw`/`exit` inside `after_call/3` is likewise
  contained -- and because the Action has *already run* by that point, the
  un-transformed result passes through unchanged (an after-hook failure never
  turns a successful call into a veto). The react loop never crashes because of
  a misbehaving hook.

  ## Re-authorization of transformed calls

  A `before_call/2` hook may rewrite `call.action` to a *different* module. If
  it does, `dispatch_tool_call/3` re-runs the tool authorizer
  (`Raxol.Agent.ToolPolicy`) against the rewritten action before executing it,
  so a hook cannot smuggle a `sensitive: true` fund-mover past the policy that
  guards the original action. When the action is unchanged (the common case),
  no re-authorization runs.

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
  transform the call before passing it to the next. A hook that raises, throws,
  or exits halts the chain with `{:hook_raised | :hook_threw | :hook_exited,
  hook, detail}` (contained -- never propagated).
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

  Hooks that don't export `after_call/3` are skipped. A hook that raises,
  throws, or exits is contained: the result passes through unchanged (the
  Action already ran).
  """
  @spec run_after([module()], call(), result(), context()) :: result()
  def run_after(hooks, call, result, context) do
    Enum.reduce(hooks, result, fn hook, acc ->
      invoke_after(hook, call, acc, context)
    end)
  end

  defp invoke_before(hook, call, context) do
    case hook.before_call(call, context) do
      {:cont, %{action: _, name: _, params: _, call_id: _} = call} -> {:cont, call}
      {:halt, reason} -> {:halt, reason}
      other -> {:halt, {:invalid_hook_return, hook, other}}
    end
  rescue
    error -> {:halt, {:hook_raised, hook, Exception.message(error)}}
  catch
    :throw, value -> {:halt, {:hook_threw, hook, value}}
    :exit, reason -> {:halt, {:hook_exited, hook, reason}}
  end

  defp invoke_after(hook, call, result, context) do
    if function_exported?(hook, :after_call, 3) do
      hook.after_call(call, result, context)
    else
      result
    end
  rescue
    _error -> result
  catch
    # A contained after_call failure falls back to the un-transformed result --
    # the Action already ran, so we surface its real output, not a veto.
    :throw, _value -> result
    :exit, _reason -> result
  end
end
