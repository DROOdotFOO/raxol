defmodule Raxol.Agent.Cache.Ets do
  @moduledoc """
  ETS-backed `Raxol.Agent.Cache` adapter.

  Stores entries in a named ETS table created lazily on the first
  call. The table is `:public` and `:set` keyed on the user's term;
  values are wrapped with their absolute expiry timestamp so
  `get/2` can decide stale-vs-fresh with a single comparison.

  ## Config

      %{table: :my_agent_cache}

  Defaults to `:raxol_agent_cache` when the `:table` key is absent.
  Two agents sharing the same table name share its entries; isolate
  per-agent by passing distinct table names.

  ## Lifetime

  The table lives for the duration of the BEAM. It is not supervised
  and does not survive `Application.stop/1`. Use
  `Raxol.Agent.Cache.Postgrex` when cache entries must outlive the
  BEAM or be shared across nodes.

  ## Lazy expiry

  `get/2` checks the wrapped expiry against `DateTime.utc_now/0`. A
  stale entry returns `:miss` and is removed from the table in the
  same call. No background sweeper; expired-but-unread entries
  occupy table memory until either `get/2` checks them or
  `flush/1` clears the table.

  ## Not for very-high-throughput shared writes

  ETS handles concurrent reads + writes fine, but two writers to the
  same key racing through `put/4` will both succeed; the second
  silently overwrites the first. The Saver-style append-only contract
  does not apply to caches; last-write-wins is the intended cache
  semantics.
  """

  @behaviour Raxol.Agent.Cache

  @default_table :raxol_agent_cache

  @doc "Ensure the configured ETS table exists. Idempotent."
  @spec ensure_table(map()) :: atom()
  def ensure_table(config) do
    table = Map.get(config, :table, @default_table)

    case :ets.whereis(table) do
      :undefined ->
        _ =
          :ets.new(table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        :ok

      _ref ->
        :ok
    end

    table
  end

  @impl true
  def get(config, key) do
    table = ensure_table(config)

    case :ets.lookup(table, key) do
      [{^key, value, :no_expiry}] ->
        {:ok, value}

      [{^key, value, %DateTime{} = expiry}] ->
        if DateTime.compare(expiry, DateTime.utc_now()) == :gt do
          {:ok, value}
        else
          _ = :ets.delete(table, key)
          :miss
        end

      [] ->
        :miss
    end
  end

  @impl true
  def put(config, key, value, 0) do
    table = ensure_table(config)
    _ = :ets.insert(table, {key, value, :no_expiry})
    :ok
  end

  def put(config, key, value, ttl_ms) when ttl_ms > 0 do
    table = ensure_table(config)
    expiry = DateTime.add(DateTime.utc_now(), ttl_ms, :millisecond)
    _ = :ets.insert(table, {key, value, expiry})
    :ok
  end

  @impl true
  def delete(config, key) do
    table = ensure_table(config)
    _ = :ets.delete(table, key)
    :ok
  end

  @impl true
  def flush(config) do
    table = ensure_table(config)
    _ = :ets.delete_all_objects(table)
    :ok
  end
end
