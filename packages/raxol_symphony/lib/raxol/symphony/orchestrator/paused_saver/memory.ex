defmodule Raxol.Symphony.Orchestrator.PausedSaver.Memory do
  @moduledoc """
  Ephemeral in-memory `PausedSaver`. Useful for tests that want to
  exercise the saver hookup without touching disk.

  The table is a named ETS table created lazily on the first call.
  Two orchestrators sharing the same `:table` config share state;
  isolate tests by passing distinct table names.

  ## Config

      %{table: :symphony_paused_test}

  Defaults to `:raxol_symphony_paused`.
  """

  @behaviour Raxol.Symphony.Orchestrator.PausedSaver

  @default_table :raxol_symphony_paused

  @impl true
  def put(config, issue_id, entry) do
    table = ensure_table(config)
    :ets.insert(table, {issue_id, entry})
    :ok
  end

  @impl true
  def delete(config, issue_id) do
    table = ensure_table(config)
    :ets.delete(table, issue_id)
    :ok
  end

  @impl true
  def load_all(config) do
    table = ensure_table(config)
    map = :ets.tab2list(table) |> Map.new()
    {:ok, map}
  end

  @doc "Idempotently create the named ETS table."
  @spec ensure_table(map()) :: atom()
  def ensure_table(config) do
    table = Map.get(config, :table, @default_table)

    case :ets.whereis(table) do
      :undefined ->
        :ets.new(table, [
          :set,
          :public,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      _ref ->
        :ok
    end

    table
  end
end
