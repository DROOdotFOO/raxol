defmodule Raxol.Core.Runtime.Directive do
  @moduledoc """
  Runtime-essential effect directives that any TEA application can return
  from `update/2`.

  These directives need no agent context: they run purely against the
  caller's runtime (`Process.send_after`, `Task.start`, runtime pid signal).
  Agent-specific directives (shell access, inter-agent messaging,
  multi-message async streams) live in `Raxol.Agent.Directive` and depend
  on raxol_agent.

  ## Built-in directives

  | Directive | Effect |
  | --- | --- |
  | `Stop` | Signal the runtime to stop |
  | `Schedule` | Send a message after a delay (`Process.send_after`) |
  | `Spawn` | Run a 0-arg function in a Task; its return value is sent back once |

  ## Examples

      import Raxol.Core.Runtime.Directive, only: [stop: 0, schedule: 2, spawn_task: 1]

      stop()
      schedule(1_000, :tick)
      spawn_task(fn -> {:result, expensive_op()} end)

  ## Dispatch

  Each struct implements `Raxol.Core.Runtime.Directive.Executor`. The
  runtime invokes the protocol's `execute/2` with a context map containing
  at minimum `:pid` and `:runtime_pid`. Result messages arrive at
  `context.pid` as `{:command_result, payload}` (the message name is
  historical; both the old `Command` system and the directive system use
  it).

  External packages register additional directives by defining a struct
  and implementing `Raxol.Core.Runtime.Directive.Executor` for it.
  """

  alias __MODULE__.{Schedule, Spawn, Stop}

  @type t :: Stop.t() | Schedule.t() | Spawn.t() | struct()

  defmodule Stop do
    @moduledoc """
    Signal the runtime to stop. Sends `:quit_runtime` to `context.runtime_pid`.
    """

    @type t :: %__MODULE__{reason: term()}

    defstruct reason: :normal
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
    `{:command_result, result}`. Use `Raxol.Agent.Directive.async/1`
    (from raxol_agent) when the task needs to send multiple messages.
    """

    @type t :: %__MODULE__{fun: (-> any())}

    @enforce_keys [:fun]
    defstruct [:fun]
  end

  @doc "Construct a `Stop` directive."
  @spec stop(term()) :: Stop.t()
  def stop(reason \\ :normal), do: %Stop{reason: reason}

  @doc "Construct a `Schedule` directive. `interval_ms` must be non-negative."
  @spec schedule(non_neg_integer(), term()) :: Schedule.t()
  def schedule(interval_ms, payload)
      when is_integer(interval_ms) and interval_ms >= 0 do
    %Schedule{interval_ms: interval_ms, payload: payload}
  end

  @doc "Construct a `Spawn` directive with a no-arg function."
  @spec spawn_task((-> any())) :: Spawn.t()
  def spawn_task(fun) when is_function(fun, 0), do: %Spawn{fun: fun}
end
