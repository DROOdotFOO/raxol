defmodule Raxol.Workflow.Checkpoint.Saver.PostgrexTest do
  use ExUnit.Case, async: true

  alias Raxol.Workflow.Checkpoint.Saver.Postgrex, as: Saver

  describe "create_table_sql/1" do
    test "produces the canonical schema for the default table" do
      sql = Saver.create_table_sql()
      assert sql =~ "CREATE TABLE IF NOT EXISTS raxol_workflow_checkpoints"
      assert sql =~ ~r/thread_id\s+text NOT NULL/
      assert sql =~ ~r/step\s+integer NOT NULL/
      assert sql =~ ~r/parent_step\s+integer/
      assert sql =~ ~r/state\s+bytea NOT NULL/
      assert sql =~ ~r/metadata\s+bytea NOT NULL/
      assert sql =~ ~r/interrupt_reason text/
      assert sql =~ ~r/paused_at\s+timestamptz/
      assert sql =~ ~r/created_at\s+timestamptz NOT NULL DEFAULT now\(\)/
      assert sql =~ "PRIMARY KEY (thread_id, step)"

      assert sql =~
               "CREATE INDEX IF NOT EXISTS raxol_workflow_checkpoints_paused_idx"

      assert sql =~ "WHERE interrupt_reason IS NOT NULL"
    end

    test "honors a custom table name" do
      sql = Saver.create_table_sql("my_app_checkpoints")
      assert sql =~ "CREATE TABLE IF NOT EXISTS my_app_checkpoints"
    end

    test "rejects unsafe identifiers" do
      for bad <- ["foo; DROP TABLE x", "1bad", "a-b", "x'y", "with space", ""] do
        assert_raise ArgumentError, ~r/unsafe table name/, fn ->
          Saver.create_table_sql(bad)
        end
      end
    end

    test "accepts standard pgsql identifier shapes" do
      for ok <- [
            "foo",
            "_foo",
            "foo_bar_baz",
            "ABC123",
            "x" <> String.duplicate("y", 62)
          ] do
        assert is_binary(Saver.create_table_sql(ok))
      end
    end
  end

  describe "insert_sql/1" do
    test "uses ON CONFLICT DO NOTHING for the append-only contract" do
      sql = Saver.insert_sql("raxol_workflow_checkpoints")
      assert sql =~ "INSERT INTO raxol_workflow_checkpoints"

      assert sql =~
               "(thread_id, step, parent_step, state, metadata, interrupt_reason, paused_at)"

      assert sql =~ "VALUES ($1, $2, $3, $4, $5, $6, $7)"
      assert sql =~ "ON CONFLICT (thread_id, step) DO NOTHING"
    end
  end

  describe "select_paused_sql/1" do
    test "filters to threads whose latest checkpoint carries an interrupt_reason" do
      sql = Saver.select_paused_sql("checkpoints")
      # DISTINCT ON picks one row per thread (the highest step); the
      # outer filter excludes threads whose latest checkpoint has no
      # interrupt_reason, which is how resumes implicitly remove a
      # thread from the result set.
      assert sql =~ "DISTINCT ON (thread_id)"
      assert sql =~ "ORDER BY thread_id, step DESC"
      assert sql =~ "WHERE latest.interrupt_reason IS NOT NULL"
      assert sql =~ "ORDER BY latest.paused_at DESC NULLS LAST"
      assert sql =~ "LIMIT $1"
    end
  end

  describe "select_latest_sql/1" do
    test "selects in descending step order with LIMIT 1" do
      sql = Saver.select_latest_sql("checkpoints")
      assert sql =~ "SELECT step, parent_step, state, metadata, created_at"
      assert sql =~ "FROM checkpoints"
      assert sql =~ "WHERE thread_id = $1"
      assert sql =~ "ORDER BY step DESC"
      assert sql =~ "LIMIT 1"
    end
  end

  describe "select_list_sql/1" do
    test "parameterizes the limit so it cannot be injected" do
      sql = Saver.select_list_sql("checkpoints")
      assert sql =~ "WHERE thread_id = $1"
      assert sql =~ "ORDER BY step DESC"
      assert sql =~ "LIMIT $2"
    end
  end

  describe "delete_sql/1" do
    test "deletes by thread_id only" do
      sql = Saver.delete_sql("checkpoints")
      assert sql =~ "DELETE FROM checkpoints"
      assert sql =~ "WHERE thread_id = $1"
    end
  end

  describe "table name validation" do
    test "all SQL-building functions reject unsafe identifiers" do
      bad = "foo; DROP TABLE"

      assert_raise ArgumentError, ~r/unsafe table name/, fn ->
        Saver.insert_sql(bad)
      end

      assert_raise ArgumentError, ~r/unsafe table name/, fn ->
        Saver.select_latest_sql(bad)
      end

      assert_raise ArgumentError, ~r/unsafe table name/, fn ->
        Saver.select_list_sql(bad)
      end

      assert_raise ArgumentError, ~r/unsafe table name/, fn ->
        Saver.delete_sql(bad)
      end
    end
  end

  # --- Integration tests against a real Postgres database ---
  # Tagged :integration so they skip by default per the project's
  # test_helper.exs (and CI excludes :integration). To run them
  # locally, point RAXOL_WORKFLOW_PG_URL at a writable database:
  #
  #   RAXOL_WORKFLOW_PG_URL=postgres://localhost/raxol_workflow_test \
  #     mix test --only integration test/raxol/workflow/checkpoint/saver/postgrex_test.exs

  @moduletag :integration

  alias Raxol.Workflow.Checkpoint

  # Reads RAXOL_WORKFLOW_PG_URL first, then falls back to the
  # POSTGRES_* discrete env vars (the shape CI sets up).
  defp pg_conn_opts do
    case System.get_env("RAXOL_WORKFLOW_PG_URL") do
      nil -> postgres_env_opts()
      url -> parse_uri(url)
    end
  end

  defp postgres_env_opts do
    host = System.get_env("POSTGRES_HOST")
    db = System.get_env("POSTGRES_DB")

    if host && db do
      [
        hostname: host,
        port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
        username: System.get_env("POSTGRES_USER") || "postgres",
        password: System.get_env("POSTGRES_PASSWORD") || "postgres",
        database: db
      ]
    else
      nil
    end
  end

  defp start_conn! do
    case pg_conn_opts() do
      nil ->
        flunk(
          "Postgres connection not configured; set RAXOL_WORKFLOW_PG_URL or POSTGRES_HOST + POSTGRES_DB"
        )

      opts ->
        # start_supervised so the connection is cleaned up at the end
        # of each test without the test process needing to manage it.
        # Tables use unique names per test for isolation, so DROP TABLE
        # cleanup is not necessary.
        start_supervised!({Postgrex, opts})
    end
  end

  defp parse_uri(url) do
    %URI{userinfo: userinfo, host: host, port: port, path: path} =
      URI.parse(url)

    {username, password} =
      case (userinfo || "") |> String.split(":", parts: 2) do
        [u, p] -> {u, p}
        [u] -> {u, nil}
        _ -> {nil, nil}
      end

    [
      hostname: host || "localhost",
      port: port || 5432,
      username: username,
      password: password,
      database: String.trim_leading(path || "/", "/")
    ]
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
  end

  defp unique_table do
    "raxol_workflow_test_#{:erlang.unique_integer([:positive])}"
  end

  describe "live Postgres roundtrip" do
    test "put + get_latest returns the same checkpoint" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      ckpt =
        Checkpoint.new(
          thread_id: "thread-1",
          step: 0,
          state: %{key: :value, list: [1, 2, 3]},
          parent_step: nil,
          metadata: %{node_id: :__start__, run_id: "thread-1"}
        )

      assert :ok = Saver.put(config, "thread-1", ckpt)
      assert {:ok, got} = Saver.get_latest(config, "thread-1")
      assert got.state == ckpt.state
      assert got.metadata == ckpt.metadata
      assert got.parent_step == nil
    end

    test "ON CONFLICT makes put/3 idempotent" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      ckpt =
        Checkpoint.new(
          thread_id: "t",
          step: 0,
          state: %{n: 1},
          metadata: %{}
        )

      assert :ok = Saver.put(config, "t", ckpt)
      # Second write is a no-op
      assert :ok = Saver.put(config, "t", %{ckpt | state: %{n: 999}})

      {:ok, got} = Saver.get_latest(config, "t")
      # First writer wins
      assert got.state == %{n: 1}
    end

    test "list/3 returns checkpoints newest-first up to limit" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      for step <- 0..5 do
        ckpt =
          Checkpoint.new(
            thread_id: "list-thread",
            step: step,
            state: %{step: step},
            parent_step: if(step == 0, do: nil, else: step - 1),
            metadata: %{node_id: :"node_#{step}"}
          )

        :ok = Saver.put(config, "list-thread", ckpt)
      end

      {:ok, all} = Saver.list(config, "list-thread", 10)
      assert length(all) == 6
      assert Enum.map(all, & &1.step) == [5, 4, 3, 2, 1, 0]

      {:ok, limited} = Saver.list(config, "list-thread", 3)
      assert length(limited) == 3
      assert Enum.map(limited, & &1.step) == [5, 4, 3]
    end

    test "delete_thread/2 removes all checkpoints for the thread" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      for step <- 0..2 do
        :ok =
          Saver.put(
            config,
            "del",
            Checkpoint.new(
              thread_id: "del",
              step: step,
              state: %{},
              metadata: %{}
            )
          )
      end

      assert :ok = Saver.delete_thread(config, "del")
      assert {:error, :not_found} = Saver.get_latest(config, "del")
      assert {:ok, []} = Saver.list(config, "del", 10)
    end

    test "two threads in the same table do not see each other's checkpoints" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      Saver.put(
        config,
        "a",
        Checkpoint.new(
          thread_id: "a",
          step: 0,
          state: %{from: :a},
          metadata: %{}
        )
      )

      Saver.put(
        config,
        "b",
        Checkpoint.new(
          thread_id: "b",
          step: 0,
          state: %{from: :b},
          metadata: %{}
        )
      )

      {:ok, ga} = Saver.get_latest(config, "a")
      {:ok, gb} = Saver.get_latest(config, "b")
      assert ga.state == %{from: :a}
      assert gb.state == %{from: :b}
    end
  end
end
