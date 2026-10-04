defmodule Raxol.Agent.ThreadLog.PostgrexTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.ThreadLog.Postgrex, as: Adapter
  import ExUnit.CaptureLog

  describe "create_table_sql/1" do
    test "produces the canonical schema for the default table" do
      sql = Adapter.create_table_sql()
      assert sql =~ "CREATE TABLE IF NOT EXISTS raxol_agent_threads"
      assert sql =~ ~r/thread_id\s+text NOT NULL/
      assert sql =~ ~r/sequence\s+bigint NOT NULL/
      assert sql =~ ~r/kind\s+text NOT NULL/
      assert sql =~ ~r/payload\s+bytea/
      assert sql =~ ~r/metadata\s+bytea NOT NULL/
      assert sql =~ ~r/recorded_at timestamptz NOT NULL DEFAULT now/
      assert sql =~ "PRIMARY KEY (thread_id, sequence)"
      assert sql =~ "raxol_agent_threads_kind_idx"
      assert sql =~ "(thread_id, kind, sequence)"
    end

    test "honors a custom table name" do
      sql = Adapter.create_table_sql("my_threads")
      assert sql =~ "CREATE TABLE IF NOT EXISTS my_threads"
      assert sql =~ "my_threads_kind_idx"
    end

    test "rejects unsafe identifiers" do
      for bad <- ["foo; DROP", "1bad", "a-b", "x'y", "with space", ""] do
        assert_raise ArgumentError, ~r/unsafe table name/, fn ->
          Adapter.create_table_sql(bad)
        end
      end
    end
  end

  describe "insert_sql/1" do
    test "uses COALESCE on MAX(sequence)+1 for atomic per-thread allocation" do
      sql = Adapter.insert_sql("raxol_agent_threads")
      assert sql =~ "INSERT INTO raxol_agent_threads"

      assert sql =~
               "(thread_id, sequence, kind, payload, metadata, recorded_at)"

      assert sql =~
               "COALESCE((SELECT MAX(sequence) + 1 FROM raxol_agent_threads WHERE thread_id = $1), 0)"

      assert sql =~ "RETURNING sequence"
    end
  end

  describe "select_latest_sql/1" do
    test "orders by sequence desc, limit 1" do
      sql = Adapter.select_latest_sql("raxol_agent_threads")
      assert sql =~ "SELECT sequence, kind, payload, metadata, recorded_at"
      assert sql =~ "WHERE thread_id = $1"
      assert sql =~ "ORDER BY sequence DESC"
      assert sql =~ "LIMIT 1"
    end
  end

  describe "truncate_sql/1" do
    test "deletes by thread_id and sequence bound" do
      sql = Adapter.truncate_sql("raxol_agent_threads")
      assert sql =~ "DELETE FROM raxol_agent_threads"
      assert sql =~ "WHERE thread_id = $1 AND sequence < $2"
    end
  end

  describe "table name validation" do
    test "all builders reject unsafe identifiers" do
      bad = "foo; DROP TABLE"

      for fun <- [
            &Adapter.insert_sql/1,
            &Adapter.select_latest_sql/1,
            &Adapter.truncate_sql/1
          ] do
        assert_raise ArgumentError, ~r/unsafe table name/, fn -> fun.(bad) end
      end
    end
  end

  # --- Live Postgres tests ---------------------------------------------------

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

  # create_table_sql/1 is two statements; the extended protocol
  # Postgrex.query!/3 uses accepts one per call.
  defp create_table!(conn, table) do
    drop_table!(conn, table)

    table
    |> Adapter.create_table_sql()
    |> String.split(";", trim: true)
    |> Enum.reject(&(String.trim(&1) == ""))
    |> Enum.each(&Postgrex.query!(conn, &1, []))
  end

  # unique_integer restarts with each VM, so a table name can repeat across
  # runs against the same database; clear whatever a previous run left.
  defp drop_table!(conn, table) do
    Postgrex.query!(conn, "DROP TABLE IF EXISTS #{table}", [])
  end

  defp unique_table do
    "raxol_agent_threads_test_#{:erlang.unique_integer([:positive])}"
  end

  describe "live Postgres roundtrip" do
    test "append + latest returns the same event" do
      conn = start_conn!()
      table = unique_table()
      create_table!(conn, table)
      config = %{conn: conn, table: table}

      assert {:ok, event} =
               Adapter.append(config, "thr-1", :directive, %{step: 1})

      assert event.thread_id == "thr-1"
      assert event.sequence == 0
      assert event.kind == :directive
      assert event.payload == %{step: 1}

      assert {:ok, latest} = Adapter.latest(config, "thr-1")
      assert latest.sequence == 0
    end

    test "sequence increments monotonically within a thread" do
      conn = start_conn!()
      table = unique_table()
      create_table!(conn, table)
      config = %{conn: conn, table: table}

      for n <- 0..4 do
        {:ok, %{sequence: ^n}} = Adapter.append(config, "thr-1", :tool_call, n)
      end

      assert {:ok, %{sequence: 4}} = Adapter.latest(config, "thr-1")
    end

    test "list_by_kind narrows by kind" do
      conn = start_conn!()
      table = unique_table()
      create_table!(conn, table)
      config = %{conn: conn, table: table}

      Adapter.append(config, "thr-1", :directive, "d1")
      Adapter.append(config, "thr-1", :tool_call, "t1")
      Adapter.append(config, "thr-1", :directive, "d2")

      assert {:ok, [%{payload: "d1"}, %{payload: "d2"}]} =
               Adapter.list_by_kind(config, "thr-1", :directive)
    end

    test "list_by_kind honours from/to/limit/order with and without an upper bound" do
      conn = start_conn!()
      table = unique_table()
      create_table!(conn, table)
      config = %{conn: conn, table: table}

      # directives land on even sequences 0..8, tool calls on odd 1..9
      for n <- 0..4 do
        {:ok, _} = Adapter.append(config, "thr-1", :directive, "d#{n}")
        {:ok, _} = Adapter.append(config, "thr-1", :tool_call, "t#{n}")
      end

      seqs = fn opts ->
        assert {:ok, events} = Adapter.list_by_kind(config, "thr-1", :directive, opts)
        assert Enum.all?(events, &(&1.kind == :directive))
        Enum.map(events, & &1.sequence)
      end

      assert seqs.(to: :infinity) == [0, 2, 4, 6, 8]
      assert seqs.(from: 3, to: :infinity) == [4, 6, 8]
      assert seqs.(to: :infinity, limit: 2) == [0, 2]
      assert seqs.(to: :infinity, order: :desc, limit: 2) == [8, 6]
      assert seqs.(to: 5) == [0, 2, 4]
      assert seqs.(from: 2, to: 6, limit: 2) == [2, 4]
      assert seqs.(from: 2, to: 6, order: :desc) == [6, 4, 2]
    end

    test "list honours from/to/limit/order" do
      conn = start_conn!()
      table = unique_table()
      create_table!(conn, table)
      config = %{conn: conn, table: table}

      for n <- 0..5, do: {:ok, _} = Adapter.append(config, "thr-1", :tool_call, n)

      seqs = fn opts ->
        assert {:ok, events} = Adapter.list(config, "thr-1", opts)
        Enum.map(events, & &1.sequence)
      end

      assert seqs.([]) == [0, 1, 2, 3, 4, 5]
      assert seqs.(from: 2, limit: 2) == [2, 3]
      assert seqs.(from: 1, to: 3) == [1, 2, 3]
      assert seqs.(to: 4, order: :desc, limit: 2) == [4, 3]
    end

    test "a failed read query is logged, not silently empty" do
      conn = start_conn!()
      # Absent table, so every read errors with undefined_table.
      table = unique_table()
      drop_table!(conn, table)
      config = %{conn: conn, table: table}

      for {op, call, expected} <- [
            {"list", fn -> Adapter.list(config, "thr-1") end, {:ok, []}},
            {"list_by_kind", fn -> Adapter.list_by_kind(config, "thr-1", :directive) end,
             {:ok, []}},
            {"latest", fn -> Adapter.latest(config, "thr-1") end, {:error, :not_found}}
          ] do
        log = capture_log(fn -> assert call.() == expected end)
        assert log =~ "[ThreadLog.Postgrex] #{op} on #{table}"
        assert log =~ ~s(thread "thr-1")
        assert log =~ "undefined_table"
      end
    end

    test "truncate removes events with sequence < before" do
      conn = start_conn!()
      table = unique_table()
      create_table!(conn, table)
      config = %{conn: conn, table: table}

      for n <- 0..4, do: Adapter.append(config, "thr-1", :tool_call, n)

      assert :ok = Adapter.truncate(config, "thr-1", 3)

      assert {:ok, events} = Adapter.list(config, "thr-1")
      assert Enum.map(events, & &1.sequence) == [3, 4]
    end
  end

  describe "decoding in a fresh VM" do
    # This test module names the canonical kind atoms, so only a child VM
    # that has loaded nothing but the adapter can observe the load-order bug.
    test "canonical kinds decode before anything interns their atoms" do
      conn = start_conn!()
      table = unique_table()
      create_table!(conn, table)
      config = %{conn: conn, table: table}

      {:ok, _} = Adapter.append(config, "thr-1", :tool_call, 1)
      {:ok, _} = Adapter.append(config, "thr-1", :state_snapshot, 2)

      Postgrex.query!(
        conn,
        Adapter.insert_sql(table),
        ["thr-1", "never_interned_kind_x9", nil, :erlang.term_to_binary(%{}), DateTime.utc_now()]
      )

      script = """
      for name <- ["tool" <> "_call", "state" <> "_snapshot"] do
        try do
          String.to_existing_atom(name)
          System.halt(2)
        rescue
          ArgumentError -> :ok
        end
      end

      {:ok, _} = Application.ensure_all_started(:postgrex)
      {opts, table} = System.fetch_env!("RAXOL_PG_CHILD") |> Base.decode64!() |> :erlang.binary_to_term()
      {:ok, conn} = Postgrex.start_link(opts)
      # Built at runtime: a literal remote call lets the compiler load the
      # adapter (and intern its atoms) before the check above runs.
      adapter = Module.concat(["Raxol", "Agent", "ThreadLog", "Postgrex"])
      {:ok, events} = adapter.list(%{conn: conn, table: table}, "thr-1")
      IO.write(inspect(Enum.map(events, & &1.kind)))
      """

      elixir = Path.expand("../../bin/elixir", :code.lib_dir(:elixir))
      pa = Enum.flat_map(:code.get_path(), &["-pa", List.to_string(&1)])
      payload = {pg_conn_opts(), table} |> :erlang.term_to_binary() |> Base.encode64()

      {out, status} =
        System.cmd(elixir, pa ++ ["-e", script],
          cd: System.tmp_dir!(),
          env: [{"RAXOL_PG_CHILD", payload}],
          stderr_to_stdout: true
        )

      # Status 2 means the child already had the atoms; the check is void.
      assert status == 0, "child exited #{status}: #{out}"
      assert out =~ ~s([:tool_call, :state_snapshot, "never_interned_kind_x9"])
    end
  end
end
