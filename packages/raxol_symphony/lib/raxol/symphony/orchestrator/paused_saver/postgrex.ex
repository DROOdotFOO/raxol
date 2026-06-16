defmodule Raxol.Symphony.Orchestrator.PausedSaver.Postgrex do
  @moduledoc """
  Postgrex-backed `PausedSaver` for multi-node Symphony deployments.

  Persists each paused-run entry to a PostgreSQL row so paused runs
  survive BEAM restart AND can be inspected / resumed from any node
  that shares the same database.

  ## Optional dependency

  `Postgrex` is declared `optional: true` in `mix.exs`. Consumers using
  this saver must add `:postgrex` to their own deps and start a
  Postgrex connection (typically under their supervision tree). The
  saver does not own the connection -- it expects `:conn` in the
  configuration to point at a live process.

  ## Config

      %{
        conn: MyApp.Postgrex,            # registered name or pid
        table: "symphony_paused_runs"    # optional; default below
      }

  `:table` defaults to `"symphony_paused_runs"`. The table name is
  validated against a safe identifier pattern so config-level
  injection is not possible.

  ## Schema

  Run the SQL returned by `create_table_sql/1` once (e.g. via Ecto
  migration or `psql`) before the first paused run:

      iex> Raxol.Symphony.Orchestrator.PausedSaver.Postgrex.create_table_sql()
      \"\"\"
      CREATE TABLE IF NOT EXISTS symphony_paused_runs (
        issue_id     text PRIMARY KEY,
        entry        bytea NOT NULL,
        persisted_at timestamptz NOT NULL DEFAULT now()
      );
      \"\"\"

  ## Overwrite semantics

  Unlike the Workflow checkpoint Saver (append-only by `(thread_id, step)`),
  this saver stores the CURRENT paused-entry state, keyed by
  `issue_id`. Each `put/3` overwrites: a paused run that gets parked,
  resumed, and parked again writes three times to the same row. The
  semantic matches the orchestrator's `state.paused` map exactly --
  one row per currently-paused issue.

  ## Cross-node safety

  Multiple BEAM nodes pointing at the same database can read each
  other's paused entries. Combined with the orchestrator hydrating
  from the saver on init, this means a paused run created on one
  node can be resumed by an orchestrator on another after a deploy.
  """

  @behaviour Raxol.Symphony.Orchestrator.PausedSaver

  @compile {:no_warn_undefined, Postgrex}

  @default_table "symphony_paused_runs"
  @safe_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/

  @impl true
  def put(config, issue_id, entry) when is_binary(issue_id) and is_map(entry) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, upsert_sql(table), [
           issue_id,
           :erlang.term_to_binary(entry)
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(config, issue_id) when is_binary(issue_id) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, delete_sql(table), [issue_id]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def load_all(config) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, select_all_sql(table), []) do
      {:ok, %{rows: rows}} ->
        map =
          Enum.reduce(rows, %{}, fn [issue_id, entry_bin], acc ->
            Map.put(acc, issue_id, :erlang.binary_to_term(entry_bin))
          end)

        {:ok, map}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Returns the `CREATE TABLE IF NOT EXISTS` SQL for the paused-runs
  table. Run once as part of the consumer's migration step.

  Pass a custom `table` name to match the value used in the saver
  config; defaults to `"symphony_paused_runs"`.
  """
  @spec create_table_sql(String.t()) :: String.t()
  def create_table_sql(table \\ @default_table) do
    table = quote_identifier!(table)

    """
    CREATE TABLE IF NOT EXISTS #{table} (
      issue_id     text PRIMARY KEY,
      entry        bytea NOT NULL,
      persisted_at timestamptz NOT NULL DEFAULT now()
    );
    """
  end

  # --- SQL builders (exposed @doc false so tests can pin the shape) ---

  @doc false
  def upsert_sql(table) do
    table = quote_identifier!(table)

    """
    INSERT INTO #{table} (issue_id, entry)
    VALUES ($1, $2)
    ON CONFLICT (issue_id) DO UPDATE
      SET entry = EXCLUDED.entry,
          persisted_at = now()
    """
  end

  @doc false
  def delete_sql(table) do
    table = quote_identifier!(table)
    "DELETE FROM #{table} WHERE issue_id = $1\n"
  end

  @doc false
  def select_all_sql(table) do
    table = quote_identifier!(table)
    "SELECT issue_id, entry FROM #{table}\n"
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
      Raxol.Symphony.Orchestrator.PausedSaver.Postgrex requires the
      :postgrex package. Add `{:postgrex, "~> 0.17"}` to your deps and
      start a Postgrex connection before configuring this saver.
      """
    end
  end
end
