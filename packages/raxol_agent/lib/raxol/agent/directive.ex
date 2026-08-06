defmodule Raxol.Agent.Directive do
  @moduledoc """
  Agent-specific effect directives.

  Each directive is a bare struct with a
  `Raxol.Core.Runtime.Directive.Executor` protocol implementation that the
  runtime invokes to perform the effect.

  ## Built-in directives

  | Directive | Effect |
  | --- | --- |
  | `Async` | Spawn a task with a sender callback for multi-message replies |
  | `Shell` | Run a shell command via Port, return structured exit/output |
  | `SendAgent` | Route a message to another agent by id (via Registry) |

  ## Re-exported from `Raxol.Core.Runtime.Directive`

  These shared directives need no agent context; agent code can use them
  through this module's helpers for convenience or call the core module
  directly:

    * `schedule/2` - delegates to `Raxol.Core.Runtime.Directive.schedule/2`
    * `spawn/1` - delegates to `Raxol.Core.Runtime.Directive.spawn_task/1`
    * `stop/1` - delegates to `Raxol.Core.Runtime.Directive.stop/1`

  ## Examples

      Directive.async(fn sender ->
        sender.({:progress, 50})
        sender.({:done, do_work()})
      end)

      Directive.shell("ls -la", timeout: 5_000)
      Directive.send_agent("worker-1", {:task, payload})

  ## Execution

      Raxol.Core.Runtime.Directive.Executor.execute(directive, %{
        pid: self(),
        runtime_pid: runtime_pid
      })

  Result messages arrive at `context.pid` as
  `{:command_result, payload, %{turn_id: turn_id}}` — the `turn_id` is a
  snapshot of the agent turn that dispatched the directive (nil outside a
  turn), so late async results stay attributed to their originating turn.
  """

  alias __MODULE__.{Async, SendAgent, Shell}
  alias Raxol.Core.Runtime.Directive, as: CoreDirective

  @type t ::
          Async.t()
          | SendAgent.t()
          | Shell.t()
          | CoreDirective.t()

  defmodule Async do
    @moduledoc """
    Spawn a task with a sender callback. The function receives a `sender/1`
    closure that can be invoked multiple times to send messages back to the
    TEA loop as `{:command_result, msg}`.

    Exceptions inside the function are caught and sent back as
    `{:command_result, {:async_error, message}}`.
    """

    @type sender :: (term() -> :ok)
    @type t :: %__MODULE__{fun: (sender() -> any())}

    @enforce_keys [:fun]
    defstruct [:fun]
  end

  defmodule Shell do
    @moduledoc """
    Run a shell command via Port. Returns a single
    `{:command_result, {:shell_result, %{exit_status: status, output: binary}}}`
    message when the command completes or the timeout elapses.

    Options: `:timeout` (default from `Raxol.Core.Defaults`), `:cd`, `:env`.
    """

    @type t :: %__MODULE__{command: String.t(), opts: keyword()}

    @enforce_keys [:command]
    defstruct command: nil, opts: []
  end

  defmodule SendAgent do
    @moduledoc """
    Route a message to another agent by id. The target is looked up in
    `Raxol.Agent.Registry`; on success the message arrives in the target's
    `update/2` as `{:agent_message, from, message}` -- `from` is this
    directive's `:from` field when set (`Directive.send_agent/3` with
    `from: my_id`), `nil` otherwise. On failure the sender receives
    `{:command_result, {:send_agent_error, :not_found, target_id}}`.
    """

    @type t :: %__MODULE__{
            target_id: term(),
            message: term(),
            from: term() | nil
          }

    @enforce_keys [:target_id, :message]
    defstruct [:target_id, :message, :from]
  end

  @doc "Construct an Async directive with a sender-callback function."
  @spec async((Async.sender() -> any())) :: Async.t()
  def async(fun) when is_function(fun, 1), do: %Async{fun: fun}

  @doc """
  Construct a Shell directive.

  Options:
    * `:timeout` - max execution time in ms (default: runtime default)
    * `:cd` - working directory
    * `:env` - environment variables as `[{key, value}]`
  """
  @spec shell(String.t(), keyword()) :: Shell.t()
  def shell(command, opts \\ []) when is_binary(command) and is_list(opts) do
    %Shell{command: command, opts: opts}
  end

  @doc """
  Construct a SendAgent directive.

  Pass `from: my_agent_id` to identify the sender; it arrives as the
  second element of the target's `:agent_message` tuple (`nil` when
  omitted -- the framework never guesses a sender).
  """
  @spec send_agent(term(), term(), keyword()) :: SendAgent.t()
  def send_agent(target_id, message, opts \\ []),
    do: %SendAgent{
      target_id: target_id,
      message: message,
      from: Keyword.get(opts, :from)
    }

  @doc "Delegates to `Raxol.Core.Runtime.Directive.schedule/2`."
  @spec schedule(non_neg_integer(), term()) :: CoreDirective.Schedule.t()
  defdelegate schedule(interval_ms, payload), to: CoreDirective

  @doc "Delegates to `Raxol.Core.Runtime.Directive.spawn_task/1`."
  @spec spawn((-> any())) :: CoreDirective.Spawn.t()
  def spawn(fun) when is_function(fun, 0), do: CoreDirective.spawn_task(fun)

  @doc "Delegates to `Raxol.Core.Runtime.Directive.stop/1`."
  @spec stop(term()) :: CoreDirective.Stop.t()
  defdelegate stop(reason \\ :normal), to: CoreDirective
end
