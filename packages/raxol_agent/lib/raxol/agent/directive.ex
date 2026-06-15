defmodule Raxol.Agent.Directive do
  @moduledoc """
  Extensible struct-based effect descriptors for raxol agents.

  Each directive is a bare struct with a `Raxol.Agent.Directive.Executor`
  protocol implementation that the runtime invokes to perform the effect.
  External packages define their own directive structs and protocol impls
  without modifying this module.

  ## Built-in directives

  | Directive | Effect |
  | --- | --- |
  | `Async` | Spawn a task with a sender callback for multi-message replies |
  | `Shell` | Run a shell command via Port, return structured exit/output |
  | `SendAgent` | Route a message to another agent by id (via Registry) |
  | `Schedule` | Send a message after a delay (Process.send_after) |
  | `Spawn` | Spawn a task whose return value is sent back once |
  | `Stop` | Signal the runtime to stop |

  ## Examples

      Directive.async(fn sender ->
        sender.({:progress, 50})
        sender.({:done, do_work()})
      end)

      Directive.shell("ls -la", timeout: 5_000)
      Directive.send_agent("worker-1", {:task, payload})
      Directive.schedule(1_000, :tick)
      Directive.spawn(fn -> {:result, expensive_op()} end)
      Directive.stop()

  ## Execution

      Raxol.Agent.Directive.Executor.execute(directive, %{
        pid: self(),
        runtime_pid: runtime_pid
      })

  Result messages arrive at `context.pid` as `{:command_result, payload}`.
  """

  alias __MODULE__.{Async, Schedule, SendAgent, Shell, Spawn, Stop}

  @type t ::
          Async.t()
          | Schedule.t()
          | SendAgent.t()
          | Shell.t()
          | Spawn.t()
          | Stop.t()
          | struct()

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
    `Raxol.Agent.Registry`; on success the message arrives as
    `{:send_message, message}` via `GenServer.cast/2`; on failure the
    sender receives `{:command_result, {:send_agent_error, :not_found, target_id}}`.
    """

    @type t :: %__MODULE__{target_id: term(), message: term()}

    @enforce_keys [:target_id, :message]
    defstruct [:target_id, :message]
  end

  defmodule Schedule do
    @moduledoc """
    Send a message after the given delay (in milliseconds) as
    `{:command_result, payload}`.
    """

    @type t :: %__MODULE__{interval_ms: non_neg_integer(), payload: term()}

    @enforce_keys [:interval_ms, :payload]
    defstruct [:interval_ms, :payload]
  end

  defmodule Spawn do
    @moduledoc """
    Spawn a Task that invokes `fun/0` and sends its return value back as
    `{:command_result, result}`. Use `Async` instead when the task needs
    to send multiple messages.
    """

    @type t :: %__MODULE__{fun: (-> any())}

    @enforce_keys [:fun]
    defstruct [:fun]
  end

  defmodule Stop do
    @moduledoc """
    Signal the runtime to stop. Sends `:quit_runtime` to `context.runtime_pid`.
    """

    @type t :: %__MODULE__{reason: term()}

    defstruct reason: :normal
  end

  @doc """
  Construct an Async directive with a sender-callback function.
  """
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
  """
  @spec send_agent(term(), term()) :: SendAgent.t()
  def send_agent(target_id, message),
    do: %SendAgent{target_id: target_id, message: message}

  @doc """
  Construct a Schedule directive. `interval_ms` must be non-negative.
  """
  @spec schedule(non_neg_integer(), term()) :: Schedule.t()
  def schedule(interval_ms, payload)
      when is_integer(interval_ms) and interval_ms >= 0 do
    %Schedule{interval_ms: interval_ms, payload: payload}
  end

  @doc """
  Construct a Spawn directive with a no-arg function.
  """
  @spec spawn((-> any())) :: Spawn.t()
  def spawn(fun) when is_function(fun, 0), do: %Spawn{fun: fun}

  @doc """
  Construct a Stop directive.
  """
  @spec stop(term()) :: Stop.t()
  def stop(reason \\ :normal), do: %Stop{reason: reason}
end
