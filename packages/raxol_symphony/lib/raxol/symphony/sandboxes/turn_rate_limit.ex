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

  This is a sliding window log. The table holds, per `issue_id`, the
  timestamp of every turn admitted in the last `window_ms`. On each
  `:turn` authorization:

  1. Drop entries older than `now - window_ms` for this `issue_id`.
  2. If `max_turns` entries remain, return `{:deny, :rate_limited}`.
  3. Otherwise record `now` and return `:ok`.

  The guarantee is a hard cap: no `window_ms` period anywhere on the
  timeline contains more than `max_turns` admitted turns.

  ## Why not `Raxol.Core.TokenBucket`

  The shared limiter is the right primitive when the limit belongs to
  an upstream and a burst is the thing to smooth. It is the wrong one
  here. A bucket sized `capacity: max_turns` starts full and refills
  while it drains, so one `window_ms` can admit close to twice
  `max_turns`. Operators write `max_turns` into `WORKFLOW.md` as the
  number of agent turns an issue may burn, and converging on the bucket
  would silently double every budget already configured against that
  reading. This is an authorization control, so the log stays.

  ## Concurrency

  `admit/3` commits with `:ets.select_replace/2`, which lands only if
  the issue's entry has not changed since it was read, and retries on a
  lost race. Concurrent authorizations for one `issue_id` therefore
  admit `max_turns` turns rather than over-admitting by the number of
  processes that read the same count. A commit that cannot land after
  repeated retries denies, because a limiter that cannot write must
  fail closed.

  Multiple Symphony orchestrators sharing one `bucket_table` see each
  other's counts, which is the intent for multi-orchestrator
  deployments. Isolate orchestrators by giving each its own
  `bucket_table`.

  ## Table lifetime

  The table is created on first use and is owned by whichever process
  created it, so it dies with that process. Left to `authorize/4` that
  owner is an agent process, and a crash there drops every issue's
  count. Call `ensure_table/1` from a supervised process at boot to
  give the counts a stable owner.

  ## Memory

  A row holds at most `max_turns` timestamps, and it is pruned when
  that same issue asks for another turn. Nothing prunes an issue that
  goes quiet, so a long-lived table keeps one row per issue id it has
  ever seen. Call `sweep/2` on whatever schedule suits the deployment
  to drop the rows whose whole window has elapsed.

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

  @max_commit_attempts 100

  @doc "Idempotently create the ETS bucket table."
  @spec ensure_table(atom()) :: atom()
  def ensure_table(table) when is_atom(table) do
    case :ets.whereis(table) do
      :undefined -> create_table(table)
      _ref -> table
    end
  end

  @doc """
  Authorize one turn for `issue_id`, recording it when admitted.

  `now_ms` is monotonic milliseconds and defaults to the system clock;
  tests pass it to walk the window without sleeping. Returns `:ok` when
  the turn fits under the cap and `{:deny, :rate_limited}` when it does
  not.
  """
  @spec admit(t(), term(), integer()) :: :ok | {:deny, :rate_limited}
  def admit(sandbox, issue_id, now_ms \\ System.monotonic_time(:millisecond))

  def admit(%__MODULE__{} = sandbox, issue_id, now_ms) when is_integer(now_ms) do
    table = ensure_table(sandbox.bucket_table)
    limit = %{max_turns: sandbox.max_turns, cutoff: now_ms - sandbox.window_ms}

    commit(table, issue_id, limit, now_ms, @max_commit_attempts)
  end

  @doc """
  Delete the rows whose whole window has elapsed, returning how many went.

  Pruning otherwise happens only for an issue that asks for another
  turn, so this is what keeps a long-lived table proportional to the
  issues currently working rather than to every issue ever seen. Safe to
  call concurrently with `admit/3`: a row deleted a moment before a turn
  is indistinguishable from one whose entries all aged out, which is
  exactly what the deletion established.
  """
  @spec sweep(t(), integer()) :: non_neg_integer()
  def sweep(sandbox, now_ms \\ System.monotonic_time(:millisecond))

  def sweep(%__MODULE__{} = sandbox, now_ms) when is_integer(now_ms) do
    table = ensure_table(sandbox.bucket_table)
    cutoff = now_ms - sandbox.window_ms

    # Timestamps are prepended in monotonic order, so the head of a row is its
    # newest entry. A row whose newest entry has aged out is entirely stale.
    :ets.select_delete(table, [{{:_, :"$1"}, [{:"=<", {:hd, :"$1"}, cutoff}], [true]}])
  end

  # -- Private -----------------------------------------------------------------

  defp create_table(table) do
    _ =
      :ets.new(table, [
        :set,
        :public,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    table
  rescue
    error in ArgumentError ->
      # Another process won the create between the whereis and the new. Any
      # other ArgumentError is a real one and must not be swallowed.
      if :ets.whereis(table) == :undefined do
        reraise(error, __STACKTRACE__)
      else
        table
      end
  end

  # A limiter that cannot commit fails closed.
  defp commit(_table, _issue_id, _limit, _now_ms, 0), do: {:deny, :rate_limited}

  defp commit(table, issue_id, limit, now_ms, attempts) do
    case :ets.lookup(table, issue_id) do
      [] ->
        insert_first(table, issue_id, limit, now_ms, attempts)

      [{^issue_id, stamps} = current] ->
        kept = Enum.filter(stamps, &(&1 > limit.cutoff))
        replace(table, issue_id, limit, now_ms, attempts, current, kept)
    end
  end

  defp insert_first(_table, _issue_id, limit, _now_ms, _attempts)
       when limit.max_turns < 1 do
    {:deny, :rate_limited}
  end

  defp insert_first(table, issue_id, limit, now_ms, attempts) do
    if :ets.insert_new(table, {issue_id, [now_ms]}) do
      :ok
    else
      commit(table, issue_id, limit, now_ms, attempts - 1)
    end
  end

  defp replace(_table, _issue_id, limit, _now_ms, _attempts, _current, kept)
       when length(kept) >= limit.max_turns do
    {:deny, :rate_limited}
  end

  defp replace(table, issue_id, limit, now_ms, attempts, current, kept) do
    case :ets.select_replace(table, [{current, [], [{:const, {issue_id, [now_ms | kept]}}]}]) do
      1 -> :ok
      0 -> commit(table, issue_id, limit, now_ms, attempts - 1)
    end
  end
end

defimpl Raxol.Agent.Sandbox, for: Raxol.Symphony.Sandboxes.TurnRateLimit do
  alias Raxol.Symphony.Sandboxes.TurnRateLimit

  def authorize(%TurnRateLimit{} = sandbox, :turn, %{issue_id: issue_id}, _ctx) do
    TurnRateLimit.admit(sandbox, issue_id)
  end

  def authorize(_sandbox, _action, _payload, _ctx), do: :ok
end
