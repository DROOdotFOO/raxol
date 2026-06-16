defmodule Raxol.Agent.Cache do
  @moduledoc """
  Behaviour for `Raxol.Agent.Policy.Cache` storage.

  Implementations decide the storage medium. Two adapters ship with
  raxol_agent:

    * `Raxol.Agent.Cache.Ets` -- in-process, named ETS table; the
      default for single-node agents.
    * `Raxol.Agent.Cache.Postgrex` -- Postgres-backed via the
      optional `:postgrex` dependency; the default for cross-process
      or multi-node sharing.

  ## TTL contract

  `put/4` takes a TTL in milliseconds. Implementations record the
  absolute expiry (`DateTime.utc_now + ttl_ms`) and serve `get/2` as
  `{:ok, value}` while not expired, `:miss` once expired. Expiry is
  lazy by default: a `get/2` on a stale entry returns `:miss` and
  the entry is removed. Adapters that want eager sweep (background
  GenServer that scans and deletes expired entries) are free to do
  so without breaking the lazy-expiry contract.

  TTL of `0` means "no expiry": the entry lives until explicitly
  deleted via `delete/2` or `flush/1`. Negative TTL is invalid and
  raises `ArgumentError` at the dispatcher (`Cache.put/4`).

  ## Keys and values

  Keys are arbitrary Erlang terms; adapters hash or serialize them
  as needed. Values are also arbitrary terms; the Postgrex adapter
  uses `:erlang.term_to_binary/1` so values round-trip faithfully
  across BEAM nodes.

  ## Configuration

  When wired into a `Policy.Cache`, the configuration carries
  alongside the module:

      Policy.Cache.ets(ttl: :timer.minutes(5))
      # ↓ resolves to ...
      {Raxol.Agent.Cache.Ets, %{table: :raxol_agent_cache}}

      Policy.Cache.postgrex(ttl: :timer.minutes(5), conn: MyApp.Postgrex)
      # ↓ resolves to ...
      {Raxol.Agent.Cache.Postgrex,
       %{conn: MyApp.Postgrex, table: "raxol_agent_cache"}}

  Adapters destructure `{module, config}` and forward `config` to
  every callback. A bare module (no tuple) gets `%{}`.
  """

  @typedoc "Per-call configuration map passed to every callback."
  @type config :: map()

  @typedoc "Cache key; arbitrary term."
  @type key :: term()

  @typedoc "Cache value; arbitrary term."
  @type value :: term()

  @typedoc "Time-to-live in milliseconds. `0` means no expiry."
  @type ttl_ms :: non_neg_integer()

  @doc """
  Return `{:ok, value}` when `key` is present and not expired,
  `:miss` otherwise. Implementations may garbage-collect expired
  entries opportunistically on `get/2`.
  """
  @callback get(config(), key()) :: {:ok, value()} | :miss

  @doc """
  Store `value` under `key` with a TTL in milliseconds.

  A `ttl_ms` of `0` means "no expiry" (entry persists until
  `delete/2` or `flush/1`). Implementations record the absolute
  expiry timestamp at write time so the get-side check is a single
  comparison against `DateTime.utc_now/0`.
  """
  @callback put(config(), key(), value(), ttl_ms()) :: :ok

  @doc """
  Remove the entry for `key`. Idempotent: returns `:ok` even if the
  key was not present.
  """
  @callback delete(config(), key()) :: :ok

  @doc """
  Remove all entries managed by this config. Idempotent.
  """
  @callback flush(config()) :: :ok

  # --- Module-level dispatcher --------------------------------------------

  @doc """
  Normalize the cache opt into `{module, config}` form.

  Accepts a bare module, a `{module, config}` tuple, or `nil`.
  Returns `nil` for `nil` input.
  """
  @spec normalize(module() | {module(), config()} | nil) ::
          {module(), config()} | nil
  def normalize(nil), do: nil

  def normalize({module, config}) when is_atom(module) and is_map(config),
    do: {module, config}

  def normalize(module) when is_atom(module), do: {module, %{}}

  @doc """
  Dispatch `get` to the adapter. Returns `{:ok, value}` or `:miss`.

  Returns `:miss` when the adapter tuple is `nil` (no cache
  configured) so callers can treat "no cache" the same as "cache
  miss" without branching.
  """
  @spec get({module(), config()} | nil, key()) :: {:ok, value()} | :miss
  def get(nil, _key), do: :miss

  def get({module, config}, key) when is_atom(module),
    do: module.get(config, key)

  @doc """
  Dispatch `put` to the adapter.

  Raises `ArgumentError` on negative `ttl_ms`. Returns `:ok` when the
  adapter tuple is `nil` (no-op, no cache configured).
  """
  @spec put({module(), config()} | nil, key(), value(), ttl_ms()) :: :ok
  def put(nil, _key, _value, _ttl_ms), do: :ok

  def put({module, config}, key, value, ttl_ms)
      when is_atom(module) and is_integer(ttl_ms) and ttl_ms >= 0,
      do: module.put(config, key, value, ttl_ms)

  def put(_adapter, _key, _value, ttl_ms) when is_integer(ttl_ms) do
    raise ArgumentError,
          "Cache.put/4 ttl_ms must be a non-negative integer, got: #{ttl_ms}"
  end

  @doc "Dispatch `delete` to the adapter. No-op when adapter is `nil`."
  @spec delete({module(), config()} | nil, key()) :: :ok
  def delete(nil, _key), do: :ok

  def delete({module, config}, key) when is_atom(module),
    do: module.delete(config, key)

  @doc "Dispatch `flush` to the adapter. No-op when adapter is `nil`."
  @spec flush({module(), config()} | nil) :: :ok
  def flush(nil), do: :ok
  def flush({module, config}) when is_atom(module), do: module.flush(config)
end
