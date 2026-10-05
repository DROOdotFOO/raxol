defmodule Raxol.Broker.ExecutorTest do
  @moduledoc """
  The executor end to end against an in-process MCP server speaking real
  JSON-RPC through the HTTP transport's `:exchange` seam
  (`Raxol.Broker.MCP.Fake`), with a real hash-chained journal on disk.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.Journal.FileStore.Writer
  alias Raxol.Broker.{Executor, Intent, Journal, PolicyFile}
  alias Raxol.Broker.Executor.{Place, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.{ExecutorIdentity, Hostile}

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

    {:ok, journal: name, journal_opts: journal_opts, path: path, server: Fake.start()}
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
        session: Fake.session(ctx.server),
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
               Fake.calls(ctx.server)

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
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
      assert length(groups_for(ctx.path, "int-dup")) == 1
    end

    test "the counters come from the journal, not the caller's context", ctx do
      executor = start_executor!(ctx, policy: policy("1000", "400"))
      lying = %{context() | today_notional: d("0"), orders_last_minute: 0}

      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("cap-1"), lying)

      assert {:deny, gid, {:daily_notional_cap, _}} =
               Executor.run(executor, limit("cap-2"), lying)

      assert types(ctx.path, gid) == ~w(intent context verdict)
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
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
      Fake.warnings(ctx.server, ["Pattern day trader check"])
      {:ok, executor: start_executor!(ctx)}
    end

    test "turn ALLOW into a parked ASK with no place call", ctx do
      assert {:ask, gid, prompts} = Executor.run(ctx.executor, limit("warn-1"), context())
      assert [{:review_warning, _}] = prompts
      assert Fake.calls(ctx.server, "place_") == []
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

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
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
      assert Fake.calls(ctx.server, "place_") == []
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
      Fake.warnings(ctx.server, [])
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
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

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
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
      assert Fake.calls(ctx.server, "review_") == ["review_equity_order"]
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a queued caller that dies is dropped from the queue at once", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
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
      Fake.warnings(ctx.server, ["Pattern day trader check"])
      executor = start_executor!(ctx, policy: policy("1000", "400"))
      {:ask, gid, _} = Executor.run(executor, limit("warn-3"), context())

      Fake.warnings(ctx.server, [])
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("other"), context())

      assert {:deny, ^gid, {:daily_notional_cap, _}} = Executor.approve(executor, gid, "droo")
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
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
      assert Fake.calls(ctx.server, "review_") == ["review_equity_order"]
      assert Fake.calls(ctx.server, "place_") == []

      stop_and_wait(executor)
      restart_journal!(ctx)
      [gid] = groups_for(ctx.path, "refused")
      assert types(ctx.path, gid) == ~w(intent context verdict review verdict close)
    end

    test "a journal damaged mid-flight refuses the review record; nothing is placed", ctx do
      executor = start_executor!(ctx)

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        flip_byte!(ctx.path)
        {:broken, _} = Journal.verify(ctx.journal)
      end)

      assert {:error, {:journal_damaged, _}} = Executor.run(executor, limit("dmg"), context())
      assert Fake.calls(ctx.server, "place_") == []
    end

    test "a journal already damaged refuses before any tool call", ctx do
      executor = start_executor!(ctx)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("first"), context())
      flip_byte!(ctx.path)
      assert {:broken, _} = Journal.verify(ctx.journal)

      assert {:error, {:journal_damaged, _}} =
               Executor.run(executor, limit("second"), context())

      assert length(Fake.calls(ctx.server)) == 2
    end

    test "an order the journal cannot record is still :ok, with journaled: false", ctx do
      executor = start_executor!(ctx)
      path = ctx.path

      Fake.on_call(ctx.server, "place_equity_order", fn _args ->
        Process.exit(writer(path), :kill)
        :answer
      end)

      assert {:ok, %{status: :placed, journaled: false, journal_error: _reason}} =
               Executor.run(executor, limit("unjournaled"), context())

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end
  end

  describe "restarts and idempotency" do
    test "an executor killed mid-review, then journal recovery and a re-run, places once",
         ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
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

      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)
      executor = start_executor!(ctx)

      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "an executor restart alone closes the group it left open", ctx do
      executor = start_executor!(ctx)

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
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
      Fake.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      {:ask, gid, _} = Executor.run(executor, limit("parked-restart"), context())

      stop_and_wait(executor)
      executor = start_executor!(ctx)

      assert Executor.approve(executor, gid, "droo") == {:error, {:not_parked, gid}}

      assert %{"type" => "close", "reason" => "executor_restarted"} =
               List.last(group(ctx.path, gid))

      assert Fake.calls(ctx.server, "place_") == []
    end

    test "a second executor on the same journal is refused; the first keeps its ASK", ctx do
      Fake.warnings(ctx.server, ["halted"])
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

      Fake.on_call(ctx.server, "place_equity_order", fn _args ->
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

      Fake.on_call(ctx.server, "place_equity_order", fn _args -> :answer end)
      executor = start_executor!(ctx)
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a place call that times out is journaled :unknown and stays counted", ctx do
      executor = start_executor!(ctx, place_timeout: 100)
      Fake.on_call(ctx.server, "place_equity_order", fn _args -> :hang end)

      intent = limit("timeout")
      assert {:ok, %{group_id: gid, status: :unknown}} = Executor.run(executor, intent, context())

      assert %{"type" => "order", "status" => "unknown"} = List.last(group(ctx.path, gid))
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}
      assert Journal.orders_last_minute(@t0, ctx.journal) == {:ok, 1}
      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
    end

    test "a JSON-RPC rejection is :failed and stops counting", ctx do
      executor = start_executor!(ctx)
      Fake.on_call(ctx.server, "place_equity_order", fn _args -> {:rpc_error, -32_602} end)

      assert {:ok, %{status: :failed}} = Executor.run(executor, limit("rejected"), context())
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("0")}
    end

    test "a 429 on place is :unknown, stays counted, and is never re-sent", ctx do
      executor = start_executor!(ctx)
      Fake.inject(ctx.server, [{"place_equity_order", {:http, 429}}])

      intent = limit("throttled")
      assert {:ok, %{group_id: gid, status: :unknown}} = Executor.run(executor, intent, context())
      assert %{"type" => "order", "status" => "unknown"} = List.last(group(ctx.path, gid))
      assert Journal.today_notional(@day, ctx.journal) == {:ok, d("250")}

      assert Executor.run(executor, intent, context()) == {:ok, :duplicate}
      assert [{"tools/call", "place_equity_order", 429}] = place_requests(ctx.server)
      assert Fake.orders(ctx.server) == []
    end

    test "a 429 on review places nothing and leaves the intent free to retry", ctx do
      executor = start_executor!(ctx)
      Fake.inject(ctx.server, [{"review_equity_order", {:http, 429}}])

      intent = limit("review-throttled")
      assert {:error, _reason} = Executor.run(executor, intent, context())
      assert place_requests(ctx.server) == []

      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert [%{"state" => "queued"}] = Fake.orders(ctx.server)
    end
  end

  defp place_requests(fake),
    do: for({"tools/call", "place_" <> _, _status} = request <- Fake.requests(fake), do: request)

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
        Keyword.put(Fake.session(ctx.server), :resolver, fn host, family ->
          case Agent.get(dns, & &1) do
            {:error, reason} -> {:error, reason}
            :ok -> Fake.session(ctx.server)[:resolver].(host, family)
          end
        end)

      {:ok, executor} =
        Executor.start_link(executor_opts(ctx, session: session, reconnect_ms: 10))

      Fake.warnings(ctx.server, ["halted"])
      assert Executor.run(executor, limit("early"), context()) == {:error, :port_not_ready}
      assert Executor.await_port(executor, 0) == {:error, :port_not_ready}
      assert groups_for(ctx.path, "early") == []
      assert Journal.open_groups(ctx.journal) == {:ok, []}
      assert Fake.exchanges(ctx.server) == 0

      Agent.update(dns, fn _ -> :ok end)
      assert :ok = Executor.await_port(executor, 5_000)

      Fake.warnings(ctx.server, [])
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
      assert Fake.calls(ctx.server) == []
    end
  end

  describe "review receipts" do
    setup ctx do
      Fake.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      intent = limit("rcpt")
      {:ask, gid, _} = Executor.run(executor, intent, context())
      {:ok, port} = PortMCP.start(Fake.session(ctx.server), mode: :dry_run)
      key = :crypto.strong_rand_bytes(32)

      env = %{port: port, journal: ctx.journal, account: @account, timeout: 5_000}
      {:ok, executor: executor, intent: intent, gid: gid, key: key, env: env}
    end

    test "a receipt verified outside the executor process is refused; nothing is sent", ctx do
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)
      assert Executor.receipt_key() == nil

      assert Place.run(receipt, ctx.intent, ctx.gid, ctx.env) == {:error, :invalid_receipt}
      assert Fake.calls(ctx.server, "place_") == []
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

      assert Fake.calls(ctx.server, "place_") == []
    end

    test "a valid receipt from a process that is not the claimant is refused", ctx do
      Process.put({Executor, :receipt_key}, ctx.key)
      receipt = ReviewReceipt.issue(ctx.key, ctx.intent, ctx.gid)

      assert Place.run(receipt, ctx.intent, ctx.gid, ctx.env) ==
               {:error, {:not_claimant, ctx.gid}}

      assert Fake.calls(ctx.server, "place_") == []
      refute "placing" in types(ctx.path, ctx.gid)
    end

    test "a receipt from a real parked group cannot be replayed", ctx do
      state = :sys.get_state(ctx.executor)
      receipt = state.parked[ctx.gid].receipt
      assert {:ok, %{status: :placed}} = Executor.approve(ctx.executor, ctx.gid, "droo")

      stop_and_wait(ctx.executor)
      ExecutorIdentity.assume!(ctx.journal, key: state.key)

      assert {:error, _refused} = Place.run(receipt, ctx.intent, ctx.gid, ctx.env)

      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
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

    test "child_spec/1 waits out a place call on shutdown; :shutdown overrides" do
      assert %{shutdown: 35_000, id: Executor} = Executor.child_spec([])

      assert %{shutdown: 7_000} =
               Executor.child_spec(review_timeout: 1_000, place_timeout: 2_000)

      assert %{shutdown: 35_000} = Executor.child_spec(place_timeout: :bogus)
      assert %{shutdown: 120_000} = Executor.child_spec(place_timeout: 2_000, shutdown: 120_000)

      for bad <- [0, -1, :infinity, 1.5, "60000"] do
        assert_raise ArgumentError, fn -> Executor.child_spec(shutdown: bad) end
      end
    end

    test "a session that reaches Robinhood, or is not marked sandbox, is refused", ctx do
      session = Fake.session(ctx.server)
      live = Keyword.put(session, :url, "https://agent.robinhood.com/mcp/trading")
      unmarked = Keyword.delete(session, :sandbox)

      for spec <- [live, unmarked] do
        assert Executor.start_link(executor_opts(ctx, session: spec)) ==
                 {:error, :live_port_in_dry_run}
      end

      assert Fake.calls(ctx.server) == []
    end
  end

  describe "round 4" do
    test "a struct in caller data never runs: refused before any call", ctx do
      executor = start_executor!(ctx)
      before = records(ctx.path)
      hostile = %{context() | quotes: Hostile.new(), positions: Hostile.new()}
      intent = limit("hostile")

      assert {:error, {:invalid_context, _}} = Executor.run(executor, intent, hostile)
      # Straight to the server, past the client-side check.
      assert {:error, {:invalid_context, _}} =
               GenServer.call(executor, {:run, intent, hostile})

      assert {:error, {:invalid_intent, _}} =
               GenServer.call(executor, {:run, Hostile.new(), context()})

      assert {:error, {:invalid_intent, _}} =
               GenServer.call(executor, {:run, %{intent | params: Hostile.new()}, context()})

      assert {:error, :unknown_request} = GenServer.call(executor, Hostile.new())

      refute_received {:hostile, _callback}
      assert records(ctx.path) == before
      assert Fake.calls(ctx.server) == []
      assert Process.alive?(executor)
      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
    end

    test "a port lost between review and place closes the group unplaced", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      intent = limit("port-gone")
      run = Task.async(fn -> Executor.run(executor, intent, context()) end)
      assert_receive {:reviewing, hook}, 5_000

      # Hold the review task with the answer in its mailbox, then lose the
      # client and let the executor handle that EXIT before the result.
      %{busy: %{pid: review}} = :sys.get_state(executor)
      true = :erlang.suspend_process(review)
      hook_ref = Process.monitor(hook)
      send(hook, :go)
      assert_receive {:DOWN, ^hook_ref, :process, ^hook, _}, 5_000
      _ = :sys.get_state(client)
      stop_and_wait(client)
      assert %{port: nil} = :sys.get_state(executor)
      true = :erlang.resume_process(review)

      assert Task.await(run) == {:error, :port_not_ready}
      [gid] = groups_for(ctx.path, "port-gone")
      refute "placing" in types(ctx.path, gid)
      assert List.last(group(ctx.path, gid))["reason"] == "port_not_ready"
      assert Fake.calls(ctx.server, "place_") == []

      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)
      assert :ok = Executor.await_port(executor, 5_000)
      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end

    test "a client that dies while connecting leaves the executor up", ctx do
      {:ok, dns} = Agent.start_link(fn -> :raise end)
      test_pid = self()
      good = Fake.session(ctx.server)[:resolver]

      session =
        Keyword.put(Fake.session(ctx.server), :resolver, fn host, family ->
          case Agent.get(dns, & &1) do
            :raise ->
              send(test_pid, :resolving)
              raise "resolver blew up"

            :ok ->
              good.(host, family)
          end
        end)

      {:ok, executor} =
        Executor.start_link(executor_opts(ctx, session: session, reconnect_ms: 10))

      assert_receive :resolving, 5_000
      assert %{connect: %Task{}, port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)
      stop_and_wait(client)
      # Handled the EXIT (a reconnect may already be under way) and still up.
      assert %{port_status: status} = :sys.get_state(executor)
      assert status != :ready

      Agent.update(dns, fn _ -> :ok end)
      assert :ok = Executor.await_port(executor, 5_000)
      assert Process.alive?(executor)
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("reborn"), context())
    end

    test "await_port refuses a timeout past the timer limit and stays up", ctx do
      session =
        Keyword.put(Fake.session(ctx.server), :resolver, fn _host, _family ->
          {:error, :nxdomain}
        end)

      {:ok, executor} = Executor.start_link(executor_opts(ctx, session: session))
      huge = 10_000_000_000

      assert Executor.await_port(executor, huge) ==
               {:error, {:invalid_timeout, :await_port, huge}}

      assert Executor.await_port(executor, 0) == {:error, :port_not_ready}
      assert Process.alive?(executor)
    end

    test "approvals queued behind a review drain one per callback, in order", ctx do
      Fake.warnings(ctx.server, ["halted"])
      executor = start_executor!(ctx)
      {:ask, g1, _} = Executor.run(executor, limit("drain-1"), context())
      {:ask, g2, _} = Executor.run(executor, limit("drain-2"), context())
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      held = Task.async(fn -> Executor.run(executor, limit("drain-held"), context()) end)
      assert_receive {:reviewing, hook}, 5_000

      first = Task.async(fn -> Executor.approve(executor, g1, "droo") end)
      wait_queued(executor, 1)
      second = Task.async(fn -> Executor.approve(executor, g2, "droo") end)
      wait_queued(executor, 2)

      :ok =
        :sys.install(
          executor,
          {fn
             n, {:in, :drain}, _name -> send(test_pid, {:drain, n}) && n + 1
             n, _event, _name -> n
           end, 0}
        )

      send(hook, :go)
      assert {:ask, _gid, _} = Task.await(held)
      assert {:ok, %{group_id: ^g1, status: :placed}} = Task.await(first)
      assert {:ok, %{group_id: ^g2, status: :placed}} = Task.await(second)

      # One :drain dispatched the first approval, a second the next.
      assert_receive {:drain, 0}
      assert_receive {:drain, 1}

      refs = for {"place_" <> _, args} <- Fake.calls(ctx.server), do: args["ref_id"]
      assert refs == [Place.ref_id("drain-1"), Place.ref_id("drain-2")]
    end

    test "a stalled journal writer stops the journal and then the executor", ctx do
      restart_journal!(ctx, write_deadline: 50)
      executor = start_executor!(ctx)
      ref = Process.monitor(executor)

      :ok = :sys.suspend(writer(ctx.path))

      assert {:error, {:journal_down, _}} =
               Executor.run(executor, limit("stalled"), context())

      assert_receive {:DOWN, ^ref, :process, ^executor, {:journal_down, {:writer_stalled, 50}}},
                     5_000

      assert Fake.calls(ctx.server) == []
    end
  end

  describe "round 5" do
    test "a hostile message is ignored without running its protocols", ctx do
      executor = start_executor!(ctx)
      GenServer.cast(executor, Hostile.new())
      GenServer.cast(executor, {:unexpected, Hostile.new()})
      before = records(ctx.path)

      send(executor, Hostile.new())
      send(executor, {:unexpected, Hostile.new()})
      send(executor, {Hostile.new(), :tag})
      send(executor, [Hostile.new()])
      _ = :sys.get_state(executor)

      refute_received {:hostile, _callback}
      assert Process.alive?(executor)
      assert records(ctx.path) == before
      assert Fake.calls(ctx.server) == []
    end

    test "a port client stopped with a struct reason runs no protocol and reconnects", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)

      stop_and_wait(client, {:shutdown, Hostile.new()})
      _ = :sys.get_state(executor)

      refute_received {:hostile, _callback}
      assert :ok = Executor.await_port(executor, 5_000)
      assert %{port: {PortMCP, %{pid: new_client}}} = :sys.get_state(executor)
      assert new_client != client
      assert {:ok, %{status: :placed}} = Executor.run(executor, limit("struct-exit"), context())
    end

    test "a clock DateTime in another calendar is a context error; nothing opens", ctx do
      {:ok, clocks} = Agent.start_link(fn -> fn -> @t0 end end)
      executor = start_executor!(ctx, clock: fn -> Agent.get(clocks, & &1).() end)

      bad = [
        %{@t0 | calendar: __MODULE__.NotACalendar},
        %{@t0 | utc_offset: 3_600},
        %{@t0 | month: 13},
        %{@t0 | microsecond: {0, 9}}
      ]

      for now <- bad do
        Agent.update(clocks, fn _ -> fn -> now end end)

        assert {:error, {:context, {:invalid_clock, _}}} =
                 Executor.run(executor, limit("odd-calendar"), context())
      end

      assert Process.alive?(executor)
      assert groups_for(ctx.path, "odd-calendar") == []
      assert Fake.calls(ctx.server) == []
    end

    test "a stale :drain during a review is ignored; the queued run completes", ctx do
      executor = start_executor!(ctx)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      held = Task.async(fn -> Executor.run(executor, limit("stale-held"), context()) end)
      assert_receive {:reviewing, hook}, 5_000
      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)

      # Suspended, the executor takes the queued call and the stale :drain
      # in this order once resumed, while the held review keeps it busy.
      :ok = :sys.suspend(executor)
      ref = Process.monitor(executor)
      send(executor, {:"$gen_call", {self(), ref}, {:run, limit("stale-queued"), context()}})
      send(executor, :drain)
      :ok = :sys.resume(executor)

      assert %{busy: %{}, queue: queue} = :sys.get_state(executor)
      assert :queue.len(queue) == 1
      assert Process.alive?(executor)

      send(hook, :go)
      assert {:ok, %{status: :placed}} = Task.await(held)
      assert_receive {^ref, {:ok, %{status: :placed}}}, 5_000
      refute_received {:DOWN, ^ref, :process, _, _}

      assert Fake.calls(ctx.server, "place_") == [
               "place_equity_order",
               "place_equity_order"
             ]
    end

    test "a port gone before the place call is :failed, not_sent; a re-run places", ctx do
      executor = start_executor!(ctx, reconnect_ms: 10)
      %{port: {PortMCP, %{pid: client}}} = :sys.get_state(executor)
      test_pid = self()

      Fake.on_call(ctx.server, "review_equity_order", fn _args ->
        send(test_pid, {:reviewing, self()})

        receive do
          :go -> :answer
        end
      end)

      intent = limit("noproc")
      run = Task.async(fn -> Executor.run(executor, intent, context()) end)
      assert_receive {:reviewing, hook}, 5_000

      # The review result reaches the executor's mailbox while it is
      # suspended; the client then dies, so its EXIT queues behind the
      # result and the place call meets a dead pid.
      %{busy: %{pid: review}} = :sys.get_state(executor)
      :ok = :sys.suspend(executor)
      review_ref = Process.monitor(review)
      send(hook, :go)
      assert_receive {:DOWN, ^review_ref, :process, ^review, _}, 5_000
      client_ref = Process.monitor(client)
      Process.exit(client, :kill)
      assert_receive {:DOWN, ^client_ref, :process, ^client, _}, 5_000
      :ok = :sys.resume(executor)

      assert {:ok, %{status: :failed, response: %{"not_sent" => true}, journaled: true}} =
               Task.await(run)

      assert Fake.calls(ctx.server, "place_") == []

      Fake.on_call(ctx.server, "review_equity_order", fn _args -> :answer end)
      assert :ok = Executor.await_port(executor, 5_000)
      assert {:ok, %{status: :placed}} = Executor.run(executor, intent, context())
      assert Fake.calls(ctx.server, "place_") == ["place_equity_order"]
    end
  end
end
