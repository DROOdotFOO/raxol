defmodule Raxol.Agent.ThreadLog.Postgrex do
  @moduledoc """
  Postgrex-backed `Raxol.Agent.ThreadLog` adapter.

  Persists events in a PostgreSQL table so agents on separate
  processes or BEAM nodes can share a durable thread log. `payload`
  and `metadata` are stored as `bytea` via
  `:erlang.term_to_binary/1`; `recorded_at` is a real
  `timestamptz`.

  ## Optional dependency

  `Postgrex` is declared `optional: true`. Consumers must add
  `:postgrex` to their own deps and start a connection.

  ## Config

      %{
        conn: MyApp.Postgrex,
        table: "raxol_agent_threads"
      }

  `:table` defaults to `"raxol_agent_threads"`. Table name is
  validated against a safe-identifier regex; config-level injection
  is not possible.

  ## Schema

  Run the SQL returned by `create_table_sql/1` once:

      iex> Raxol.Agent.ThreadLog.Postgrex.create_table_sql()
      \"\"\"
      CREATE TABLE IF NOT EXISTS raxol_agent_threads (
        thread_id   text NOT NULL,
        sequence    bigint NOT NULL,
        kind        text NOT NULL,
        payload     bytea,
        metadata    bytea NOT NULL,
        recorded_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (thread_id, sequence)
      );
      CREATE INDEX IF NOT EXISTS raxol_agent_threads_kind_idx
        ON raxol_agent_threads (thread_id, kind, sequence);
      \"\"\"

  The secondary index on `(thread_id, kind, sequence)` makes
  `list_by_kind/4` an index-only scan.

  ## Sequence allocation

  `append/5` uses `INSERT ... VALUES (..., COALESCE((SELECT MAX(sequence)
  + 1 FROM <table> WHERE thread_id = $1), 0), ...)` inside a single
  statement. This is *racy* between concurrent writers to the same
  `thread_id`: two writers can both read `MAX = N` and both try to
  insert at `N + 1`, producing a `unique_violation` on the second.

  The adapter catches `unique_violation` and retries up to three
  times with a 5ms backoff. Under heavier contention the third
  attempt fails with `{:error, :sequence_conflict}` and the caller
  is expected to serialize through a single owning process. The
  single-writer-per-thread contract is documented on the behaviour.

  ## Lazy expiry, retention, audit

  No automatic expiry. Retention is a consumer responsibility via
  `truncate/3` (cheap, indexed) or a scheduled
  `DELETE FROM <table> WHERE recorded_at < now() - interval 'N days'`.
  """

  @behaviour Raxol.Agent.ThreadLog

  @compile {:no_warn_undefined, Postgrex}

  alias Raxol.Agent.ThreadEvent

  @default_table "raxol_agent_threads"
  @safe_identifier ~r/\A[a-zA-Z_][a-zA-Z0-9_]{0,62}\z/
  @retry_attempts 3
  @retry_backoff_ms 5

  @impl true
  def append(config, thread_id, kind, payload, opts \\ []) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)
    metadata = Keyword.get(opts, :metadata, %{})
    recorded_at = Keyword.get(opts, :recorded_at, DateTime.utc_now())

    payload_bin = :erlang.term_to_binary(payload)
    metadata_bin = :erlang.term_to_binary(metadata)
    kind_str = Atom.to_string(kind)

    do_append(
      conn,
      table,
      thread_id,
      kind,
      kind_str,
      payload,
      payload_bin,
      metadata_bin,
      recorded_at,
      0
    )
  end

  defp do_append(
         _conn,
         _table,
         thread_id,
         _kind_atom,
         _kind_str,
         _payload,
         _payload_bin,
         _metadata_bin,
         _recorded_at,
         attempt
       )
       when attempt >= @retry_attempts do
    {:error, {:sequence_conflict, thread_id}}
  end

  defp do_append(
         conn,
         table,
         thread_id,
         kind_atom,
         kind_str,
         payload,
         payload_bin,
         metadata_bin,
         recorded_at,
         attempt
       ) do
    case Postgrex.query(conn, insert_sql(table), [
           thread_id,
           kind_str,
           payload_bin,
           metadata_bin,
           recorded_at
         ]) do
      {:ok, %{rows: [[sequence]]}} ->
        event =
          ThreadEvent.new(
            thread_id: thread_id,
            sequence: sequence,
            kind: kind_atom,
            payload: payload,
            metadata: :erlang.binary_to_term(metadata_bin),
            recorded_at: recorded_at
          )

        {:ok, event}

      {:error, %{postgres: %{code: :unique_violation}}} ->
        Process.sleep(@retry_backoff_ms * (attempt + 1))

        do_append(
          conn,
          table,
          thread_id,
          kind_atom,
          kind_str,
          payload,
          payload_bin,
          metadata_bin,
          recorded_at,
          attempt + 1
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list(config, thread_id, opts \\ []) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)
    from = Keyword.get(opts, :from, 0)
    to = Keyword.get(opts, :to, :infinity)
    limit = Keyword.get(opts, :limit, 1_000)
    order = Keyword.get(opts, :order, :asc)

    {sql, params} =
      build_list_query(table, thread_id, from, to, limit, order, nil)

    case Postgrex.query(conn, sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_event(&1, thread_id))}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  @impl true
  def list_by_kind(config, thread_id, kind, opts \\ []) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)
    from = Keyword.get(opts, :from, 0)
    to = Keyword.get(opts, :to, :infinity)
    limit = Keyword.get(opts, :limit, 1_000)
    order = Keyword.get(opts, :order, :asc)

    {sql, params} =
      build_list_query(
        table,
        thread_id,
        from,
        to,
        limit,
        order,
        Atom.to_string(kind)
      )

    case Postgrex.query(conn, sql, params) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_event(&1, thread_id))}

      {:error, _reason} ->
        {:ok, []}
    end
  end

  @impl true
  def latest(config, thread_id) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, select_latest_sql(table), [thread_id]) do
      {:ok, %{rows: [row]}} ->
        {:ok, row_to_event(row, thread_id)}

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, _reason} ->
        {:error, :not_found}
    end
  end

  @impl true
  def truncate(config, thread_id, before) do
    ensure_postgrex_loaded!()
    {conn, table} = conn_and_table(config)

    case Postgrex.query(conn, truncate_sql(table), [thread_id, before]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- SQL builders ---------------------------------------------------------

  @doc """
  Returns the `CREATE TABLE IF NOT EXISTS` + secondary index SQL.
  Run once as part of the consumer's migration step.
  """
  @spec create_table_sql(String.t()) :: String.t()
  def create_table_sql(table \\ @default_table) do
    table = quote_identifier!(table)
    index_name = String.slice("#{table}_kind_idx", 0, 63)

    """
    CREATE TABLE IF NOT EXISTS #{table} (
      thread_id   text NOT NULL,
      sequence    bigint NOT NULL,
      kind        text NOT NULL,
      payload     bytea,
      metadata    bytea NOT NULL,
      recorded_at timestamptz NOT NULL DEFAULT now(),
      PRIMARY KEY (thread_id, sequence)
    );
    CREATE INDEX IF NOT EXISTS #{index_name}
      ON #{table} (thread_id, kind, sequence);
    """
  end

  @doc false
  def insert_sql(table) do
    table = quote_identifier!(table)

    """
    INSERT INTO #{table} (thread_id, sequence, kind, payload, metadata, recorded_at)
    VALUES (
      $1,
      COALESCE((SELECT MAX(sequence) + 1 FROM #{table} WHERE thread_id = $1), 0),
      $2, $3, $4, $5
    )
    RETURNING sequence
    """
  end

  @doc false
  def select_latest_sql(table) do
    table = quote_identifier!(table)

    """
    SELECT sequence, kind, payload, metadata, recorded_at
    FROM #{table}
    WHERE thread_id = $1
    ORDER BY sequence DESC
    LIMIT 1
    """
  end

  @doc false
  def truncate_sql(table) do
    table = quote_identifier!(table)
    "DELETE FROM #{table} WHERE thread_id = $1 AND sequence < $2\n"
  end

  # Parametric list query: range-bounds + optional kind filter + order + limit.
  defp build_list_query(table, thread_id, from, to, limit, order, kind_str) do
    table = quote_identifier!(table)
    order_sql = if order == :desc, do: "DESC", else: "ASC"

    {to_clause, params_tail} =
      case to do
        :infinity -> {"", []}
        n when is_integer(n) -> {" AND sequence <= $4", [n]}
      end

    {kind_clause, params_tail2} =
      case kind_str do
        nil ->
          {to_clause, params_tail}

        k ->
          {to_clause <> kind_clause_sql(to), params_tail ++ [k]}
      end

    limit_pos = 3 + length(params_tail2)

    sql =
      """
      SELECT sequence, kind, payload, metadata, recorded_at
      FROM #{table}
      WHERE thread_id = $1
        AND sequence >= $2
      #{kind_clause}
      ORDER BY sequence #{order_sql}
      LIMIT $#{limit_pos}
      """

    params = [thread_id, from] ++ params_tail2 ++ [limit_to_int(limit)]
    {sql, params}
  end

  defp kind_clause_sql(:infinity), do: " AND kind = $4"
  defp kind_clause_sql(_n), do: " AND kind = $5"

  defp limit_to_int(:all), do: 1_000_000
  defp limit_to_int(n) when is_integer(n) and n > 0, do: n

  # --- Helpers --------------------------------------------------------------

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
      Raxol.Agent.ThreadLog.Postgrex requires the :postgrex package.
      Add `{:postgrex, "~> 0.17"}` to your deps and start a Postgrex
      connection before configuring this adapter.
      """
    end
  end

  defp row_to_event(
         [sequence, kind_str, payload_bin, metadata_bin, recorded_at],
         thread_id
       ) do
    ThreadEvent.new(
      thread_id: thread_id,
      sequence: sequence,
      kind: String.to_existing_atom(kind_str),
      payload: maybe_decode(payload_bin),
      metadata: :erlang.binary_to_term(metadata_bin),
      recorded_at: recorded_at
    )
  end

  defp maybe_decode(nil), do: nil
  defp maybe_decode(bin) when is_binary(bin), do: :erlang.binary_to_term(bin)
end
