defmodule Raxol.Web3.Cache do
  @moduledoc """
  The response cache: four functions, lazy expiry, one owned table.

  ADR-0033 decision 6. `Raxol.Agent.Cache` is the shape this copies, and the
  copy is deliberate: that module lives in `raxol_agent`, which depends on main
  `raxol`, so consuming it would pull the framework and the agent runtime
  underneath a read-only package. Lifting it into `raxol_core` is the right
  eventual move and is not this package's to make, so the four callbacks are
  reproduced here (`get`, `put`, `delete`, `flush`, TTL in milliseconds, `0`
  meaning no expiry, expiry checked lazily on read) and the two converge
  cheaply when someone merges them.

  Two deliberate divergences from that module, both with reasons:

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

  ## Keys never come from a URL

  `Raxol.Web3.HTTP` composes a key as `{origin_id, fragment}`, where the
  fragment is supplied by the backend from its own endpoint name and the
  parameters that endpoint declares. The request URI is never an input. That is
  ADR-0033 §7's rule about cache keys made structural rather than reviewed: an
  API key travels as a query parameter on one of the upstreams this package
  targets, so a key derived from a URI is a credential written into a table
  that something will eventually dump.

  ## What is worth caching, and what is not

  A finalized transaction is immutable and can be cached for a long time. Chain
  statistics are seconds. A **height is not cached at all**, and that is the
  one rule here that is about correctness rather than freshness: a cached
  height read alongside a live one is exactly what breaks the monotonicity
  `Raxol.Web3.Backend`'s height shape exists to express. `Raxol.Web3.TTL`
  carries the per-endpoint values.
  """

  alias Raxol.Web3.Tables

  @type key :: term()
  @type value :: term()
  @type ttl_ms :: non_neg_integer()

  @doc """
  Fetch a fresh entry.

  A stale entry is deleted in the same call and reported as a miss, so a key
  that is read keeps its own memory in check without a sweeper. An
  expired-but-never-read entry occupies the table until `flush/0`.
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
    :ets.insert(Tables.cache(), {key, value, expires_at})
    :ok
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
