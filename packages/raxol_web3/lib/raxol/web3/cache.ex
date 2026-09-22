defmodule Raxol.Web3.Cache do
  @moduledoc """
  The response cache: four functions, lazy expiry, one owned bounded table.

  ADR-0033 decision 6. `Raxol.Agent.Cache` is the shape this copies, and the
  copy is deliberate: that module lives in `raxol_agent`, which depends on main
  `raxol`, so consuming it would pull the framework and the agent runtime
  underneath a read-only package. Lifting it into `raxol_core` is the right
  eventual move and is not this package's to make, so the four callbacks are
  reproduced here (`get`, `put`, `delete`, `flush`, TTL in milliseconds, `0`
  meaning no expiry, expiry checked lazily on read) and the two converge
  cheaply when someone merges them.

  Three deliberate divergences from that module, each with a reason:

    * **No `config` argument and no behaviour.** `Raxol.Agent.Cache` dispatches
      on `{module, config}` because a caller chooses its own table or a
      Postgres connection. Here the table has exactly one owner
      (`Raxol.Web3.Tables`, ADR-0038 decision 5), so there is nothing to
      configure and a per-call config would be a parameter that can only be
      passed wrongly. A second storage medium, if one is ever needed, arrives
      as a behaviour at that point rather than as an abstraction waiting for it.
    * **Monotonic time, not wall clock.** `Raxol.Agent.Cache.Ets` compares
      against `DateTime.utc_now/0`. A clock stepping backwards, which happens
      on a VM resumed from a snapshot, extends every outstanding TTL by the
      size of the step. Monotonic milliseconds cannot do that.
    * **A bounded table.** `Raxol.Agent.Cache.Ets` grows until someone calls
      `clear/1`, which is right for a store whose owner decides its lifetime.
      This table's owner is the application, so its lifetime is the node's,
      and "until someone clears it" is not a bound. What replaces it is below.

  ## Keys never come from a URL

  `Raxol.Web3.HTTP` composes a key as `{origin_id, fragment}`, where the
  fragment is supplied by the backend from its own endpoint name and the
  parameters that endpoint declares. The request URI is never an input. That is
  ADR-0033 §7's rule about cache keys made structural rather than reviewed: an
  API key travels as a query parameter on one of the upstreams this package
  targets, so a key derived from a URI is a credential written into a table
  that something will eventually dump.

  ## What bounds the table

  Lazy expiry on its own bounds nothing: an entry that expires and is never
  read again is never looked at, so nothing deletes it. Two explicit ceilings
  do the bounding, and neither needs a timer or a process.

    * `config :raxol_web3, :cache_max_entries` (default `512`) caps the row
      count. A `put/3` that would grow the table past the cap first reclaims
      every expired row, then evicts live rows until the table is back under a
      low-water mark of seven eighths of the cap. Freeing an eighth at a time
      rather than one row at a time is what keeps this cheap: the pass walks
      keys and expiries with a single `:ets.select/2` and never copies a
      value, and a full table pays for one such pass per 64 inserts at the
      default.
    * `config :raxol_web3, :cache_max_value_bytes` (default `262_144`, 256
      KiB) declines to store a value larger than that. `put/3` still answers
      `:ok` and the next `get/1` is a miss. This is the ceiling that makes the
      first one mean something: `Raxol.MCP.BoundedExchange` reads a body up to
      its `:max_bytes` (2 MiB by default), so an entry cap alone bounds this
      table at 512 × 2 MiB, which is a bound and not a useful one. With both,
      it is 128 MiB. 256 KiB sits above what these read endpoints actually
      return — a transaction, a page of logs, a token-balance list are
      single-digit kilobytes — so what it excludes is the rare extreme, which
      is also the entry least worth holding 2 MiB of a long-lived node's
      memory for.

  Eviction is by soonest expiry, with `:no_expiry` rows going last. That is
  deterministic and therefore assertable: a test fills past the cap and names
  the key that must be gone. An LRU would need a write on every read, which
  costs more than it saves on a table whose rows all carry an expiry anyway.

  Both ceilings are checked before an insert rather than after, so the table
  can hold cap + 1 rows for the length of one `put/3`, and two callers racing
  at the cap can each sweep and leave it under the low-water mark. Neither
  matters: the point is a ceiling, not an exact size.

  ## What is worth caching, and what is not

  A finalized transaction is immutable and can be cached for a long time. Chain
  statistics are seconds. A **height is not cached at all**, and that is the
  one rule here that is about correctness rather than freshness: a cached
  height read alongside a live one is exactly what breaks the monotonicity
  `Raxol.Web3.Backend`'s height shape exists to express. `Raxol.Web3.TTL`
  carries the per-endpoint values.
  """

  alias Raxol.Web3.Tables

  @default_max_entries 512
  @default_max_value_bytes 262_144

  @type key :: term()
  @type value :: term()
  @type ttl_ms :: non_neg_integer()

  @doc """
  Fetch a fresh entry.

  A stale entry is deleted in the same call and reported as a miss, so a key
  that is read keeps its own memory in check. An expired entry that is never
  read again is reclaimed by the next `put/3` that needs the room, or by
  `flush/0`.
  """
  @spec get(key()) :: {:ok, value()} | :miss
  def get(key) do
    case :ets.lookup(Tables.cache(), key) do
      [{^key, value, :no_expiry}] -> {:ok, value}
      [{^key, value, expires_at}] -> fresh_or_expire(key, value, expires_at)
      [] -> :miss
    end
  end

  @doc """
  Store a value for `ttl_ms` milliseconds.

  `0` means no expiry. A negative TTL raises rather than being clamped: it is
  a caller's arithmetic mistake, and silently treating it as "expired already"
  or "never" would hide the bug behind a cache that merely looks cold.

  A value over `:cache_max_value_bytes` is not stored, and storing may evict
  other entries to stay under `:cache_max_entries`; the moduledoc has both.
  Either way the answer is `:ok`, because "the cache declined to hold this" is
  not a caller's error to handle.
  """
  @spec put(key(), value(), ttl_ms()) :: :ok
  def put(key, value, 0), do: insert(key, value, :no_expiry)

  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    insert(key, value, now_ms() + ttl_ms)
  end

  def put(_key, _value, ttl_ms) do
    raise ArgumentError, "ttl_ms must be a non-negative integer, got: #{inspect(ttl_ms)}"
  end

  @doc "Forget one key."
  @spec delete(key()) :: :ok
  def delete(key) do
    :ets.delete(Tables.cache(), key)
    :ok
  end

  @doc "Forget everything."
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(Tables.cache())
    :ok
  end

  defp insert(key, value, expires_at) do
    if :erlang.external_size(value) > max_value_bytes() do
      :ok
    else
      insert_bounded(key, value, expires_at)
    end
  end

  # The `:ets.member/2` check is what keeps a hot key cheap: overwriting a row
  # that is already there does not grow the table, so refreshing one entry at
  # the cap must not cost an eighth of the cache.
  defp insert_bounded(key, value, expires_at) do
    table = Tables.cache()

    if :ets.info(table, :size) >= max_entries() and not :ets.member(table, key) do
      make_room(table)
    end

    :ets.insert(table, {key, value, expires_at})
    :ok
  end

  # One `:ets.select/2` over keys and expiries: the values, which are the large
  # half of a row, are never copied out to decide what to drop. Expired rows go
  # first because they are free, then live rows by soonest expiry. `:no_expiry`
  # sorts after every integer in Erlang term order, so the rows a caller asked
  # to keep forever are the last to go.
  defp make_room(table) do
    now = now_ms()

    {expired, live} =
      table
      |> :ets.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.split_with(fn {_key, expires_at} -> expired?(expires_at, now) end)

    Enum.each(expired, &delete_row(table, &1))

    surplus = length(live) - low_water()

    if surplus > 0 do
      live
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(surplus)
      |> Enum.each(&delete_row(table, &1))
    end

    :ok
  end

  defp delete_row(table, {key, _expires_at}), do: :ets.delete(table, key)

  defp expired?(:no_expiry, _now), do: false
  defp expired?(expires_at, now), do: now >= expires_at

  defp low_water do
    cap = max_entries()
    cap - max(1, div(cap, 8))
  end

  defp max_entries do
    Application.get_env(:raxol_web3, :cache_max_entries, @default_max_entries)
  end

  defp max_value_bytes do
    Application.get_env(:raxol_web3, :cache_max_value_bytes, @default_max_value_bytes)
  end

  defp fresh_or_expire(key, value, expires_at) do
    if now_ms() < expires_at do
      {:ok, value}
    else
      delete(key)
      :miss
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
