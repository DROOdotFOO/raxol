defmodule Raxol.Payments.RebalanceMonitorTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.{RebalanceMonitor, RebalancePolicy, SettlementLedger}
  alias Raxol.Payments.ChainReader.Stub

  defp policy do
    %RebalancePolicy{
      gas_floor: %{8453 => Decimal.new("0.01")},
      gas_target: %{8453 => Decimal.new("0.05")},
      inventory_floor: %{},
      inventory_target: %{}
    }
  end

  defp eth_price do
    fn
      "ETH" -> Decimal.new("2000")
      _ -> nil
    end
  end

  setup do
    ledger =
      start_supervised!(
        {SettlementLedger, table_name: :"rm_#{System.unique_integer([:positive])}"}
      )

    %{ledger: ledger}
  end

  test "advise_once recommends a gas refuel from a below-floor native balance", %{ledger: ledger} do
    # 0.005 ETH on Base, floor 0.01.
    reader = Stub.new(balances: %{{8453, "0xsolver"} => 5_000_000_000_000_000})

    recs =
      RebalanceMonitor.advise_once(
        ledger: ledger,
        reader: reader,
        solver_address: "0xsolver",
        policy: policy(),
        chains: [8453],
        price_fn: eth_price()
      )

    # Phase 1 gathers native balances only, so USDC funding is unknown
    # (:insufficient_usdc) -- the refuel is still recommended and correctly sized.
    assert [{:refuel_gas, r}] = recs
    assert r.chain_id == 8453
    assert Decimal.equal?(r.native_to_buy, Decimal.new("0.045"))
  end

  test "sweep_now runs a cycle and returns recommendations without auto-firing", %{ledger: ledger} do
    reader = Stub.new(balances: %{{8453, "0xsolver"} => 0})

    monitor =
      start_supervised!({
        RebalanceMonitor,
        # Push the periodic sweep far out so only sweep_now runs during the test.
        name: :"mon_#{System.unique_integer([:positive])}",
        ledger: ledger,
        reader: reader,
        solver_address: "0xsolver",
        policy: policy(),
        chains: [8453],
        price_fn: eth_price(),
        initial_delay_ms: 3_600_000
      })

    assert [{:refuel_gas, %{chain_id: 8453}}] = RebalanceMonitor.sweep_now(monitor)
  end
end
