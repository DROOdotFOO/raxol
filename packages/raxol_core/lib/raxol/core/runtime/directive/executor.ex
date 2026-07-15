defprotocol Raxol.Core.Runtime.Directive.Executor do
  @moduledoc """
  Protocol for executing runtime directives.

  Built-in implementations cover `Raxol.Core.Runtime.Directive.{Stop, Schedule, Spawn}`.
  Packages register additional directive types by defining a struct and
  implementing this protocol for it. raxol_agent provides impls for
  `Raxol.Agent.Directive.{Async, Shell, SendAgent}`; raxol_payments and
  raxol_acp provide their own.

  ## Context

  The `context` map carries at minimum:

    * `:pid` - process to receive `{:command_result, payload}` messages
    * `:runtime_pid` - process to receive runtime-level signals (e.g. quit)

  The Dispatcher additionally supplies `:turn_id` — a snapshot of the agent
  turn that minted the command (nil outside a turn). Implementations whose
  results may land after the minting turn closed SHOULD echo it back using the
  tagged form `{:command_result, payload, %{turn_id: turn_id}}` so the result
  is attributed to its originating turn; the plain 2-tuple remains valid and
  is attributed to the turn current at delivery time (nil between turns).

  Effect messages land at `context.pid` as `{:command_result, payload}` (or
  the tagged 3-tuple above). Consumers rely on the asynchronous result message
  rather than the return value of `execute/2`.
  """

  @spec execute(t(), context :: map()) :: any()
  def execute(directive, context)
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.Core.Runtime.Directive.Stop do
  alias Raxol.Core.Runtime.Directive.Stop

  def execute(%Stop{}, context) do
    send(context.runtime_pid, :quit_runtime)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.Core.Runtime.Directive.Schedule do
  alias Raxol.Core.Runtime.Directive.Schedule

  def execute(%Schedule{interval_ms: interval_ms, payload: payload}, context) do
    Process.send_after(context.pid, {:command_result, payload}, interval_ms)
  end
end

defimpl Raxol.Core.Runtime.Directive.Executor, for: Raxol.Core.Runtime.Directive.Spawn do
  alias Raxol.Core.Runtime.Directive.Spawn

  def execute(%Spawn{fun: fun}, context) do
    Task.start(fn ->
      result = fun.()
      send(context.pid, {:command_result, result})
    end)
  end
end
