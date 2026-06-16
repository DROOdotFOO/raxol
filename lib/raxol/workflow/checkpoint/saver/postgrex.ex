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
  migration or `psql`) before the first run. The table has two
  nullable columns — `interrupt_reason` and `paused_at` — populated
  only when the runtime writes a pause checkpoint (ADR-0017). A
  partial index over them keeps `list_paused/2` queries fast even
  when the active-runs table is large.

      iex> Raxol.Workflow.Checkpoint.Saver.Postgrex.create_table_sql()
      \"\"\"
      CREATE TABLE IF NOT EXISTS raxol_workflow_checkpoints (
        thread_id        text NOT NULL,
        step             integer NOT NULL,
        parent_step      integer,
        state            bytea NOT NULL,
        metadata         bytea NOT NULL,
        interrupt_reason text,
        paused_at        timestamptz,
        created_at       timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (thread_id, step)
      );
      CREATE INDEX IF NOT EXISTS raxol_workflow_checkpoints_paused_idx
        ON raxol_workflow_checkpoints (paused_at DESC)
        WHERE interrupt_reason IS NOT NULL;
      \"\"\"

  Pre-ADR-0017 deployments can migrate with:

      ALTER TABLE raxol_workflow_checkpoints
        ADD COLUMN interrupt_reason text,
        ADD COLUMN paused_at        timestamptz;
      CREATE INDEX raxol_workflow_checkpoints_paused_idx
        ON raxol_workflow_checkpoints (paused_at DESC)
        WHERE interrupt_reason IS NOT NULL;

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
  alias Raxol.Workflow.Checkpoint.Saver

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
           :erlang.term_to_binary(metadata),
           interrupt_reason_text(metadata),
           Map.get(metadata || %{}, :paused_at)
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

  @impl true
  def list_paused(config, limit) when is_integer(limit) and limit > 0 do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, select_paused_sql(table), [limit]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_paused_row/1)}

      {:error, reason} ->
        {:error, reason}
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
    # PostgreSQL identifiers cap at 63 chars and are silently truncated
    # beyond that. Truncate explicitly here so the generated DDL stays
    # deterministic across long table names without re-running the
    # 63-char validator (the input table was already validated and
    # the `_paused_idx` suffix is constant).
    index_name = String.slice("#{table}_paused_idx", 0, 63)

    """
    CREATE TABLE IF NOT EXISTS #{table} (
      thread_id        text NOT NULL,
      step             integer NOT NULL,
      parent_step      integer,
      state            bytea NOT NULL,
      metadata         bytea NOT NULL,
      interrupt_reason text,
      paused_at        timestamptz,
      created_at       timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (thread_id, step)
    );
    CREATE INDEX IF NOT EXISTS #{index_name}
      ON #{table} (paused_at DESC)
      WHERE interrupt_reason IS NOT NULL;
    """
  end

  # --- SQL builders (exposed @doc false so tests can pin the shape) ---

  @doc false
  def insert_sql(table) do
    table = quote_identifier!(table)

    """
    INSERT INTO #{table}
      (thread_id, step, parent_step, state, metadata, interrupt_reason, paused_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7)
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

  # Paused-runs query. `DISTINCT ON (thread_id) ... ORDER BY thread_id,
  # step DESC` collapses each thread to its latest checkpoint inside a
  # single atomic scan, so a concurrent resume that just committed a
  # follow-up checkpoint (clearing `interrupt_reason`) is filtered out
  # correctly. The outer `WHERE interrupt_reason IS NOT NULL` plus the
  # partial index keeps the scan O(paused) instead of O(all).
  @doc false
  def select_paused_sql(table) do
    table = quote_identifier!(table)

    """
    SELECT thread_id, step, parent_step, state, metadata, created_at,
           interrupt_reason, paused_at
    FROM (
      SELECT DISTINCT ON (thread_id)
        thread_id, step, parent_step, state, metadata, created_at,
        interrupt_reason, paused_at
      FROM #{table}
      ORDER BY thread_id, step DESC
    ) latest
    WHERE latest.interrupt_reason IS NOT NULL
    ORDER BY latest.paused_at DESC NULLS LAST
    LIMIT $1
    """
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

  # `interrupt_reason` and `paused_at` come back as denormalized
  # columns alongside the canonical bytea metadata; we trust the
  # metadata blob (it survived term_to_binary round-trip) for the
  # paused-row's reason and timestamp so the original Erlang term is
  # preserved rather than the `inspect/1`-text column.
  defp row_to_paused_row([
         thread_id,
         step,
         parent_step,
         state_bin,
         metadata_bin,
         created_at,
         _interrupt_reason_text,
         _paused_at_col
       ]) do
    checkpoint = %Checkpoint{
      thread_id: thread_id,
      step: step,
      parent_step: parent_step,
      state: :erlang.binary_to_term(state_bin),
      metadata: :erlang.binary_to_term(metadata_bin),
      created_at: created_at
    }

    Saver.to_paused_row(checkpoint)
  end

  # The SQL column `interrupt_reason` is text-typed so a partial index
  # can target it directly. The canonical reason term stays in the
  # bytea metadata blob; this is the queryable projection used only for
  # `WHERE interrupt_reason IS NOT NULL` filtering.
  defp interrupt_reason_text(metadata) when is_map(metadata) do
    case Map.get(metadata, :interrupt_reason) do
      nil -> nil
      reason -> inspect(reason)
    end
  end

  defp interrupt_reason_text(_), do: nil
end
