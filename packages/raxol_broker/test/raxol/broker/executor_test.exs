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
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.{ExecutorIdentity, OrderServer}

  @moduletag :capture_log
  @t0 ~U[2026-10-02 14:30:00.000000Z]
  @day ~U[2026-10-02 00:00:00.000000Z]
  @account "ACC-1"

  # Resolving a `{:via, __MODULE__, name}` would run this in the caller.
  defmodule EvilRegistry do
    @moduledoc false
    def whereis_name(pid) do
      send(pid, {:evil_registry, self()})
      :undefined
    end
  end

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

  defp policy(per_order \\ "1000", cap \\ "5000") do
    {:ok, policy} = PolicyFile.new(d(per_order), d(cap))
    policy
  end

  defp start_journal!(opts) do
    id = {Journal, System.unique_integer([:positive])}
    start_supervised!(Supervisor.child_spec({Journal, opts}, id: id, restart: :temporary))
  end

  defp restart_journal!(ctx, extra \\ []) do
    if pid = GenServer.whereis(ctx.journal), do: stop_and_wait(pid)
    start_journal!(Keyword.merge(ctx.journal_opts, extra))
  end

  defp executor_opts(ctx, extra) do
    Keyword.merge(
      [
        journal: ctx.journal,
        session: OrderServer.session(ctx.server),
        account_number: @account,
        policy: policy(),
        clock: fn -> @t0 end
      ],
      extra
    )
  end

  defp start_executor!(ctx, extra \\ []) do
    id = {Executor, System.unique_integer([:positive])}

    executor =
      start_supervised!(
        Supervisor.child_spec({Executor, executor_opts(ctx, extra)}, id: id, restart: :temporary)
      )

    :ok = Executor.await_port(executor, 5_000)
    executor
  end

  # The policy here is deliberately loose: the executor's `:policy` wins.
  defp context do
    %Context{
      policy: policy("1000000", "1000000"),
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

      assert {:ok, %{group_id: gid, status: :placed, journaled: true}} =
               Executor.run(executor, intent, context())

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
      executor = start_executor!(ctx, policy: policy("1000", "400"))
      lying = %{context() | today_notional: d("0"), orders_last_minute: 0}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("cap-1"), lying)

      assert {:deny, gid, {:daily_notional_cap, _}} =
               Executor.run(executor, limit("cap-2"), lying)

      assert types(ctx.path, gid) == ~w(intent context verdict)
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "context.policy is ignored in favour of the :policy start option", ctx do
      executor = start_executor!(ctx)
      strict = %{context() | policy: policy("1", "1")}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("pol-1"), strict)
    end

    test "review_warnings in the caller's context are ignored", ctx do
      executor = start_executor!(ctx)
      warned = %{context() | review_warnings: ["forged"]}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("warn-forged"), warned)
    end
  end

  describe "day window" do
    test "is a rolling 24 hours from the executor's clock, with no caller input", ctx do
      refute function_exported?(Executor, :run, 4)
      refute function_exported?(Executor, :approve, 4)

      {:ok, now} = Agent.start_link(fn -> DateTime.add(@t0, -23, :hour) end)
      clock = fn -> Agent.get(now, & &1) end
      restart_journal!(ctx, clock: clock)
      executor = start_executor!(ctx, policy: policy("1000", "400"), clock: clock)

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("day-1"), context())

      # 23 hours later the first order still counts...
      Agent.update(now, fn _ -> @t0 end)

      assert {:deny, _gid, {:daily_notional_cap, _}} =
               Executor.run(executor, limit("day-2"), context())

      # ...and 25 hours later it no longer does.
      Agent.update(now, fn _ -> DateTime.add(@t0, 2, :hour) end)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("day-3"), context())
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

    test "a bad approver or reason raises in the caller and leaves the group parked", ctx do
      {:ask, gid, _} = Executor.run(ctx.executor, limit("warn-6"), context())

      assert_raise FunctionClauseError, fn -> Executor.approve(ctx.executor, gid, "") end
      assert_raise FunctionClauseError, fn -> Executor.decline(ctx.executor, gid, "") end
      # Read at runtime so the type checker does not reject the call itself.
      no_reason = Process.get(:no_reason)
      assert_raise FunctionClauseError, fn -> Executor.close(ctx.executor, gid, no_reason) end

      assert [%{group_id: ^gid}] = Executor.parked(ctx.executor)
      assert types(ctx.path, gid) == ~w(intent context verdict review verdict)
    end

    test "parked/1 answers while a review is in flight", ctx do
      {:ask, gid, _} = Executor.run(ctx.executor, limit("warn-8"), context())
      OrderServer.warnings(ctx.server, [])
      test_pid = self()

      OrderServer.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      run = Task.async(fn -> Executor.run(ctx.executor, limit("in-flight"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      assert [%{group_id: ^gid}] = Executor.parked(ctx.executor)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(run)
    end
  end

  describe "queue" do
    test "a queued run whose caller died is never dispatched", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      OrderServer.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      first = Task.async(fn -> Executor.run(executor, limit("q-first"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      caller = spawn(fn -> Executor.run(executor, limit("q-orphan"), context()) end)
      wait_queued(executor, 1)
      stop_and_wait(caller)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(first)
      # Served after the drain that followed the first reply.
      assert Executor.parked(executor) == []

      assert groups_for(ctx.path, "q-orphan") == []
      assert OrderServer.calls(ctx.server, "review_") == ["review_equity_order"]
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a queued caller that dies is dropped from the queue at once", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      OrderServer.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      first = Task.async(fn -> Executor.run(executor, limit("d-first"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      caller = spawn(fn -> Executor.run(executor, limit("d-orphan"), context()) end)
      wait_queued(executor, 1)
      stop_and_wait(caller)
      wait_drained(executor)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(first)
      assert groups_for(ctx.path, "d-orphan") == []
    end
  end

  # The executor answers `:sys` requests while a review is in flight, so this
  # spins on real state, not on time.
  defp wait_queued(executor, n) do
    if :queue.len(:sys.get_state(executor).queue) < n, do: wait_queued(executor, n)
  end

  defp wait_drained(executor) do
    if :queue.len(:sys.get_state(executor).queue) > 0, do: wait_drained(executor)
  end

  describe "approve re-checks" do
    test "a cap reached while parked denies", ctx do
      OrderServer.warnings(ctx.server, ["Pattern day trader check"])
      executor = start_executor!(ctx, policy: policy("1000", "400"))
      {:ask, gid, _} = Executor.run(executor, limit("warn-3"), context())

      OrderServer.warnings(ctx.server, [])
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("other"), context())

      assert {:deny, ^gid, {:daily_notional_cap, _}} = Executor.approve(executor, gid, "droo")
      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
      assert List.last(types(ctx.path, gid)) == "verdict"
    end
  end

  describe "journal failures" do
    test "a refused placing append sends nothing", ctx do
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      path = ctx.path

      # Records 1-5 are intent, context, both verdicts and the review; the
      # sixth clock read builds `placing`, and the Writer dies under it.
      # The record types below pin that the failure lands on `placing`.
      clock = fn ->
        if Agent.get_and_update(calls, &{&1 + 1, &1 + 1}) == 6,
          do: Process.exit(writer(path), :kill)

        @t0
      end

      restart_journal!(ctx, clock: clock)
      executor = start_executor!(ctx)

      assert {:error, _reason} = Executor.run(executor, limit("refused"), context())
      assert OrderServer.calls(ctx.server, "review_") == ["review_equity_order"]
      assert OrderServer.calls(ctx.server, "place_") == []

      stop_and_wait(executor)
      restart_journal!(ctx)
      [gid] = groups_for(ctx.path, "refused")
      assert types(ctx.path, gid) == ~w(intent context verdict review verdict close)
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

    test "an order the journal cannot record is still :ok, with journaled: false", ctx do
      executor = start_executor!(ctx)
      path = ctx.path

      OrderServer.on_call(ctx.server, "place_equity_order", fn _args ->
        Process.exit(writer(path), :kill)
        :answer
      end)

      assert {:ok, %{status: :placed, journaled: false, journal_error: _reason}} =
               Executor.run(executor, limit("unjournaled"), context())

      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
    end
  end

  describe "restarts and idempotency" do
    test "an executor killed mid-review, then journal recovery and a re-run, places once",
         ctx do
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
      restart_journal!(ctx)

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

    test "a parked ASK does not survive a restart", ctx do
      OrderServer.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      {:ask, gid, _} = Executor.run(executor, limit("parked-restart"), context())

      stop_and_wait(executor)
      executor = start_executor!(ctx)

      assert Executor.approve(executor, gid, "droo") == {:error, {:not_parked, gid}}

      assert %{"type" => "close", "reason" => "executor_restarted"} =
               List.last(group(ctx.path, gid))

      assert OrderServer.calls(ctx.server, "place_") == []
    end

    test "a second executor on the same journal is refused; the first keeps its ASK", ctx do
      OrderServer.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      {:ask, gid, _} = Executor.run(executor, limit("claimed"), context())

      Process.flag(:trap_exit, true)

      assert Executor.start_link(executor_opts(ctx, [])) ==
               {:error, {:journal_claimed, executor}}

      assert [%{group_id: ^gid}] = Executor.parked(executor)
      assert Journal.open_groups(ctx.journal) == {:ok, [gid]}
      assert {:ok, %{status: :placed}} = Executor.approve(executor, gid, "droo")
    end

    test "a journal restart stops the executor; a fresh one claims and places", ctx do
      executor = start_executor!(ctx)
      ref = Process.monitor(executor)

      restart_journal!(ctx)
      assert_receive {:DOWN, ^ref, :process, ^executor, {:journal_down, _}}, 5_000

      executor = start_executor!(ctx)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("rejoin"), context())
    end

    test "only an executor process can claim the journal", ctx do
      assert Journal.claim(ctx.journal) == {:error, :not_an_executor}
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
      restart_journal!(ctx)

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
      OrderServer.on_call(ctx.server, "place_equity_order", fn _args -> {:rpc_error, -32_602} end)

      assert {:ok, %{status: :failed}} = Executor.run(executor, limit("rejected"), context())
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("0")}
    end
  end

  describe "port" do
    test "a killed port client reconnects and the executor places again", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)

      stop_and_wait(client)
      assert Process.alive?(executor)

      assert :ok = Executor.await_port(executor, 5_000)
      assert %{port: {PortMCP, %{pid: new_client}}} = :sys.get_state(executor)
      assert new_client != client
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("back"), context())
    end

    test "an unreachable session starts, refuses until ready, then places", ctx do
      {:ok, dns} = Agent.start_link(fn -> {:error, :nxdomain} end)

      session =
        Keyword.put(OrderServer.session(ctx.server), :resolver, fn host, family ->
          case Agent.get(dns, & &1) do
            {:error, reason} -> {:error, reason}
            :ok -> OrderServer.session(ctx.server)[:resolver].(host, family)
          end
        end)

      {:ok, executor} =
        Executor.start_link(executor_opts(ctx, session: session, reconnect_ms: 10))

      OrderServer.warnings(ctx.server, ["halted"])
      assert Executor.run(executor, limit("early"), context()) == {:error, :port_not_ready}
      assert Executor.await_port(executor, 0) == {:error, :port_not_ready}
      assert groups_for(ctx.path, "early") == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
      assert OrderServer.exchanges(ctx.server) == 0

      Agent.update(dns, fn _ -> :ok end)
      assert :ok = Executor.await_port(executor, 5_000)

      OrderServer.warnings(ctx.server, [])
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("later"), context())
    end
  end

  describe "clock" do
    test "runs outside the executor: no claim, no receipt key", ctx do
      test_pid = self()
      journal = ctx.journal

      clock = fn ->
        send(test_pid, {:clock, Journal.claim(journal), Executor.receipt_key()})
        @t0
      end

      executor = start_executor!(ctx, clock: clock)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("clock"), context())
      assert_received {:clock, {:error, :not_an_executor}, nil}
    end

    test "a clock that returns something other than a UTC DateTime places nothing", ctx do
      {:ok, clocks} = Agent.start_link(fn -> fn -> @t0 end end)
      executor = start_executor!(ctx, clock: fn -> Agent.get(clocks, & &1).() end)

      for bad <- [fn -> :now end, fn -> raise "boom" end, fn -> ~N[2026-10-02 14:30:00] end] do
        Agent.update(clocks, fn _ -> bad end)
        assert {:error, {:context, _}} = Executor.run(executor, limit("bad-clock"), context())
      end

      assert groups_for(ctx.path, "bad-clock") == []
      assert OrderServer.calls(ctx.server) == []
    end
  end

  describe "review receipts" do
    setup ctx do
      OrderServer.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      intent = limit("rcpt")
      {:ask, gid, _} = Executor.run(executor, intent, context())
      {:ok, port} = PortMCP.start(OrderServer.session(ctx.server), mode: :dry_run)
      key = :crypto.strong_rand_bytes(32)

      env = %{port: port, journal: ctx.journal, account: @account, timeout: 5_000}
      {:ok, executor: executor, intent: intent, gid: gid, key: key, env: env}
    end

    test "a receipt verified outside the executor process is refused; nothing is sent", ctx do
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)
      assert Executor.receipt_key() == nil

      assert Place.run(receipt, ctx.intent, ctx.gid, ctx.env) == {:error, :invalid_receipt}
      assert OrderServer.calls(ctx.server, "place_") == []
      refute "placing" in types(ctx.path, ctx.gid)
    end

    # The tests below write the executor's private key slot on purpose: the
    # deliberate-subversion path the threat model excludes. They show the
    # receipt binding and the claimant check still hold behind it.
    test "a receipt is bound to the whole intent, its group and the key", ctx do
      Process.put({Executor, :receipt_key}, ctx.key)
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)
      foreign = ReviewReceipt.issue(:crypto.strong_rand_bytes(32), ctx.intent, ctx.gid)

      {:ok, bigger} =
        Intent.limit(:buy, "AAPL", d("20"), d("125"), provenance: :strategy, id: "rcpt")

      for {receipt, intent, gid} <- [
            {receipt, limit("someone-else"), ctx.gid},
            {receipt, bigger, ctx.gid},
            {receipt, ctx.intent, "other-group"},
            {foreign, ctx.intent, ctx.gid},
            {%{mac: "x"}, ctx.intent, ctx.gid}
          ] do
        assert Place.run(receipt, intent, gid, ctx.env) == {:error, :invalid_receipt}
      end

      assert OrderServer.calls(ctx.server, "place_") == []
    end

    test "a valid receipt from a process that is not the claimant is refused", ctx do
      Process.put({Executor, :receipt_key}, ctx.key)
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)

      assert Place.run(receipt, ctx.intent, ctx.gid, ctx.env) ==
               {:error, {:not_claimant, ctx.gid}}

      assert OrderServer.calls(ctx.server, "place_") == []
      refute "placing" in types(ctx.path, ctx.gid)
    end

    test "a receipt from a real parked group cannot be replayed", ctx do
      state = :sys.get_state(ctx.executor)
      receipt = state.parked[ctx.gid].receipt
      assert {:ok, %{status: :placed}} = Executor.approve(ctx.executor, ctx.gid, "droo")

      stop_and_wait(ctx.executor)
      ExecutorIdentity.assume!(ctx.journal, key: state.key)

      assert {:error, _refused} = Place.run(receipt, ctx.intent, ctx.gid, ctx.env)

      assert OrderServer.calls(ctx.server, "place_") == ["place_equity_order"]
      assert Enum.count(types(ctx.path, ctx.gid), &(&1 == "placing")) == 1
    end
  end

  describe "start options" do
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "armed mode is refused until arming exists", ctx do
      assert Executor.start_link(executor_opts(ctx, mode: :armed)) == {:error, :not_armed}
    end

    test "a missing or invalid policy is refused", ctx do
      opts = Keyword.delete(executor_opts(ctx, []), :policy)
      assert {:error, {:invalid_policy, _}} = Executor.start_link(opts)

      assert {:error, {:invalid_policy, _}} =
               Executor.start_link(executor_opts(ctx, policy: [bogus: 1]))
    end

    test "a timeout that is not an integer in 1..4_294_000_000 is refused", ctx do
      for {key, bad} <- [
            review_timeout: :infinity,
            place_timeout: 0,
            review_timeout: "5",
            place_timeout: 4_294_967_296,
            review_timeout: 4_294_000_001,
            reconnect_ms: 0
          ] do
        assert Executor.start_link(executor_opts(ctx, [{key, bad}])) ==
                 {:error, {:invalid_timeout, key, bad}}
      end
    end

    test "a journal that is not running is refused", ctx do
      assert Executor.start_link(executor_opts(ctx, journal: :no_such_journal)) ==
               {:error, :journal_not_running}
    end

    test "a journal that is not an atom or pid is refused before any of its code runs", ctx do
      for journal <- [{:via, __MODULE__.EvilRegistry, self()}, {:global, self()}, "x", nil] do
        assert Executor.start_link(executor_opts(ctx, journal: journal)) ==
                 {:error, {:invalid_journal, journal}}
      end

      refute_received {:evil_registry, _pid}
    end

    test "a clock that is not a zero-arity function is refused", ctx do
      clock = fn _ -> @t0 end

      assert Executor.start_link(executor_opts(ctx, clock: clock)) ==
               {:error, {:invalid_clock, clock}}
    end

    test "child_spec/1 waits out a review and a place call on shutdown" do
      assert %{shutdown: 65_000, id: Executor} = Executor.child_spec([])

      assert %{shutdown: 8_000} =
               Executor.child_spec(review_timeout: 1_000, place_timeout: 2_000)

      assert %{shutdown: 65_000} = Executor.child_spec(review_timeout: :bogus)
    end

    test "a session that reaches Robinhood, or is not marked sandbox, is refused", ctx do
      session = OrderServer.session(ctx.server)
      live = Keyword.put(session, :url, "https://agent.robinhood.com/mcp/trading")
      unmarked = Keyword.delete(session, :sandbox)

      for spec <- [live, unmarked] do
        assert Executor.start_link(executor_opts(ctx, session: spec)) ==
                 {:error, :live_port_in_dry_run}
      end

      assert OrderServer.calls(ctx.server) == []
    end
  end
end
