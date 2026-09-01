defmodule Raxol.Core.TokenBucket do
  @moduledoc """
  ETS-backed token bucket, the shared rate-limiting primitive.

  A bucket holds at most `:capacity` tokens and regains them at `:refill_per_second`.
  `take/3` removes tokens and refuses once the bucket cannot cover the cost, so a caller
  may burst up to `:capacity` and then proceeds at the refill rate. This is the algorithm
  to reach for when the limit being respected belongs to somebody else, because a
  fixed-window counter admits two full windows worth of calls across a window boundary,
  which is exactly the burst an upstream penalises.

  There is no owning process. All state lives in a public ETS table created by the caller,
  so buckets are keyed per upstream origin (or per user, or per action) and two callers
  never contend on a single mailbox.

      alias Raxol.Core.TokenBucket

      table = TokenBucket.new()
      limit = [capacity: 30, refill_per_second: 5.0]

      case TokenBucket.take(table, "trongrid", limit) do
        {:ok, _remaining} ->
          call_upstream()

        {:error, :rate_limited} ->
          {:error, {:retry_after, TokenBucket.retry_after(table, "trongrid", limit)}}
      end

  ## The limit belongs to the caller

  `:capacity` and `:refill_per_second` are required on every call and are never read from
  application environment. One table therefore holds buckets with different limits, which
  is the normal case when each key is a different upstream. The consequence is that the
  caller owns the limit for a key and must pass the same one consistently; passing a
  smaller `:capacity` later simply clamps that key's stored tokens down to it.

  ## Time

  Refill is computed from elapsed monotonic milliseconds, and fractional tokens survive
  across calls. Pass `:now_ms` to supply the clock yourself, which is how the tests stay
  deterministic without sleeping. A `:now_ms` that moves backwards is clamped to zero
  elapsed, so it can never drain a bucket.

  ## Concurrency

  `take/3` is atomic. It reads the bucket, then commits with `:ets.select_replace/2`,
  which only succeeds if nothing changed underneath, and retries on a lost race. Under
  concurrent takes against an empty-refill bucket, exactly `:capacity` calls are admitted.
  """

  @type table :: :ets.table()
  @type key :: term()

  @max_commit_attempts 100

  @doc """
  Create a bucket table.

  The table is public and owned by the calling process, so it lives exactly as long as
  that process. Pass the returned reference to `take/3` and friends.
  """
  @spec new(atom()) :: :ets.table()
  def new(name \\ :raxol_token_buckets) when is_atom(name) do
    :ets.new(name, [:set, :public, read_concurrency: true, write_concurrency: true])
  end

  @doc """
  Take tokens from a bucket, refilling it for the time elapsed first.

  Returns `{:ok, remaining}` when the bucket covered the cost, `{:error, :rate_limited}`
  when it did not. A bucket that has never been seen starts full.

  ## Options

    * `:capacity` (required) - burst size, a positive number of tokens
    * `:refill_per_second` (required) - tokens regained per second, a positive number
    * `:cost` - tokens this call consumes, defaults to `1`, must not exceed `:capacity`
    * `:now_ms` - monotonic milliseconds, defaults to `System.monotonic_time(:millisecond)`
  """
  @spec take(table(), key(), keyword()) :: {:ok, float()} | {:error, :rate_limited}
  def take(table, key, opts \\ []) when is_list(opts) do
    commit(table, key, limit(opts), now_ms(opts), @max_commit_attempts)
  end

  @doc """
  Tokens currently available, refilled for the time elapsed but not consumed.

  Takes the same options as `take/3`, except `:cost`, which is irrelevant to a read.
  """
  @spec peek(table(), key(), keyword()) :: float()
  def peek(table, key, opts \\ []) when is_list(opts) do
    available(table, key, limit(opts), now_ms(opts))
  end

  @doc """
  Milliseconds until `:cost` tokens are available, rounded up.

  Returns `0` when the bucket can already cover the cost, which makes it safe to use as a
  `Retry-After` hint without a branch. Takes the same options as `take/3`.
  """
  @spec retry_after(table(), key(), keyword()) :: non_neg_integer()
  def retry_after(table, key, opts \\ []) when is_list(opts) do
    lim = limit(opts)
    deficit = lim.cost - available(table, key, lim, now_ms(opts))

    if deficit <= 0, do: 0, else: ceil(deficit / lim.refill_per_second * 1000)
  end

  @doc "Forget a bucket, so the next `take/3` starts from a full one."
  @spec reset(table(), key()) :: :ok
  def reset(table, key) do
    :ets.delete(table, key)
    :ok
  end

  @doc "Forget every bucket in the table."
  @spec reset_all(table()) :: :ok
  def reset_all(table) do
    :ets.delete_all_objects(table)
    :ok
  end

  # -- Private -----------------------------------------------------------------

  # Out of retries. A limiter that cannot commit fails closed.
  defp commit(_table, _key, _limit, _now, 0), do: {:error, :rate_limited}

  defp commit(table, key, limit, now, attempts) do
    case :ets.lookup(table, key) do
      [] ->
        insert_fresh(table, key, limit, now, attempts)

      [{^key, tokens, last_ms} = current] ->
        replace(table, key, limit, now, attempts, current, refill(tokens, last_ms, now, limit))
    end
  end

  defp insert_fresh(table, key, limit, now, attempts) do
    remaining = limit.capacity - limit.cost

    if :ets.insert_new(table, {key, remaining, now}) do
      {:ok, remaining}
    else
      commit(table, key, limit, now, attempts - 1)
    end
  end

  defp replace(_table, _key, limit, _now, _attempts, _current, tokens)
       when tokens < limit.cost do
    {:error, :rate_limited}
  end

  defp replace(table, key, limit, now, attempts, current, tokens) do
    remaining = tokens - limit.cost

    case :ets.select_replace(table, [{current, [], [{:const, {key, remaining, now}}]}]) do
      1 -> {:ok, remaining}
      0 -> commit(table, key, limit, now, attempts - 1)
    end
  end

  defp available(table, key, limit, now) do
    case :ets.lookup(table, key) do
      [] -> limit.capacity
      [{^key, tokens, last_ms}] -> refill(tokens, last_ms, now, limit)
    end
  end

  # Elapsed is clamped so a clock that moves backwards cannot drain a bucket.
  defp refill(tokens, last_ms, now_ms, limit) do
    elapsed_ms = max(now_ms - last_ms, 0)
    min(tokens + elapsed_ms / 1000 * limit.refill_per_second, limit.capacity)
  end

  defp now_ms(opts) do
    Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
  end

  defp limit(opts) do
    capacity = required(opts, :capacity)
    refill_per_second = required(opts, :refill_per_second)
    cost = Keyword.get(opts, :cost, 1)

    validate_cost(cost, capacity)

    %{capacity: capacity * 1.0, refill_per_second: refill_per_second * 1.0, cost: cost * 1.0}
  end

  defp required(opts, name) do
    case Keyword.fetch(opts, name) do
      {:ok, value} when is_number(value) and value > 0 ->
        value

      {:ok, value} ->
        raise ArgumentError, ":#{name} must be a positive number, got: #{inspect(value)}"

      :error ->
        raise ArgumentError,
              ":#{name} is required. A rate limit belongs to the upstream being called, " <>
                "so there is no correct default for it"
    end
  end

  defp validate_cost(cost, _capacity) when not is_number(cost) or cost <= 0 do
    raise ArgumentError, ":cost must be a positive number, got: #{inspect(cost)}"
  end

  defp validate_cost(cost, capacity) when cost > capacity do
    raise ArgumentError,
          ":cost #{cost} exceeds :capacity #{capacity}, so it could never be taken"
  end

  defp validate_cost(_cost, _capacity), do: :ok
end
