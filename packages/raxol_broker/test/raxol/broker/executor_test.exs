defmodule Raxol.Broker.ExecutorTest do
  @moduledoc """
  The executor end to end against an in-process MCP server speaking real
  JSON-RPC through the HTTP transport's `:exchange` seam
  (`Raxol.Broker.Test.OrderServer`), with a real hash-chained journal on disk.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Broker.{Executor, Intent, Journal, PolicyFile}
  alias Raxol.Broker.Executor.{Place, ReviewReceipt}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.OrderServer

  @moduletag :capture_log
  @t0 ~U[2026-10-02 14:30:00.000000Z]
  @day ~U[2026-10-02 00:00:00.000000Z]
  @account "ACC-1"

  setup_all do
    unless Code.ensure_loaded?(Raxol.MCP.Client.ReferenceServer.Legacy) and
             Code.ensure_loaded?(Raxol.MCP.Client.Transport.Http) do
      raise "raxol_broker tests need raxol_mcp built with plug and mint"
    end

    :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "broker-exec-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    path = Path.join(base, "journal")
    name = :"broker_exec_journal_#{System.unique_integer([:positive])}"
    journal_opts = [name: name, path: path, clock: fn -> @t0 end]
    start_journal!(journal_opts)

    {:ok, journal: name, journal_opts: journal_opts, path: path, server: OrderServer.start()}
  end

  defp d(value), do: Decimal.new(value)

  defp start_journal!(opts) do
    start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
  end

  defp start_executor!(ctx, extra \\ []) do
    opts =
      [
        journal: ctx.journal,
        session: OrderServer.session(ctx.server),
        account_number: @account,
        clock: fn -> @t0 end
      ] ++ extra

    id = {Executor, System.unique_integer([:positive])}
    start_supervised!(Supervisor.child_spec({Executor, opts}, id: id, restart: :temporary))
  end

  defp context do
    {:ok, policy} = PolicyFile.new(d("1000"), d("5000"))

    %Context{
      policy: policy,
      portfolio_value: d("100000"),
      start_of_day_value: d("100000"),
      day_pnl: d("0"),
      quotes: %{"AAPL" => d("125")},
      market_session: :regular
    }
  end

  defp limit(id, opts \\ []) do
    {:ok, intent} =
      Intent.limit(:buy, "AAPL", d("2"), d("125"), [provenance: :strategy, id: id] ++ opts)

    intent
  end

  defp records(path) do
    {base, session} = Journal.location(path)
    {:ok, records} = FileStore.read_records(session, base_dir: base)
    records
  end

  defp group(path, group_id), do: Enum.filter(records(path), &(&1["group_id"] == group_id))
  defp types(path, group_id), do: Enum.map(group(path, group_id), & &1["type"])

  defp groups_for(path, intent_id) do
    path
    |> records()
    |> Enum.filter(&(&1["type"] == "intent" and &1["intent"]["id"] == intent_id))
    |> Enum.map(& &1["group_id"])
  end

  defp writer(path) do
    {base, session} = Journal.location(path)
    :global.whereis_name({Writer, Path.join(base, session)})
  end

  defp stop_and_wait(pid, reason \\ :kill) do
    ref = Process.monitor(pid)
    Process.exit(pid, reason)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  defp flip_byte!(path) do
    [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))
    bytes = File.read!(segment)
    at = div(byte_size(bytes), 2)
    <<pre::binary-size(^at), byte, post::binary>> = bytes
    File.write!(segment, <<pre::binary, Bitwise.bxor(byte, 1), post::binary>>)
  end

  describe "allowed intent" do
    test "journals intent..order in order and places exactly once", ctx do
      executor = start_executor!(ctx)
      intent = limit("int-allow")

      assert {:ok, %{group_id: gid, status: :placed}} = Executor.run(executor, intent, context())

      assert types(ctx.path, gid) ==
               ~w(intent context verdict review verdict placing order)

      [intent_record | _] = group(ctx.path, gid)
      assert intent_record["mode"] == "dry_run"

      assert [{"review_equity_order", review}, {"place_equity_order", place}] =
               OrderServer.calls(ctx.server)

      refute Map.has_key?(review, "ref_id")
      assert place["ref_id"] == Place.ref_id("int-allow")
      assert place["limit_price"] == "125" and place["quantity"] == "2"
      assert place["account_number"] == @account
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}
    end

    test "a re-run of a placed intent is a duplicate and sends nothing", ctx do
      executor = start_executor!(ctx)
      intent = limit("int-dup")

      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
      assert length(groups_for(ctx.path, "int-dup")) == 1
    end

    test "the counters come from the journal, not the caller's context", ctx do
      executor = start_executor!(ctx)
      {:ok, policy} = PolicyFile.new(d("1000"), d("400"))
      tight = %{context() | policy: policy, today_notional: d("0"), orders_last_minute: 0}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("cap-1"), tight)

      assert {:deny, gid, {:daily_notional_cap, _}} =
               Executor.run(executor, limit("cap-2"), tight)

      assert types(ctx.path, gid) == ~w(intent context verdict)
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
    end
  end

  describe "review warnings" do
    setup ctx do
      OrderServer.warnings(ctx.server, ["Pattern day trader check"])
      {:ok, executor: start_executor!(ctx)}
    end

    test "turn ALLOW into a parked ASK with no place call", ctx do
      assert {:ask, gid, prompts} = Executor.run(ctx.executor, limit("warn-1"), context())
      assert [{:review_warning, _}] = prompts
      assert OrderServer.calls(ctx.server, "place_") == []
      assert types(ctx.path, gid) == ~w(intent context verdict review verdict)
      assert List.last(group(ctx.path, gid))["result"]["action"] == "ask"
      assert [%{group_id: ^gid}] = Executor.parked(ctx.executor)
      assert Journal.open_groups(ctx.journal) == {:ok, [gid]}

      assert Executor.run(ctx.executor, limit("warn-1"), context()) == {:error, {:parked, gid}}
    end

    test "approve journals the approval, re-checks, then places once", ctx do
      {:ask, gid, _} = Executor.run(ctx.executor, limit("warn-2"), context())

      assert {:ok, %{group_id: ^gid, status: :placed}} =
               Executor.approve(ctx.executor, gid, "droo@terminal")

      assert types(ctx.path, gid) ==
               ~w(intent context verdict review verdict approval verdict placing order)

      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
      assert Executor.parked(ctx.executor) == []
      assert Executor.approve(ctx.executor, gid, "droo") == {:error, {:not_parked, gid}}
    end

    test "approve re-runs the hard rules: a cap reached while parked denies", ctx do
      {:ok, policy} = PolicyFile.new(d("1000"), d("400"))
      tight = %{context() | policy: policy}
      {:ask, gid, _} = Executor.run(ctx.executor, limit("warn-3"), tight)

      OrderServer.warnings(ctx.server, [])
      assert {:ok, %{status: :placed}} = Executor.run(ctx.executor, limit("other"), tight)

      assert {:deny, ^gid, {:daily_notional_cap, _}} = Executor.approve(ctx.executor, gid, "droo")
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
      assert List.last(types(ctx.path, gid)) == "verdict"
    end

    test "decline and close end the group with no order", ctx do
      {:ask, declined, _} = Executor.run(ctx.executor, limit("warn-4"), context())
      {:ask, closed, _} = Executor.run(ctx.executor, limit("warn-5"), context())

      assert Executor.decline(ctx.executor, declined, "droo") == :ok
      assert Executor.close(ctx.executor, closed, :ask_timeout) == :ok

      assert List.last(group(ctx.path, declined))["decision"] == "declined"
      assert List.last(group(ctx.path, closed))["reason"] == "ask_timeout"
      assert Executor.approve(ctx.executor, declined, "droo") == {:error, {:not_parked, declined}}
      assert OrderServer.calls(ctx.server, "place_") == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
    end
  end

  describe "journal failures mean no order" do
    test "a refused placing append sends nothing", ctx do
      stop_supervised!(ctx.journal)
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      path = ctx.path

      # Records 1-5 are intent, context, both verdicts and the review; the
      # sixth clock read builds `placing`, and the Writer dies under it.
      clock = fn ->
        if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == 6,
          do: Process.exit(writer(path), :kill)

        @t0
      end

      start_journal!(Keyword.put(ctx.journal_opts, :clock, clock))
      executor = start_executor!(ctx)

      assert {:error, _reason} = Executor.run(executor, limit("refused"), context())
      assert OrderServer.calls(ctx.server, "review_") == ["review_equity_order"]
      assert OrderServer.calls(ctx.server, "place_") == []
    end

    test "a journal damaged mid-flight refuses the review record; nothing is placed", ctx do
      executor = start_executor!(ctx)

      OrderServer.on_call(ctx.server, "review_equity_order", fn _args ->
        flip_byte!(ctx.path)
        {:broken, _} = Journal.verify(ctx.journal)
      end)

      assert {:error, {:journal_damaged, _}} = Executor.run(executor, limit("dmg"), context())
      assert OrderServer.calls(ctx.server, "place_") == []
    end

    test "a journal already damaged refuses before any tool call", ctx do
      executor = start_executor!(ctx)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("first"), context())
      flip_byte!(ctx.path)
      assert {:broken, _} = Journal.verify(ctx.journal)

      assert {:error, {:journal_damaged, _}} =
               Executor.run(executor, limit("second"), context())

      assert length(OrderServer.calls(ctx.server)) == 2
    end
  end

  describe "restarts and idempotency" do
    test "a restart between review and place, then a re-run, places once", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      OrderServer.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, :reviewing)
        Process.exit(executor, :kill)
        :hang
      end)

      intent = limit("restart-1")
      catch_exit(Executor.run(executor, intent, context()))
      assert_received :reviewing

      # Journal restarts too: its recovery closes the open group.
      journal = GenServer.whereis(ctx.journal)
      stop_supervised!(ctx.journal)
      refute Process.alive?(journal)
      start_journal!(ctx.journal_opts)

      [first] = groups_for(ctx.path, "restart-1")
      assert List.last(group(ctx.path, first))["reason"] == "crash_before_verdict"

      OrderServer.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)
      executor = start_executor!(ctx)

      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "an executor restart alone closes the group it left open", ctx do
      executor = start_executor!(ctx)

      OrderServer.on_call(ctx.server, "review_equity_order", fn _args ->
        Process.exit(executor, :kill)
        :hang
      end)

      catch_exit(Executor.run(executor, limit("restart-2"), context()))
      [gid] = groups_for(ctx.path, "restart-2")
      assert Journal.open_groups(ctx.journal) == {:ok, [gid]}

      start_executor!(ctx)
      assert Journal.open_groups(ctx.journal) == {:ok, []}
      assert List.last(group(ctx.path, gid))["reason"] == "executor_restarted"
    end

    test "a crash after placing is crash_outcome_unknown, counted, and never re-placed", ctx do
      executor = start_executor!(ctx)
      path = ctx.path

      OrderServer.on_call(ctx.server, "place_equity_order", fn _args ->
        Process.exit(writer(path), :kill)
        Process.exit(executor, :kill)
        :hang
      end)

      intent = limit("crash-placing")
      catch_exit(Executor.run(executor, intent, context()))

      journal = GenServer.whereis(ctx.journal)
      if journal, do: stop_and_wait(journal)
      start_journal!(ctx.journal_opts)

      [gid] = groups_for(ctx.path, "crash-placing")
      assert List.last(group(ctx.path, gid))["reason"] == "crash_outcome_unknown"
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}

      OrderServer.on_call(ctx.server, "place_equity_order", fn _args -> :answer end)
      executor = start_executor!(ctx)
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a place call that times out is journaled :unknown and stays counted", ctx do
      executor = start_executor!(ctx, place_timeout: 100)
      OrderServer.on_call(ctx.server, "place_equity_order", fn _args -> :hang end)

      intent = limit("timeout")
      assert {:ok, %{group_id: gid, status: :unknown}} = Executor.run(executor, intent, context())

      assert %{"type" => "order", "status" => "unknown"} = List.last(group(ctx.path, gid))
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}
      assert Journal.orders_last_minute(@t0, ctx.journal) == {:ok, 1}
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
    end

    test "a JSON-RPC rejection is :failed and stops counting", ctx do
      executor = start_executor!(ctx)
      OrderServer.on_call(ctx.server, "place_equity_order", fn _args -> {:rpc_error, -32_000} end)

      assert {:ok, %{status: :failed}} = Executor.run(executor, limit("rejected"), context())
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("0")}
    end
  end

  describe "review receipts" do
    setup ctx do
      OrderServer.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      intent = limit("rcpt")
      {:ask, gid, _} = Executor.run(executor, intent, context())
      state = :sys.get_state(executor)
      receipt = state.parked[gid].receipt

      env = %{
        key: state.key,
        spent: state.spent,
        port: state.port,
        journal: ctx.journal,
        account: @account,
        timeout: 5_000
      }

      {:ok, executor: executor, intent: intent, gid: gid, receipt: receipt, env: env}
    end

    test "a hand-built receipt is refused and nothing is journaled or sent", ctx do
      forged =
        struct!(ReviewReceipt,
          intent_id: "rcpt",
          group_id: ctx.gid,
          digest: <<0::256>>,
          nonce: <<1::128>>,
          mac: <<0::256>>
        )

      assert Place.run(forged, ctx.intent, ctx.gid, ctx.env) == {:error, :invalid_receipt}
      assert Place.run(%{mac: "x"}, ctx.intent, ctx.gid, ctx.env) == {:error, :invalid_receipt}
      assert OrderServer.calls(ctx.server, "place_") == []
      refute "placing" in types(ctx.path, ctx.gid)
    end

    test "a receipt is bound to its intent, group and executor key", ctx do
      other = limit("someone-else")

      assert Place.run(ctx.receipt, other, ctx.gid, ctx.env) == {:error, :invalid_receipt}

      assert Place.run(ctx.receipt, ctx.intent, "other-group", ctx.env) ==
               {:error, :invalid_receipt}

      rotated = %{ctx.env | key: :crypto.strong_rand_bytes(32)}
      assert Place.run(ctx.receipt, ctx.intent, ctx.gid, rotated) == {:error, :invalid_receipt}
      assert OrderServer.calls(ctx.server, "place_") == []
    end

    test "a spent receipt is refused", ctx do
      assert {:ok, %{status: :placed}} = Executor.approve(ctx.executor, ctx.gid, "droo")
      spent = :sys.get_state(ctx.executor).spent

      assert Place.run(ctx.receipt, ctx.intent, ctx.gid, %{ctx.env | spent: spent}) ==
               {:error, :receipt_spent}

      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
    end
  end

  describe "mode" do
    test "armed mode is refused until arming exists", ctx do
      Process.flag(:trap_exit, true)

      assert Executor.start_link(
               journal: ctx.journal,
               session: OrderServer.session(ctx.server),
               account_number: @account,
               mode: :armed
             ) == {:error, :not_armed}
    end

    test "a port that reaches Robinhood is refused in dry-run", ctx do
      Process.flag(:trap_exit, true)

      session =
        Keyword.put(
          OrderServer.session(ctx.server),
          :url,
          "https://agent.robinhood.com/mcp/trading"
        )

      opts = [journal: ctx.journal, session: session, account_number: @account]
      assert Executor.start_link(opts) == {:error, :live_port_in_dry_run}
    end
  end

  describe "structural review" do
    @order_tool ~r/\b(?:place|cancel)_\w*order/
    @lib Path.expand("../../../lib", __DIR__)

    test "only Executor.Place names an order-writing tool" do
      offenders =
        for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
            Path.relative_to(file, @lib) != "raxol/broker/executor/place.ex",
            Regex.match?(@order_tool, File.read!(file)),
            do: Path.relative_to(file, @lib)

      assert offenders == []
    end

    test "only the review and place stages call through the write port" do
      allowed = ~w(raxol/broker/executor/review.ex raxol/broker/executor/place.ex
                   raxol/broker/executor/port.ex)

      offenders =
        for file <- Path.wildcard(Path.join(@lib, "**/*.ex")),
            Path.relative_to(file, @lib) not in allowed,
            File.read!(file) =~ ~r/Port\.call\(|call_tool\(/,
            not String.ends_with?(file, "executor/port/mcp.ex") and
              not String.ends_with?(file, "mcp/client.ex"),
            do: Path.relative_to(file, @lib)

      assert offenders == []
    end
  end
end
