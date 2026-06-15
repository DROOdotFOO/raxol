defmodule Raxol.Workflow.Checkpoint.Saver.Postgrex do
  @moduledoc """
  Postgrex-backed `Raxol.Workflow.Checkpoint.Saver` adapter.

  Persists workflow checkpoints in a PostgreSQL table so resumable
  runs survive BEAM restarts and can be shared across nodes. Both
  `state` and `metadata` are stored as `bytea` via
  `:erlang.term_to_binary/1`, preserving arbitrary Erlang terms.

  ## Optional dependency

  `Postgrex` is declared `optional: true` in the umbrella's `mix.exs`.
  Consumers using this saver must add `:postgrex` to their own deps
  and start a Postgrex connection (typically under their own
  supervision tree). The saver does not start or own the connection;
  it expects `:conn` in the configuration to point at a live process.

  ## Config

      %{
        conn: MyApp.Postgrex,       # registered name or pid
        table: "raxol_workflow_checkpoints"  # optional, default below
      }

  `:table` defaults to `"raxol_workflow_checkpoints"`. The table name
  is validated against a safe identifier pattern so config-level
  injection is not possible.

  ## Schema

  Run the SQL returned by `create_table_sql/1` once (e.g. via Ecto
  migration or `psql`) before the first run:

      iex> Raxol.Workflow.Checkpoint.Saver.Postgrex.create_table_sql()
      \"\"\"
      CREATE TABLE IF NOT EXISTS raxol_workflow_checkpoints (
        thread_id   text NOT NULL,
        step        integer NOT NULL,
        parent_step integer,
        state       bytea NOT NULL,
        metadata    bytea NOT NULL,
        created_at  timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (thread_id, step)
      )
      \"\"\"

  ## Append-only contract

  `put/3` is idempotent: a second write to the same `(thread_id, step)`
  pair is a no-op via `ON CONFLICT DO NOTHING`, matching the contract
  documented on `Raxol.Workflow.Checkpoint.Saver`.

  ## Cross-node safety

  Multiple BEAM nodes pointing at the same database can read each
  other's checkpoints. Combined with `Compiled.resume/4`, this means
  a run interrupted on one node can be resumed on another. The
  `ON CONFLICT DO NOTHING` clause prevents racing writers from
  duplicating a step.
  """

  @behaviour Raxol.Workflow.Checkpoint.Saver

  @compile {:no_warn_undefined, Postgrex}

  alias Raxol.Workflow.Checkpoint

  @default_table "raxol_workflow_checkpoints"
  @safe_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/

  @impl true
  def put(config, thread_id, %Checkpoint{
        step: step,
        parent_step: parent_step,
        state: state,
        metadata: metadata
      }) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, insert_sql(table), [
           thread_id,
           step,
           parent_step,
           :erlang.term_to_binary(state),
           :erlang.term_to_binary(metadata)
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get_latest(config, thread_id) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, select_latest_sql(table), [thread_id]) do
      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:ok, %{rows: [row]}} ->
        {:ok, row_to_checkpoint(row, thread_id)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list(config, thread_id, limit) when is_integer(limit) and limit > 0 do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, select_list_sql(table), [thread_id, limit]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_checkpoint(&1, thread_id))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_thread(config, thread_id) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, delete_sql(table), [thread_id]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the `CREATE TABLE IF NOT EXISTS` SQL for the checkpoint
  table. Run once as part of the consumer's migration step.

  Pass a custom `table` name to match the value used in the saver
  config; defaults to `"raxol_workflow_checkpoints"`.
  """
  @spec create_table_sql(String.t()) :: String.t()
  def create_table_sql(table \\ @default_table) do
    table = quote_identifier!(table)

    """
    CREATE TABLE IF NOT EXISTS #{table} (
      thread_id   text NOT NULL,
      step        integer NOT NULL,
      parent_step integer,
      state       bytea NOT NULL,
      metadata    bytea NOT NULL,
      created_at  timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (thread_id, step)
    )
    """
  end

  # --- SQL builders (exposed @doc false so tests can pin the shape) ---

  @doc false
  def insert_sql(table) do
    table = quote_identifier!(table)

    """
    INSERT INTO #{table} (thread_id, step, parent_step, state, metadata)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (thread_id, step) DO NOTHING
    """
  end

  @doc false
  def select_latest_sql(table) do
    table = quote_identifier!(table)

    """
    SELECT step, parent_step, state, metadata, created_at
    FROM #{table}
    WHERE thread_id = $1
    ORDER BY step DESC
    LIMIT 1
    """
  end

  @doc false
  def select_list_sql(table) do
    table = quote_identifier!(table)

    """
    SELECT step, parent_step, state, metadata, created_at
    FROM #{table}
    WHERE thread_id = $1
    ORDER BY step DESC
    LIMIT $2
    """
  end

  @doc false
  def delete_sql(table) do
    table = quote_identifier!(table)

    "DELETE FROM #{table} WHERE thread_id = $1\n"
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
      Raxol.Workflow.Checkpoint.Saver.Postgrex requires the :postgrex
      package. Add `{:postgrex, "~> 0.17"}` to your deps and start a
      Postgrex connection before configuring this saver.
      """
    end
  end

  defp row_to_checkpoint(
         [step, parent_step, state_bin, metadata_bin, created_at],
         thread_id
       ) do
    %Checkpoint{
      thread_id: thread_id,
      step: step,
      parent_step: parent_step,
      state: :erlang.binary_to_term(state_bin),
      metadata: :erlang.binary_to_term(metadata_bin),
      created_at: created_at
    }
  end
end
