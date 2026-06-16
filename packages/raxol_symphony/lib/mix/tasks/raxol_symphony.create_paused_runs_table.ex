defmodule Mix.Tasks.RaxolSymphony.CreatePausedRunsTable do
  @shortdoc "Print the Postgres DDL for the symphony_paused_runs table"

  @moduledoc """
  Prints the `CREATE TABLE IF NOT EXISTS` SQL for the paused-runs
  table used by `Raxol.Symphony.Orchestrator.PausedSaver.Postgrex`.

  ## Usage

      mix raxol_symphony.create_paused_runs_table
      mix raxol_symphony.create_paused_runs_table --table my_paused_runs

  Pipe straight into `psql` to apply the migration:

      mix raxol_symphony.create_paused_runs_table | psql -d my_db

  ## Why a separate task

  Consumers configuring the Postgrex saver typically own their own
  migration tooling (Ecto.Migration, sqitch, dbmate, etc.) and run
  DDL through that pipeline. This task is a thin wrapper around
  `Raxol.Symphony.Orchestrator.PausedSaver.Postgrex.create_table_sql/1`
  so the canonical SQL doesn't have to be hand-copied from
  module docs.

  ## Options

    * `--table NAME` -- custom table name (default
      `symphony_paused_runs`). The name is validated against a safe
      identifier pattern; invalid input raises `ArgumentError`.
  """

  use Mix.Task

  alias Raxol.Symphony.Orchestrator.PausedSaver.Postgrex, as: Saver

  @impl Mix.Task
  def run(argv) do
    {opts, _, _} = OptionParser.parse(argv, strict: [table: :string])

    sql =
      case Keyword.get(opts, :table) do
        nil -> Saver.create_table_sql()
        table when is_binary(table) -> Saver.create_table_sql(table)
      end

    Mix.shell().info(sql)
  end
end
