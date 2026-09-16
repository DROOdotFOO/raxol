defmodule Raxol.Web3.Tables do
  @moduledoc """
  The one process that owns this package's ETS tables.

  ADR-0038 decision 5, and it is not a detail. `:ets.new/2` tables are owned by
  the process that creates them, so "a public ETS table with no owning process"
  is not a thing that can be built, and letting each caller create its own has
  three distinct failure modes:

    * a token bucket created by a short-lived process resets to full capacity
      when that process dies, so a free-tier budget is spent once per process
      rather than once per node;
    * a circuit breaker created per caller never observes anyone else's
      failures, so failover never trips;
    * a lookup against a table whose owner has died raises `ArgumentError`
      inside whichever process still holds the reference, which is a crash
      rather than an error tuple.

  So the tables are created once, here, at application boot, and handed out
  through `:persistent_term`: a lock-free read on a value written once, rather
  than a message to this process on every outbound request.

  This process holds no logic of its own. It creates tables in `init/1` and
  answers nothing, which is what makes the restart window theoretical rather
  than a live concern: there is no code path in it that can fail after boot. A
  restart re-creates the tables and overwrites the `:persistent_term` entries,
  and a caller that read a reference in between sees `ArgumentError` from ETS.
  Callers therefore read through `buckets/0` and `breakers/0` per request
  rather than caching a reference.

  The cursor MAC key lives here too. It is not a table, but it has the same
  lifetime question and the same answer: minted once at boot, so every cursor
  this node emits verifies against every cursor it is handed back.

  `Raxol.Web3.Cache`'s table is owned here for the same reason as the other
  two, and one more: a cache created per caller is a cache that never hits.
  """

  use GenServer

  alias Raxol.Core.TokenBucket
  alias Raxol.MCP.CircuitBreaker

  @buckets {__MODULE__, :buckets}
  @breakers {__MODULE__, :breakers}
  @origins {__MODULE__, :origins}
  @cache {__MODULE__, :cache}
  @cursor_key {__MODULE__, :cursor_key}

  @cursor_key_bytes 32

  @doc "Start the table owner. One per node, named."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "The token-bucket table, keyed per upstream origin."
  @spec buckets() :: :ets.table()
  def buckets, do: :persistent_term.get(@buckets)

  @doc "The circuit-breaker table, keyed `{:origin, origin_id}`."
  @spec breakers() :: :ets.table()
  def breakers, do: :persistent_term.get(@breakers)

  @doc """
  The origin-id table: `origin_id -> origin`.

  Node-local and read deliberately, which is the whole point. An error term
  carries the id, so a log line, a telemetry measurement or a model-visible
  response never carries a host that may itself be a credential (a per-account
  URL names the account). An operator holding the node resolves the id through
  `Raxol.Web3.Origin.resolve/1`.
  """
  @spec origins() :: :ets.table()
  def origins, do: :persistent_term.get(@origins)

  @doc """
  The response-cache table.

  `:set` with write concurrency, because last-write-wins is the intended
  semantics: two callers racing to cache the same response both succeed and the
  second overwrites an identical value.
  """
  @spec cache() :: :ets.table()
  def cache, do: :persistent_term.get(@cache)

  @doc """
  The key cursors are signed with.

  Random per boot when `config :raxol_web3, :cursor_key` is absent. Random is
  right for one node and wrong for a fleet: a cursor minted on one node does
  not verify on another, so a load-balanced deployment that pages across nodes
  has to configure a shared key of at least 32 bytes. A present but malformed
  key is a boot error rather than a silent random-key fallback. ADR-0038 records
  the cost either way, since a rotation invalidates outstanding cursors and a
  paging caller restarts its walk.
  """
  @spec cursor_key() :: binary()
  def cursor_key, do: :persistent_term.get(@cursor_key)

  @impl GenServer
  def init(_opts) do
    # Validate configuration before creating tables or publishing any
    # persistent terms: a rejected key must leave no half-initialized owner.
    cursor_key = configured_cursor_key()

    :persistent_term.put(@buckets, TokenBucket.new(:raxol_web3_buckets))
    :persistent_term.put(@breakers, CircuitBreaker.new(:raxol_web3_breakers))

    :persistent_term.put(
      @origins,
      :ets.new(:raxol_web3_origins, [:set, :public, read_concurrency: true])
    )

    :persistent_term.put(
      @cache,
      :ets.new(:raxol_web3_cache, [
        :set,
        :public,
        read_concurrency: true,
        write_concurrency: true
      ])
    )

    :persistent_term.put(@cursor_key, cursor_key)

    {:ok, %{}}
  end

  defp configured_cursor_key do
    case Application.fetch_env(:raxol_web3, :cursor_key) do
      :error ->
        :crypto.strong_rand_bytes(@cursor_key_bytes)

      {:ok, key} when is_binary(key) and byte_size(key) >= @cursor_key_bytes ->
        key

      {:ok, _invalid} ->
        raise ArgumentError,
              "config :raxol_web3, :cursor_key must be a binary of at least #{@cursor_key_bytes} bytes"
    end
  end
end
