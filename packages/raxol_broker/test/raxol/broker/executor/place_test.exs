defmodule Raxol.Broker.Executor.PlaceTest do
  @moduledoc """
  `Raxol.Broker.Executor.Place` and its receipt against
  `Raxol.Broker.Test.OrderServer` through a real port and a real journal.

  The test process impersonates the executor with
  `Raxol.Broker.Test.ExecutorIdentity` (its journal claim and receipt key):
  the deliberate-subversion path the threat model excludes, used here only
  to drive `Place.run/4` directly.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Broker.Executor.{Place, Port, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Broker.{Intent, Journal, PolicyFile}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.{ExecutorIdentity, Hostile, OrderServer}

  @moduletag :capture_log
  @t0 ~U[2026-10-02 14:30:00.000000Z]
  @account "ACC-1"
  @tool "place_equity_order"

  setup do
    base = Path.join(System.tmp_dir!(), "broker-place-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    name = :"broker_place_journal_#{System.unique_integer([:positive])}"
    path = Path.join(base, "journal")
    opts = [name: name, path: path, clock: fn -> @t0 end]
    start_supervised!(Supervisor.child_spec({Journal, opts}, restart: :temporary))
    key = :crypto.strong_rand_bytes(32)
    :ok = ExecutorIdentity.assume!(name, key: key)

    server = OrderServer.start()
    {:ok, port} = PortMCP.start(OrderServer.session(server), mode: :dry_run)

    env = %{port: port, journal: name, account: @account, timeout: 5_000}
    {:ok, server: server, port: port, env: env, journal: name, key: key, path: path}
  end

  defp records(path) do
    {base, session} = Journal.location(path)
    {:ok, records} = FileStore.read_records(session, base_dir: base)
    records
  end

  defp d(value), do: Decimal.new(value)

  defp intent(id, qty \\ "2") do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d(qty), d("125"), provenance: :strategy, id: id)
    intent
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

  defp reviewed_group(intent, journal) do
    {:ok, id} = Journal.open_group(intent, context(), journal, mode: :dry_run)
    :ok = Journal.append_to_group(id, {:verdict, :pre_review, {:allow, intent}}, journal)
    :ok = Journal.append_to_group(id, {:review, %{"warnings" => []}}, journal)
    :ok = Journal.append_to_group(id, {:verdict, :post_review, {:allow, intent}}, journal)
    id
  end

  defp call_and_classify(ctx, hook) do
    OrderServer.on_call(ctx.server, @tool, hook)
    ctx.port |> Port.call(@tool, %{}, 5_000) |> Place.classify(@tool)
  end

  describe "receipts" do
    test "a receipt verifies only for the same whole intent and group" do
      key = :crypto.strong_rand_bytes(32)
      intent = intent("int-1")
      receipt = ReviewReceipt.issue(key, intent, "g-1")

      assert ReviewReceipt.verify(receipt, key, intent, "g-1") == :ok

      assert ReviewReceipt.verify(receipt, key, intent("int-1", "3"), "g-1") ==
               {:error, :invalid_receipt}

      assert ReviewReceipt.verify(receipt, key, intent, "g-2") == {:error, :invalid_receipt}

      assert ReviewReceipt.verify(receipt, key, intent("int-2"), "g-1") ==
               {:error, :invalid_receipt}

      assert ReviewReceipt.verify(receipt, :crypto.strong_rand_bytes(32), intent, "g-1") ==
               {:error, :invalid_receipt}

      assert ReviewReceipt.verify(:forged, key, intent, "g-1") == {:error, :invalid_receipt}
    end

    test "run/4 refuses a receipt for the same id with a different quantity, sending nothing",
         ctx do
      reviewed = intent("int-qty")
      group = reviewed_group(reviewed, ctx.journal)
      receipt = ReviewReceipt.issue(ctx.key, reviewed, group)

      assert Place.run(receipt, intent("int-qty", "200"), group, ctx.env) ==
               {:error, :invalid_receipt}

      assert OrderServer.calls(ctx.server, "place_") == []
      assert Journal.placing_for_intent("int-qty", ctx.journal) == {:ok, nil}
    end
  end

  describe "receipt key" do
    test "a receipt minted under a foreign key in a plain process journals and sends nothing",
         ctx do
      intent = intent("int-foreign")
      group = reviewed_group(intent, ctx.journal)
      before = records(ctx.path)

      task =
        Task.async(fn ->
          receipt = ReviewReceipt.issue(:crypto.strong_rand_bytes(32), intent, group)
          Place.run(receipt, intent, group, ctx.env)
        end)

      assert Task.await(task) == {:error, :invalid_receipt}
      assert records(ctx.path) == before
      assert OrderServer.calls(ctx.server) == []
      assert Journal.placing_for_intent("int-foreign", ctx.journal) == {:ok, nil}
    end

    test "holding the journal claim without the executor key slot journals and sends nothing",
         ctx do
      intent = intent("int-no-slot")
      group = reviewed_group(intent, ctx.journal)
      before = records(ctx.path)

      Process.delete({Raxol.Broker.Executor, :receipt_key})
      assert Raxol.Broker.Executor.receipt_key() == nil

      for key <- [ctx.key, :crypto.strong_rand_bytes(32)] do
        receipt = ReviewReceipt.issue(key, intent, group)
        assert Place.run(receipt, intent, group, ctx.env) == {:error, :invalid_receipt}
      end

      assert records(ctx.path) == before
      assert OrderServer.calls(ctx.server) == []
      assert Journal.placing_for_intent("int-no-slot", ctx.journal) == {:ok, nil}
    end
  end

  describe "run/4" do
    test "places once with ref_id and journals the response", ctx do
      intent = intent("int-ok")
      group = reviewed_group(intent, ctx.journal)
      receipt = ReviewReceipt.issue(ctx.key, intent, group)

      assert {:ok, :placed, %{"tool" => @tool}} = Place.run(receipt, intent, group, ctx.env)
      assert [{@tool, %{"ref_id" => ref_id}}] = OrderServer.calls(ctx.server)
      assert ref_id == Place.ref_id("int-ok")

      assert {:error, _already} = Place.run(receipt, intent, group, ctx.env)
      assert OrderServer.calls(ctx.server, "place_") == [@tool]
    end

    test "an unreviewed group is refused by the journal and nothing is sent", ctx do
      intent = intent("int-unreviewed")
      {:ok, group} = Journal.open_group(intent, context(), ctx.journal, mode: :dry_run)
      receipt = ReviewReceipt.issue(ctx.key, intent, group)

      assert Place.run(receipt, intent, group, ctx.env) == {:error, {:not_reviewed, group}}
      assert OrderServer.calls(ctx.server, "place_") == []
    end
  end

  describe "classification over the real port" do
    test "a result without isError is placed", ctx do
      assert {:placed, %{"is_error" => false}} = call_and_classify(ctx, fn _ -> :answer end)
    end

    test "a result with isError is failed", ctx do
      result = %{"content" => [%{"type" => "text", "text" => "rejected"}], "isError" => true}

      assert {:failed, %{"is_error" => true}} =
               call_and_classify(ctx, fn _ -> {:result, result} end)
    end

    test "request-level JSON-RPC errors are failed", ctx do
      for code <- [-32_700, -32_600, -32_601, -32_602] do
        assert {:failed, %{"error" => %{"code" => ^code}}} =
                 call_and_classify(ctx, fn _ -> {:rpc_error, code} end)
      end
    end

    test "any other JSON-RPC error is unknown", ctx do
      for code <- [-32_603, -32_000, 500] do
        assert {:unknown, %{"error" => %{"code" => ^code}}} =
                 call_and_classify(ctx, fn _ -> {:rpc_error, code} end)
      end
    end

    test "a timeout is unknown", ctx do
      OrderServer.on_call(ctx.server, @tool, fn _ -> :hang end)

      assert {:unknown, %{"error" => ":timeout"}} =
               ctx.port |> Port.call(@tool, %{}, 1) |> Place.classify(@tool)
    end

    test "a stopped port is failed and not_sent: the call never reached a process", ctx do
      :ok = Port.stop(ctx.port)

      assert {:failed, %{"not_sent" => true, "error" => error}} =
               ctx.port |> Port.call(@tool, %{}, 5_000) |> Place.classify(@tool)

      assert error =~ "noproc"
      assert OrderServer.calls(ctx.server, "place_") == []
    end

    test "a port that dies during the call is unknown", ctx do
      Process.flag(:trap_exit, true)
      test_pid = self()

      OrderServer.on_call(ctx.server, @tool, fn _ ->
        send(test_pid, :in_call)
        :hang
      end)

      call = Task.async(fn -> Port.call(ctx.port, @tool, %{}, 5_000) end)
      assert_receive :in_call, 5_000
      {PortMCP, %PortMCP{pid: client}} = ctx.port
      Process.exit(client, :kill)

      assert {:unknown, %{"error" => error} = result} =
               call |> Task.await() |> Place.classify(@tool)

      assert error =~ "port_down" and error =~ "killed"
      refute Map.has_key?(result, "not_sent")
    end

    test "a struct in an error reason is never inspected through its protocol" do
      for reason <- [
            {:port_down, Hostile.new()},
            Hostile.new(),
            {:port_down, {:noproc, Hostile.new()}}
          ] do
        assert {_status, %{"error" => error}} = Place.classify({:error, reason}, @tool)
        assert error =~ "Raxol.Broker.Test.Hostile"
      end

      assert {:unknown, _} = Place.classify(Hostile.new(), @tool)
      refute_received {:hostile, _callback}
    end

    test "a refusal the client makes before sending is failed and not_sent", ctx do
      spec = Keyword.put(OrderServer.session(ctx.server), :prices, %{@tool => 1})
      {:ok, port} = PortMCP.start(spec, mode: :dry_run)

      assert {:failed, %{"not_sent" => true, "error" => ":unmetered_call"}} =
               port |> Port.call(@tool, %{}, 5_000) |> Place.classify(@tool)

      assert OrderServer.calls(ctx.server, "place_") == []
    end
  end
end
