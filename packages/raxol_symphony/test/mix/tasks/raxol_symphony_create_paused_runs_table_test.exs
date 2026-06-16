defmodule Mix.Tasks.RaxolSymphony.CreatePausedRunsTableTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Mix.Tasks.RaxolSymphony.CreatePausedRunsTable

  setup do
    Mix.shell(Mix.Shell.IO)
    :ok
  end

  describe "run/1" do
    test "with no args prints the canonical DDL" do
      sql =
        capture_io(fn ->
          CreatePausedRunsTable.run([])
        end)

      assert sql =~ "CREATE TABLE IF NOT EXISTS symphony_paused_runs"
      assert sql =~ "issue_id"
      assert sql =~ "entry"
      assert sql =~ "persisted_at"
    end

    test "--table NAME emits the custom table name" do
      sql =
        capture_io(fn ->
          CreatePausedRunsTable.run(["--table", "my_paused_runs"])
        end)

      assert sql =~ "CREATE TABLE IF NOT EXISTS my_paused_runs"
      refute sql =~ "symphony_paused_runs"
    end

    test "unsafe table names raise" do
      assert_raise ArgumentError, ~r/unsafe table name/, fn ->
        capture_io(fn ->
          CreatePausedRunsTable.run(["--table", "foo; DROP TABLE bar"])
        end)
      end
    end
  end
end
