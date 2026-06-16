defmodule Raxol.Agent.Policy.Timeout do
  @moduledoc """
  Timeout policy: abort an operation after `:wall_ms` elapsed
  wall-clock time.

  Implementation: `Raxol.Agent.PolicyApplier` spawns the wrapped
  function in a `Task` and uses `Task.yield/2` + `Task.shutdown/2`
  to enforce the bound. On timeout the result is
  `{:error, :timeout}` and a `[:raxol, :agent, :policy, :timeout]`
  telemetry event fires.

  ## Fields

  - `wall_ms` -- timeout in milliseconds; must be `>= 1`

  ## Constructors

      Policy.Timeout.new(30_000)
      Policy.Timeout.new(wall_ms: 30_000)
  """

  @type t :: %__MODULE__{wall_ms: pos_integer()}

  @enforce_keys [:wall_ms]
  defstruct [:wall_ms]

  @doc "Construct a timeout policy from a positive integer or keyword opts."
  @spec new(pos_integer() | keyword()) :: t()
  def new(wall_ms) when is_integer(wall_ms) and wall_ms >= 1,
    do: %__MODULE__{wall_ms: wall_ms}

  def new(opts) when is_list(opts) do
    case Keyword.fetch!(opts, :wall_ms) do
      n when is_integer(n) and n >= 1 ->
        %__MODULE__{wall_ms: n}

      other ->
        raise ArgumentError,
              ":wall_ms must be a positive integer, got: #{inspect(other)}"
    end
  end

  def new(other),
    do:
      raise(
        ArgumentError,
        "Timeout.new/1 expects pos_integer or keyword, got: #{inspect(other)}"
      )
end
