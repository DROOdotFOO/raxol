defmodule Raxol.Payments.SettlementLedgerTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.SettlementLedger

  setup do
    table = String.to_atom("sl_#{System.unique_integer([:positive])}")
    ledger = start_supervised!({SettlementLedger, table_name: table})
    %{ledger: ledger}
  end

  # A real Base -> Ethereum-L1 USDC fill: 2205 atomic USDC fee against the on-chain
  # gas the mainnet fill burned (45148 gas * ~2.38 gwei).
  defp l1_fill(overrides \\ %{}) do
    Map.merge(
      %{
        intent_id: "xi_1",
        from_chain_id: 8453,
        to_chain_id: 1,
        token_symbol: "USDC",
        fee_collected: "2205",
        fee_currency: "USDC",
        fee_decimals: 6,
        gas_native: 107_675_364_531_212,
        gas_chain_id: 1,
        gas_symbol: "ETH",
        gas_status: :confirmed,
        tx_hash: "0xabc",
        settlement_type: :public
      },
      overrides
    )
  end

  test "records a settlement and is idempotent by intent_id", %{ledger: ledger} do
    assert {:ok, :recorded} = SettlementLedger.record_settlement(ledger, l1_fill())
    assert {:ok, :duplicate} = SettlementLedger.record_settlement(ledger, l1_fill())
    assert length(SettlementLedger.list_settlements(ledger)) == 1
  end

  test "emits a settlement event on record, never on a duplicate", %{ledger: ledger} do
    test_pid = self()
    handler = "sl-tele-#{System.unique_integer([:positive])}"
    # The event is global, so filter by this test's own intent id -- otherwise a
    # concurrent test's settlement would trip the refute_receive below.
    iid = "xi_tele_#{System.unique_integer([:positive])}"
    fill = l1_fill(%{intent_id: iid})

    :telemetry.attach(
      handler,
      [:raxol, :payments, :settlement],
      fn
        _event, meas, %{intent_id: ^iid} = meta, _cfg -> send(test_pid, {:settlement, meas, meta})
        _event, _meas, _meta, _cfg -> :ok
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, :recorded} = SettlementLedger.record_settlement(ledger, fill)
    assert_receive {:settlement, meas, meta}
    assert meta.to_chain_id == 1
    assert Decimal.equal?(meas.fee_atomic, Decimal.new("2205"))

    assert {:ok, :duplicate} = SettlementLedger.record_settlement(ledger, fill)
    refute_receive {:settlement, _, _}
  end

  test "margin_by_destination computes a negative USD margin for a priced L1 loss",
       %{ledger: ledger} do
    SettlementLedger.record_settlement(ledger, l1_fill())

    price_fn = fn
      "ETH" -> Decimal.new("1700")
      _ -> nil
    end

    agg = SettlementLedger.margin_by_destination(ledger, price_fn: price_fn)[1]

    # fee 0.002205 USDC vs gas 0.000107675 ETH * 1700 ~= $0.183 -> margin < 0
    assert Decimal.compare(agg.usd_margin, 0) == :lt
    assert agg.count == 1
    assert agg.gas_unknown_count == 0
  end

  test "without a gas price, usd_gas and usd_margin stay nil but raw totals hold",
       %{ledger: ledger} do
    SettlementLedger.record_settlement(ledger, l1_fill())
    agg = SettlementLedger.cumulative_subsidy(ledger)

    # Stablecoin fee is valued at $1 by default, so usd_fee is known; gas needs a
    # price_fn (absent here), so usd_gas -- and therefore usd_margin -- stay nil.
    assert Decimal.equal?(agg.usd_fee, Decimal.new("0.002205"))
    assert agg.usd_gas == nil
    assert agg.usd_margin == nil
    assert Decimal.equal?(agg.fee_by_currency["USDC"], Decimal.new("2205"))
    assert Decimal.equal?(agg.gas_by_chain[1], Decimal.new(107_675_364_531_212))
  end

  test "amend_gas backfills only when gas_native is nil", %{ledger: ledger} do
    SettlementLedger.record_settlement(ledger, l1_fill(%{gas_native: nil, gas_status: :pending}))

    assert {:ok, :amended} = SettlementLedger.amend_gas(ledger, "xi_1", 100)
    assert {:ok, :noop} = SettlementLedger.amend_gas(ledger, "xi_1", 200)
    assert :error = SettlementLedger.amend_gas(ledger, "missing", 1)

    {:ok, entry} = SettlementLedger.get_settlement(ledger, "xi_1")
    assert Decimal.equal?(entry.gas_native, Decimal.new(100))
    assert entry.gas_status == :confirmed
  end

  test "usd_revenue is the delivered spread and drives the margin", %{ledger: ledger} do
    # Pulled 1.10 USDC on origin, delivered 1.002487 on Ethereum: solver spread
    # ~0.0975 USDC against ~$0.183 of L1 gas -> a loss.
    SettlementLedger.record_settlement(
      ledger,
      l1_fill(%{
        from_amount: "1100000",
        from_symbol: "USDC",
        from_decimals: 6,
        to_amount: "1002487",
        to_symbol: "USDC",
        to_decimals: 6
      })
    )

    price_fn = fn
      "ETH" -> Decimal.new("1700")
      _ -> nil
    end

    agg = SettlementLedger.margin_by_destination(ledger, price_fn: price_fn)[1]

    assert Decimal.equal?(agg.usd_revenue, Decimal.new("0.097513"))
    assert Decimal.compare(agg.usd_margin, 0) == :lt
  end

  test "native_drain_by_chain sums wei per destination chain", %{ledger: ledger} do
    SettlementLedger.record_settlement(ledger, l1_fill())
    SettlementLedger.record_settlement(ledger, l1_fill(%{intent_id: "xi_2"}))

    drain = SettlementLedger.native_drain_by_chain(ledger)
    assert Decimal.equal?(drain[1], Decimal.new(2 * 107_675_364_531_212))
  end

  test "list_settlements filters by corridor", %{ledger: ledger} do
    SettlementLedger.record_settlement(ledger, l1_fill())
    SettlementLedger.record_settlement(ledger, l1_fill(%{intent_id: "xi_2", to_chain_id: 137}))

    assert [%{intent_id: "xi_1"}] = SettlementLedger.list_settlements(ledger, to_chain_id: 1)
  end

  describe "demand_by_destination/2" do
    defp fill(id, to_chain, symbol, amount) do
      %{
        intent_id: id,
        from_chain_id: 8453,
        to_chain_id: to_chain,
        token_symbol: symbol,
        fee_collected: "100",
        fee_currency: symbol,
        fee_decimals: 6,
        to_amount: Decimal.new(amount),
        to_symbol: symbol,
        to_decimals: 6,
        gas_status: :confirmed
      }
    end

    test "totals and peaks outflow per destination chain and symbol", %{ledger: ledger} do
      for f <- [
            fill("d1", 42_161, "USDC", "100"),
            fill("d2", 42_161, "USDC", "500"),
            fill("d3", 42_161, "USDT", "20"),
            fill("d4", 1, "USDC", "7")
          ] do
        assert {:ok, :recorded} = SettlementLedger.record_settlement(ledger, f)
      end

      demand = SettlementLedger.demand_by_destination(ledger)

      arb_usdc = demand[42_161]["USDC"]
      assert Decimal.equal?(arb_usdc.total, Decimal.new("600"))
      # The peak is what sizes a floor: one $500 order, not the $600 of throughput.
      assert Decimal.equal?(arb_usdc.peak, Decimal.new("500"))
      assert arb_usdc.count == 2

      assert Decimal.equal?(demand[42_161]["USDT"].peak, Decimal.new("20"))
      assert Decimal.equal?(demand[1]["USDC"].peak, Decimal.new("7"))
    end

    test "a fill that cannot be attributed to a corridor is skipped", %{ledger: ledger} do
      # No to_amount/to_symbol: it is evidence about nothing.
      assert {:ok, :recorded} = SettlementLedger.record_settlement(ledger, l1_fill())

      assert SettlementLedger.demand_by_destination(ledger) == %{}
    end

    test "honours the :since_ms window", %{ledger: ledger} do
      assert {:ok, :recorded} =
               SettlementLedger.record_settlement(
                 ledger,
                 Map.put(fill("old", 42_161, "USDC", "900"), :timestamp_ms, 1_000)
               )

      assert {:ok, :recorded} =
               SettlementLedger.record_settlement(
                 ledger,
                 Map.put(fill("new", 42_161, "USDC", "10"), :timestamp_ms, 9_000)
               )

      recent = SettlementLedger.demand_by_destination(ledger, since_ms: 5_000)

      # The $900 order is outside the window, so it no longer sizes the floor.
      assert Decimal.equal?(recent[42_161]["USDC"].peak, Decimal.new("10"))
      assert recent[42_161]["USDC"].count == 1
    end
  end
end
