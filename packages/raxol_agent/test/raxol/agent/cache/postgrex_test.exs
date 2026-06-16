defmodule Raxol.Agent.Cache.PostgrexTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Cache.Postgrex, as: Adapter

  describe "create_table_sql/1" do
    test "produces the canonical schema for the default table" do
      sql = Adapter.create_table_sql()

      assert sql =~ "CREATE TABLE IF NOT EXISTS raxol_agent_cache"
      assert sql =~ ~r/key\s+bytea NOT NULL/
      assert sql =~ ~r/value\s+bytea NOT NULL/
      assert sql =~ ~r/expires_at timestamptz/
      assert sql =~ "PRIMARY KEY (key)"

      assert sql =~
               "CREATE INDEX IF NOT EXISTS raxol_agent_cache_expires_at_idx"

      assert sql =~ "WHERE expires_at IS NOT NULL"
    end

    test "honors a custom table name" do
      sql = Adapter.create_table_sql("my_cache")
      assert sql =~ "CREATE TABLE IF NOT EXISTS my_cache"
      assert sql =~ "my_cache_expires_at_idx"
    end

    test "rejects unsafe identifiers" do
      for bad <- ["foo; DROP TABLE x", "1bad", "a-b", "x'y", "with space", ""] do
        assert_raise ArgumentError, ~r/unsafe table name/, fn ->
          Adapter.create_table_sql(bad)
        end
      end
    end
  end

  describe "select_sql/1" do
    test "filters by key and expiry" do
      sql = Adapter.select_sql("raxol_agent_cache")
      assert sql =~ "SELECT value"
      assert sql =~ "FROM raxol_agent_cache"
      assert sql =~ "WHERE key = $1"
      assert sql =~ "expires_at IS NULL OR expires_at > now()"
    end
  end

  describe "upsert_sql/1" do
    test "uses ON CONFLICT to overwrite existing keys" do
      sql = Adapter.upsert_sql("raxol_agent_cache")
      assert sql =~ "INSERT INTO raxol_agent_cache"
      assert sql =~ "(key, value, expires_at)"
      assert sql =~ "VALUES ($1, $2, $3)"
      assert sql =~ "ON CONFLICT (key) DO UPDATE"
      assert sql =~ "SET value = EXCLUDED.value"
      assert sql =~ "expires_at = EXCLUDED.expires_at"
    end
  end

  describe "delete_sql/1 + flush_sql/1" do
    test "delete narrows by key" do
      sql = Adapter.delete_sql("raxol_agent_cache")
      assert sql =~ "DELETE FROM raxol_agent_cache"
      assert sql =~ "WHERE key = $1"
    end

    test "flush is unscoped" do
      sql = Adapter.flush_sql("raxol_agent_cache")
      assert sql =~ "DELETE FROM raxol_agent_cache"
      refute sql =~ "WHERE"
    end
  end

  describe "table name validation" do
    test "all SQL-building functions reject unsafe identifiers" do
      bad = "foo; DROP TABLE"

      for fun <- [
            &Adapter.select_sql/1,
            &Adapter.upsert_sql/1,
            &Adapter.delete_sql/1,
            &Adapter.flush_sql/1
          ] do
        assert_raise ArgumentError, ~r/unsafe table name/, fn -> fun.(bad) end
      end
    end
  end

  # --- Live Postgres tests ---------------------------------------------------
  # Same pattern as Raxol.Workflow.Checkpoint.Saver.PostgrexTest: gated on
  # RAXOL_AGENT_PG_URL or POSTGRES_* env vars; tagged :integration so the
  # default `mix test --exclude integration` skips them.

  @moduletag :integration

  defp pg_conn_opts do
    case System.get_env("RAXOL_AGENT_PG_URL") do
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

  defp start_conn! do
    case pg_conn_opts() do
      nil ->
        flunk(
          "Postgres connection not configured; set RAXOL_AGENT_PG_URL or POSTGRES_HOST + POSTGRES_DB"
        )

      opts ->
        start_supervised!({Postgrex, opts})
    end
  end

  defp unique_table do
    "raxol_agent_cache_test_#{:erlang.unique_integer([:positive])}"
  end

  describe "live Postgres roundtrip" do
    test "put + get returns the same value" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Adapter.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      assert :ok = Adapter.put(config, :alpha, %{n: 1}, 60_000)
      assert {:ok, %{n: 1}} = Adapter.get(config, :alpha)
    end

    test "ttl_ms = 0 means no expiry (null expires_at)" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Adapter.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      :ok = Adapter.put(config, :forever, :v, 0)
      assert {:ok, :v} = Adapter.get(config, :forever)
    end

    test "ON CONFLICT replaces the previous value" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Adapter.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      :ok = Adapter.put(config, :k, :first, 60_000)
      :ok = Adapter.put(config, :k, :second, 60_000)

      assert {:ok, :second} = Adapter.get(config, :k)
    end

    test "expired row is invisible to get/2 (lazy expiry)" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Adapter.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      :ok = Adapter.put(config, :short, :v, 50)
      Process.sleep(100)

      assert :miss = Adapter.get(config, :short)
    end

    test "delete + flush" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Adapter.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      :ok = Adapter.put(config, :a, 1, 60_000)
      :ok = Adapter.put(config, :b, 2, 60_000)

      :ok = Adapter.delete(config, :a)
      assert :miss = Adapter.get(config, :a)
      assert {:ok, 2} = Adapter.get(config, :b)

      :ok = Adapter.flush(config)
      assert :miss = Adapter.get(config, :b)
    end
  end
end
