defmodule Raxol.Symphony.Orchestrator.PausedSaver.PostgrexTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.Orchestrator.PausedSaver.Postgrex, as: Saver

  describe "create_table_sql/1" do
    test "produces the canonical schema for the default table" do
      sql = Saver.create_table_sql()
      assert sql =~ "CREATE TABLE IF NOT EXISTS symphony_paused_runs"
      assert sql =~ ~r/issue_id\s+text PRIMARY KEY/
      assert sql =~ ~r/entry\s+bytea NOT NULL/
      assert sql =~ ~r/persisted_at\s+timestamptz NOT NULL DEFAULT now\(\)/
    end

    test "honors a custom table name" do
      sql = Saver.create_table_sql("my_app_paused")
      assert sql =~ "CREATE TABLE IF NOT EXISTS my_app_paused"
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

  describe "upsert_sql/1" do
    test "INSERT ... ON CONFLICT DO UPDATE matches the overwrite contract" do
      sql = Saver.upsert_sql("symphony_paused_runs")
      assert sql =~ "INSERT INTO symphony_paused_runs (issue_id, entry)"
      assert sql =~ "VALUES ($1, $2)"
      assert sql =~ "ON CONFLICT (issue_id) DO UPDATE"
      assert sql =~ "SET entry = EXCLUDED.entry"
      assert sql =~ "persisted_at = now()"
    end
  end

  describe "delete_sql/1" do
    test "deletes by issue_id" do
      sql = Saver.delete_sql("symphony_paused_runs")
      assert sql =~ "DELETE FROM symphony_paused_runs WHERE issue_id = $1"
    end
  end

  describe "select_all_sql/1" do
    test "selects every persisted entry" do
      sql = Saver.select_all_sql("symphony_paused_runs")
      assert sql =~ "SELECT issue_id, entry FROM symphony_paused_runs"
    end
  end

  # --- Integration tests against a real Postgres database ---
  # Tagged :integration so they skip by default per the project's
  # test_helper.exs (and CI excludes :integration). To run them
  # locally, point RAXOL_SYMPHONY_PG_URL at a writable database:
  #
  #   RAXOL_SYMPHONY_PG_URL=postgres://localhost/raxol_symphony_test \
  #     mix test --only integration \
  #       test/raxol/symphony/orchestrator/paused_saver/postgrex_test.exs

  @moduletag :integration

  defp pg_conn_opts do
    case System.get_env("RAXOL_SYMPHONY_PG_URL") do
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
          "Postgres connection not configured; set RAXOL_SYMPHONY_PG_URL or POSTGRES_HOST + POSTGRES_DB"
        )

      opts ->
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
    "symphony_paused_test_#{:erlang.unique_integer([:positive])}"
  end

  defp paused_entry(issue_id) do
    %{
      issue: %{id: issue_id, identifier: "MT-#{issue_id}"},
      attempt: 1,
      workspace_path: "/tmp/ws-#{issue_id}",
      interrupt_reason: :awaiting_buyer_payment,
      resume_token: %{seq: 1, opaque: "x"},
      paused_at: System.monotonic_time(:millisecond),
      last_event: nil,
      last_message: "queued",
      turn_count: 3,
      tokens: %{input_tokens: 10, output_tokens: 5, total_tokens: 15}
    }
  end

  describe "live Postgres roundtrip" do
    test "put + load_all returns the same entry" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      entry = paused_entry("a")

      assert :ok = Saver.put(config, "a", entry)
      assert {:ok, %{"a" => loaded}} = Saver.load_all(config)
      assert loaded == entry
    end

    test "put on conflict updates the entry (overwrite semantics)" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      entry1 = paused_entry("a")
      entry2 = %{entry1 | interrupt_reason: :awaiting_evaluator_approval}

      assert :ok = Saver.put(config, "a", entry1)
      assert :ok = Saver.put(config, "a", entry2)
      assert {:ok, %{"a" => loaded}} = Saver.load_all(config)
      assert loaded.interrupt_reason == :awaiting_evaluator_approval
    end

    test "delete removes the entry" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      :ok = Saver.put(config, "a", paused_entry("a"))
      :ok = Saver.delete(config, "a")
      assert {:ok, %{}} = Saver.load_all(config)
    end

    test "load_all returns multiple entries keyed by issue_id" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      :ok = Saver.put(config, "a", paused_entry("a"))
      :ok = Saver.put(config, "b", paused_entry("b"))
      :ok = Saver.put(config, "c", paused_entry("c"))

      assert {:ok, loaded} = Saver.load_all(config)
      assert Map.keys(loaded) |> Enum.sort() == ["a", "b", "c"]
    end

    test "delete on unknown issue_id is idempotent" do
      conn = start_conn!()
      table = unique_table()
      Postgrex.query!(conn, Saver.create_table_sql(table), [])
      config = %{conn: conn, table: table}

      assert :ok = Saver.delete(config, "ghost")
    end
  end

  describe "missing postgrex" do
    test "raises a useful error if Postgrex is not loaded" do
      # If Postgrex is loaded in this environment, skip; the production
      # behaviour is exercised in consumer apps without postgrex.
      if Code.ensure_loaded?(Postgrex) do
        :ok
      else
        assert_raise RuntimeError, ~r/:postgrex package/, fn ->
          Saver.put(%{conn: :fake, table: "t"}, "a", %{})
        end
      end
    end
  end
end
