defmodule Raxol.Agent.Cache.Postgrex do
  @moduledoc """
  Postgrex-backed `Raxol.Agent.Cache` adapter.

  Persists cache entries in a PostgreSQL table so agents on
  separate processes (or separate BEAM nodes) can share cache
  state. Values are stored as `bytea` via
  `:erlang.term_to_binary/1`, preserving arbitrary Erlang terms.

  ## Optional dependency

  `Postgrex` is declared `optional: true` in the umbrella's
  `mix.exs`. Consumers using this adapter must add `:postgrex` to
  their own deps and start a Postgrex connection (typically under
  their own supervision tree). The adapter does not start or own
  the connection; it expects `:conn` in the configuration to point
  at a live process.

  ## Config

      %{
        conn: MyApp.Postgrex,                # registered name or pid
        table: "raxol_agent_cache"           # optional, default below
      }

  `:table` defaults to `"raxol_agent_cache"`. The table name is
  validated against a safe identifier pattern so config-level
  injection is not possible.

  ## Schema

  Run the SQL returned by `create_table_sql/1` once (e.g. via Ecto
  migration or `psql`) before the first call:

      iex> Raxol.Agent.Cache.Postgrex.create_table_sql()
      \"\"\"
      CREATE TABLE IF NOT EXISTS raxol_agent_cache (
        key        bytea NOT NULL,
        value      bytea NOT NULL,
        expires_at timestamptz,
        PRIMARY KEY (key)
      );
      CREATE INDEX IF NOT EXISTS raxol_agent_cache_expires_at_idx
        ON raxol_agent_cache (expires_at)
        WHERE expires_at IS NOT NULL;
      \"\"\"

  `expires_at` is nullable: rows with `NULL` never expire (matches
  the `ttl_ms == 0` contract). The partial index makes the
  occasional eager-sweep query (`DELETE WHERE expires_at <= now()`)
  cheap; this adapter does not run that sweep automatically, but a
  consumer's supervised periodic job can.

  ## Upsert semantics

  `put/4` uses `ON CONFLICT (key) DO UPDATE` so a second write to
  the same key replaces the previous value and expiry. Last-write-
  wins is the documented cache semantic; the append-only contract
  of `Raxol.Workflow.Checkpoint.Saver` does not apply here.

  ## Lazy expiry

  `get/2` filters with `WHERE key = $1 AND (expires_at IS NULL OR
  expires_at > now())` — a stale row stays in the table but is
  invisible to `get/2`. The caller can periodically delete expired
  rows via `DELETE FROM <table> WHERE expires_at <= now()` for
  retention; the partial index keeps that cheap.
  """

  @behaviour Raxol.Agent.Cache

  @compile {:no_warn_undefined, Postgrex}

  @default_table "raxol_agent_cache"
  @safe_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/

  @impl true
  def get(config, key) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, select_sql(table), [:erlang.term_to_binary(key)]) do
      {:ok, %{rows: []}} ->
        :miss

      {:ok, %{rows: [[value_bin]]}} ->
        {:ok, :erlang.binary_to_term(value_bin)}

      {:error, _reason} ->
        :miss
    end
  end

  @impl true
  def put(config, key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms >= 0 do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    expires_at =
      case ttl_ms do
        0 -> nil
        ms -> DateTime.add(DateTime.utc_now(), ms, :millisecond)
      end

    _ =
      Postgrex.query(conn, upsert_sql(table), [
        :erlang.term_to_binary(key),
        :erlang.term_to_binary(value),
        expires_at
      ])

    :ok
  end

  @impl true
  def delete(config, key) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    _ =
      Postgrex.query(conn, delete_sql(table), [
        :erlang.term_to_binary(key)
      ])

    :ok
  end

  @impl true
  def flush(config) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    _ = Postgrex.query(conn, flush_sql(table), [])
    :ok
  end

  # --- SQL builders (exposed @doc false so tests can pin the shape) ---

  @doc """
  Returns the `CREATE TABLE IF NOT EXISTS` + partial-index SQL for
  the cache table. Run once as part of the consumer's migration step.

  Pass a custom `table` name to match the value used in the cache
  config; defaults to `"raxol_agent_cache"`.
  """
  @spec create_table_sql(String.t()) :: String.t()
  def create_table_sql(table \\ @default_table) do
    table = quote_identifier!(table)
    index_name = String.slice("#{table}_expires_at_idx", 0, 63)

    """
    CREATE TABLE IF NOT EXISTS #{table} (
      key        bytea NOT NULL,
      value      bytea NOT NULL,
      expires_at timestamptz,
      PRIMARY KEY (key)
    );
    CREATE INDEX IF NOT EXISTS #{index_name}
      ON #{table} (expires_at)
      WHERE expires_at IS NOT NULL;
    """
  end

  @doc false
  def select_sql(table) do
    table = quote_identifier!(table)

    """
    SELECT value
    FROM #{table}
    WHERE key = $1
      AND (expires_at IS NULL OR expires_at > now())
    """
  end

  @doc false
  def upsert_sql(table) do
    table = quote_identifier!(table)

    """
    INSERT INTO #{table} (key, value, expires_at)
    VALUES ($1, $2, $3)
    ON CONFLICT (key) DO UPDATE
      SET value = EXCLUDED.value,
          expires_at = EXCLUDED.expires_at
    """
  end

  @doc false
  def delete_sql(table) do
    table = quote_identifier!(table)
    "DELETE FROM #{table} WHERE key = $1\n"
  end

  @doc false
  def flush_sql(table) do
    table = quote_identifier!(table)
    "DELETE FROM #{table}\n"
  end

  # --- Helpers ---

  defp conn_and_table(config) do
    conn = Map.fetch!(config, :conn)
    table = Map.get(config, :table, @default_table)
    {conn, table}
  end

  defp quote_identifier!(name) when is_binary(name) do
    if Regex.match?(@safe_identifier, name) do
      name
    else
      raise ArgumentError,
            "unsafe table name #{inspect(name)}; identifiers must match #{inspect(@safe_identifier)}"
    end
  end

  defp ensure_postgrex_loaded! do
    unless Code.ensure_loaded?(Postgrex) do
      raise """
      Raxol.Agent.Cache.Postgrex requires the :postgrex package. Add
      `{:postgrex, "~> 0.17"}` to your deps and start a Postgrex
      connection before configuring this adapter.
      """
    end
  end
end
