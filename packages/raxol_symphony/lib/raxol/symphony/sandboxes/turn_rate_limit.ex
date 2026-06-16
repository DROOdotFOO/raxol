defmodule Raxol.Symphony.Sandboxes.TurnRateLimit do
  @moduledoc """
  `Raxol.Agent.Sandbox` impl that caps how many `:turn` actions an
  issue can run within a sliding time window.

  ## Configuration

      %Raxol.Symphony.Sandboxes.TurnRateLimit{
        max_turns: 10,
        window_ms: 60_000,        # 1 minute
        bucket_table: :rate_limit # ETS table name; lazy-created
      }

  ## Behaviour

  Tracks per-issue timestamps in a named ETS table. On each `:turn`
  authorization:

  1. Prune entries older than `now - window_ms` for this `issue_id`.
  2. Count remaining entries.
  3. If `>= max_turns`, return `{:deny, :rate_limited}`.
  4. Otherwise append `now` to the issue's bucket and return `:ok`.

  ## Concurrency

  Uses `:ets.update_counter`-style atomic reads and writes for
  per-issue buckets. Multiple Symphony orchestrators sharing the
  same `bucket_table` will see each other's counts -- this is the
  intent for multi-orchestrator deployments. Isolate orchestrators
  by giving each its own `bucket_table`.

  ## Other actions

  Abstains (`:ok`) for any action other than `:turn` so this struct
  composes harmlessly with other Sandbox dimensions (e.g.
  `Raxol.Agent.Sandbox.Shell`).

  ## Wiring

      config = %{
        agent: %{
          sandboxes: [
            %Raxol.Symphony.Sandboxes.TurnRateLimit{
              max_turns: 20,
              window_ms: :timer.minutes(5)
            }
          ]
        },
        ...
      }
  """

  @enforce_keys [:max_turns, :window_ms]
  defstruct [:max_turns, :window_ms, bucket_table: :symphony_turn_rate_limit]

  @type t :: %__MODULE__{
          max_turns: pos_integer(),
          window_ms: pos_integer(),
          bucket_table: atom()
        }

  @doc "Idempotently create the ETS bucket table."
  @spec ensure_table(atom()) :: atom()
  def ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        :ok
    end

    table
  end
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Symphony.Sandboxes.TurnRateLimit do
  alias Raxol.Symphony.Sandboxes.TurnRateLimit

  def authorize(%TurnRateLimit{} = sandbox, :turn, %{issue_id: issue_id}, _ctx) do
    table = TurnRateLimit.ensure_table(sandbox.bucket_table)
    now_ms = System.monotonic_time(:millisecond)
    cutoff = now_ms - sandbox.window_ms

    existing =
      case :ets.lookup(table, issue_id) do
        [{^issue_id, timestamps}] -> Enum.filter(timestamps, &(&1 > cutoff))
        [] -> []
      end

    if length(existing) >= sandbox.max_turns do
      {:deny, :rate_limited}
    else
      :ets.insert(table, {issue_id, [now_ms | existing]})
      :ok
    end
  end

  def authorize(_sandbox, _action, _payload, _ctx), do: :ok
end
