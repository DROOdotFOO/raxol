defmodule Raxol.Agent.Policy.Cache do
  @moduledoc """
  Cache policy: short-circuit an operation when its `:key_fn`
  matches a cached value in the configured `Raxol.Agent.Cache`
  adapter.

  Implementation: `Raxol.Agent.PolicyApplier` calls `key_fn.(params)`
  to compute the cache key. On hit (`{:ok, value}`), the wrapped
  operation does not run and the cached value is returned. On miss,
  the operation runs; on `{:ok, value}` the value is stored under
  the key with `:ttl_ms` and the result is returned. Errors are
  surfaced verbatim without caching.

  ## Fields

  - `storage` -- `{module, config}` tuple resolved at construction
    by the `.ets/1` and `.postgrex/1` helpers
  - `ttl_ms` -- TTL in milliseconds; `0` means no expiry; must be
    `>= 0`
  - `key_fn` -- `(params -> term())` that derives the cache key
    from the operation's input

  ## Constructors

      Policy.Cache.ets(ttl_ms: 300_000, key_fn: &(&1.user_id))
      Policy.Cache.ets(ttl_ms: 60_000, key_fn: &(&1.id), table: :my_cache)
      Policy.Cache.postgrex(ttl_ms: 60_000, key_fn: &(&1.id), conn: MyApp.Postgrex)

  Bring-your-own adapter: pass `:storage` directly to the struct
  constructor for an adapter outside the two shipped defaults.
  """

  @type t :: %__MODULE__{
          storage: {module(), map()},
          ttl_ms: non_neg_integer(),
          key_fn: (term() -> term())
        }

  @enforce_keys [:storage, :ttl_ms, :key_fn]
  defstruct [:storage, :ttl_ms, :key_fn]

  @doc """
  Construct a Cache policy backed by the Ets adapter. Required:
  `:ttl_ms`, `:key_fn`. Optional: `:table` (defaults to the Ets
  adapter's `:raxol_agent_cache`).
  """
  @spec ets(keyword()) :: t()
  def ets(opts) do
    %__MODULE__{
      storage: {Raxol.Agent.Cache.Ets, ets_config(opts)},
      ttl_ms: fetch_non_neg!(opts, :ttl_ms),
      key_fn: fetch_fun!(opts, :key_fn)
    }
  end

  @doc """
  Construct a Cache policy backed by the Postgrex adapter. Required:
  `:ttl_ms`, `:key_fn`, `:conn`. Optional: `:table`.
  """
  @spec postgrex(keyword()) :: t()
  def postgrex(opts) do
    %__MODULE__{
      storage: {Raxol.Agent.Cache.Postgrex, postgrex_config(opts)},
      ttl_ms: fetch_non_neg!(opts, :ttl_ms),
      key_fn: fetch_fun!(opts, :key_fn)
    }
  end

  defp ets_config(opts) do
    case Keyword.fetch(opts, :table) do
      {:ok, table} -> %{table: table}
      :error -> %{}
    end
  end

  defp postgrex_config(opts) do
    conn = Keyword.fetch!(opts, :conn)
    table = Keyword.get(opts, :table)
    base = %{conn: conn}
    if table, do: Map.put(base, :table, table), else: base
  end

  defp fetch_non_neg!(opts, key) do
    case Keyword.fetch!(opts, key) do
      n when is_integer(n) and n >= 0 ->
        n

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a non-negative integer, got: #{inspect(other)}"
    end
  end

  defp fetch_fun!(opts, key) do
    case Keyword.fetch!(opts, key) do
      fun when is_function(fun, 1) ->
        fun

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a 1-arity function, got: #{inspect(other)}"
    end
  end
end
