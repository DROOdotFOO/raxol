defmodule Raxol.Payments.Actions.Payments.PollXochiStatusTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.PollXochiStatus
  alias Raxol.Payments.{Checkpoint, Failure, Ledger, SpendingPolicy}
  alias Raxol.Payments.Xochi.ReadTokenStore

  defp config do
    %{
      base_url: "https://xochi.test",
      auth_token: "t",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("10.00"),
      session_max: Decimal.new("100.00"),
      lifetime_max: Decimal.new("1000.00"),
      session_window_ms: 3_600_000
    }
  end

  test "Failure.from classifies a stranded intent as retryable with the id in detail" do
    assert %Failure{reason: :stranded, retryable?: true, detail: {:stranded, "int_9"}} =
             Failure.from({:stranded, "int_9"})
  end

  test "a poll that never reaches terminal returns :stranded and signals for reconcile" do
    # The intent stays non-terminal, so the poll gives up at the deadline. The
    # origin funds may already have moved, so this is a stranded intent, not a
    # clean failure.
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"intentId" => "int_x", "status" => "executing", "terminal" => false})
    end)

    handler_id = "stranded-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:raxol, :payments, :xochi, :intent_stranded],
      fn _e, _m, meta, _ -> send(test_pid, {:stranded, meta}) end,
      nil
    )

    try do
      params = %{intent_id: "int_x", timeout_ms: 40, interval_ms: 10}

      assert {:error, %Failure{reason: :stranded, retryable?: true}} =
               PollXochiStatus.run(params, %{xochi_config: config()})

      # The id rides the telemetry so operator tooling can reconcile THIS intent.
      assert_received {:stranded, %{intent_id: "int_x"}}
    after
      :telemetry.detach(handler_id)
    end
  end

  test "a refunded terminal status surfaces as a :refunded failure carrying the reason" do
    # The worker reports the intent refunded and terminal, with a refundReason.
    # The poll must stop (refunded is terminal), fail (not {:ok, ...}), and carry
    # the reason so the agent sees why the funds came back.
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{
        "intent_id" => "int_r",
        "status" => "refunded",
        "terminal" => true,
        "refundReason" => "solver timeout"
      })
    end)

    params = %{intent_id: "int_r", timeout_ms: 40, interval_ms: 10}

    assert {:error, %Failure{reason: :refunded, retryable?: false, detail: "solver timeout"}} =
             PollXochiStatus.run(params, %{xochi_config: config()})
  end

  test "a refunded status without a refundReason still surfaces as :refunded" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"intent_id" => "int_r2", "status" => "refunded", "terminal" => true})
    end)

    params = %{intent_id: "int_r2", timeout_ms: 40, interval_ms: 10}

    assert {:error, %Failure{reason: :refunded} = failure} =
             PollXochiStatus.run(params, %{xochi_config: config()})

    assert to_string(failure) == "The transfer failed and the funds were refunded."
  end

  test "a refunded poll releases the execute-time reservation, idempotently" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"intent_id" => "int_r3", "status" => "refunded", "terminal" => true})
    end)

    {:ok, ledger} = Ledger.start_link(table_name: :"poll_refund_#{:erlang.unique_integer()}")
    ctx = %{xochi_config: config(), ledger: ledger, agent_id: "agent_1"}

    # Mirror the execute path: reserve budget and tag it with the intent id.
    :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("1.00"), policy(), %{})
    :ok = Ledger.tag_reservation(ledger, "agent_1", "int_r3", Decimal.new("1.00"))
    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "1.00")

    params = %{intent_id: "int_r3", timeout_ms: 40, interval_ms: 10}

    assert {:error, %Failure{reason: :refunded}} = PollXochiStatus.run(params, ctx)
    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "0")

    # Re-polling the same refunded intent must not release a second time.
    assert {:error, %Failure{reason: :refunded}} = PollXochiStatus.run(params, ctx)
    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "0")
  end

  test "a completed poll keeps the spend and forgets the tag" do
    Req.Test.stub(__MODULE__, fn conn ->
      Req.Test.json(conn, %{"intent_id" => "int_c", "status" => "completed", "terminal" => true})
    end)

    {:ok, ledger} = Ledger.start_link(table_name: :"poll_done_#{:erlang.unique_integer()}")
    ctx = %{xochi_config: config(), ledger: ledger, agent_id: "agent_1"}

    :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("1.00"), policy(), %{})
    :ok = Ledger.tag_reservation(ledger, "agent_1", "int_c", Decimal.new("1.00"))

    params = %{intent_id: "int_c", timeout_ms: 40, interval_ms: 10}

    assert {:ok, %{status: "completed"}} = PollXochiStatus.run(params, ctx)
    # The spend stands; the tag is forgotten so a later stray release is a no-op.
    assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "1.00")
    assert :noop = Ledger.release_by_intent(ledger, "agent_1", "int_c")
  end

  # xochi#563: the worker withholds a stealth intent's legs unless the caller
  # presents the read token execute returned. The sim reveals `tx_hash` only
  # for the right token, as the worker does.
  describe "read_token" do
    @token "CCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC"
    @other "DDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD"

    # Owner view for the right token; otherwise the worker's anonymous view of
    # a private settlement: status-only, `legs_withheld`, `settlement_confirmed`.
    defp stub_private(test_pid, status) do
      Req.Test.stub(__MODULE__, fn conn ->
        presented = Plug.Conn.get_req_header(conn, "x-xochi-read-token")
        send(test_pid, {:presented, presented})
        base = %{"intent_id" => "int_s", "status" => status, "settlement_type" => "stealth"}

        body =
          if presented == [@token],
            do:
              Map.merge(base, %{
                "tx_hash" => "0x" <> String.duplicate("c", 64),
                "receiving_tx_hash" => "0x" <> String.duplicate("d", 64),
                "settlement_tx_hash" => "0x" <> String.duplicate("d", 64),
                "settlement_chain_id" => 10
              }),
            else: Map.merge(base, %{"settlement_confirmed" => true, "legs_withheld" => true})

        Req.Test.json(conn, body)
      end)
    end

    setup do
      stub_private(self(), "completed")
      :ok
    end

    test "the token is loaded from private checkpoint state and reveals the settlement tx" do
      store = Checkpoint.ETS.new()
      ReadTokenStore.put(store, config().base_url, "int_s", @token)
      params = %{intent_id: "int_s", timeout_ms: 40, interval_ms: 10}

      assert {:ok, summary} =
               PollXochiStatus.run(params, %{xochi_config: config(), checkpoint: store})

      # Every owner-view leg is in the result before the token is dropped.
      assert %{
               status: "completed",
               tx_hash: "0x" <> _,
               receiving_tx_hash: "0x" <> _,
               settlement_tx_hash: "0x" <> _,
               settlement_chain_id: 10,
               settlement_confirmed: true,
               legs_withheld: false
             } = summary

      assert_received {:presented, [@token]}
      assert ReadTokenStore.fetch(store, config().base_url, "int_s") == nil
    end

    test "without a token no header is sent and the status still resolves" do
      params = %{intent_id: "int_s", timeout_ms: 40, interval_ms: 10}

      assert {:ok,
              %{
                status: "completed",
                settlement_type: "stealth",
                tx_hash: nil,
                legs_withheld: true,
                settlement_confirmed: true
              }} = PollXochiStatus.run(params, %{xochi_config: config()})

      assert_received {:presented, []}
    end

    test "an anonymous terminal answer keeps the token for a later owner-view poll" do
      store = Checkpoint.ETS.new()
      ReadTokenStore.put(store, config().base_url, "int_s", @other)
      params = %{intent_id: "int_s", timeout_ms: 40, interval_ms: 10}

      assert {:ok, %{legs_withheld: true, tx_hash: nil}} =
               PollXochiStatus.run(params, %{xochi_config: config(), checkpoint: store})

      assert ReadTokenStore.fetch(store, config().base_url, "int_s") == @other
    end

    test "a failed status keeps the token, since the error carries none of its legs" do
      stub_private(self(), "failed")
      store = Checkpoint.ETS.new()
      ReadTokenStore.put(store, config().base_url, "int_s", @token)
      params = %{intent_id: "int_s", timeout_ms: 40, interval_ms: 10}

      assert {:error, %Failure{}} =
               PollXochiStatus.run(params, %{xochi_config: config(), checkpoint: store})

      assert ReadTokenStore.fetch(store, config().base_url, "int_s") == @token
    end

    test "a token stored for another API origin is never presented" do
      store = Checkpoint.ETS.new()
      ReadTokenStore.put(store, "https://other.test", "int_s", @token)
      params = %{intent_id: "int_s", timeout_ms: 40, interval_ms: 10}

      assert {:ok, %{tx_hash: nil}} =
               PollXochiStatus.run(params, %{xochi_config: config(), checkpoint: store})

      assert_received {:presented, []}
      assert ReadTokenStore.fetch(store, "https://other.test", "int_s") == @token
    end
  end

  describe "a confirmed private fill that is not yet terminal" do
    setup do
      handler_id = "confirmed-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :payments, :xochi, :intent_stranded],
        fn _e, _m, meta, _ -> send(test_pid, {:stranded, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
    end

    test "is reported as confirmed and non-terminal, not stranded, and releases nothing" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intent_id" => "int_p",
          "status" => "settling",
          "terminal" => false,
          "settlement_type" => "shielded",
          "settlement_confirmed" => true,
          "legs_withheld" => true
        })
      end)

      {:ok, ledger} = Ledger.start_link(table_name: :"poll_confirmed_#{:erlang.unique_integer()}")
      ctx = %{xochi_config: config(), ledger: ledger, agent_id: "agent_1"}
      :ok = Ledger.try_spend(ledger, "agent_1", Decimal.new("1.00"), policy(), %{})
      :ok = Ledger.tag_reservation(ledger, "agent_1", "int_p", Decimal.new("1.00"))

      params = %{intent_id: "int_p", timeout_ms: 40, interval_ms: 10}

      assert {:ok,
              %{
                status: "settling",
                terminal: false,
                settlement_confirmed: true,
                legs_withheld: true
              }} = PollXochiStatus.run(params, ctx)

      refute_received {:stranded, _}
      # The reservation is neither released nor forgotten.
      assert Decimal.equal?(Ledger.get_totals(ledger, "agent_1", policy()).lifetime, "1.00")
      assert :released = Ledger.release_by_intent(ledger, "agent_1", "int_p")
    end

    test "an unconfirmed private fill is stranded, and the report says the legs were withheld" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intent_id" => "int_u",
          "status" => "settling",
          "terminal" => false,
          "settlement_confirmed" => false,
          "legs_withheld" => true
        })
      end)

      params = %{intent_id: "int_u", timeout_ms: 40, interval_ms: 10}

      assert {:error, %Failure{reason: :stranded}} =
               PollXochiStatus.run(params, %{xochi_config: config()})

      assert_received {:stranded,
                       %{
                         intent_id: "int_u",
                         status: "settling",
                         settlement_confirmed: false,
                         legs_withheld: true
                       }}
    end
  end
end
