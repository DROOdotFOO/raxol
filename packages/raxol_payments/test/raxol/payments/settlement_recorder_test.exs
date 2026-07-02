defmodule Raxol.Payments.SettlementRecorderTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.{SettlementLedger, SettlementRecorder}
  alias Raxol.Payments.ChainReader.Stub

  setup do
    table = String.to_atom("slr_#{System.unique_integer([:positive])}")
    ledger = start_supervised!({SettlementLedger, table_name: table})
    %{ledger: ledger}
  end

  test "public fill with a mined receipt records confirmed gas", %{ledger: ledger} do
    reader =
      Stub.new(
        receipts: %{
          {1, "0xabc"} => %{
            gas_used: 45_148,
            effective_gas_price: 2_384_942_069,
            status: :success
          }
        }
      )

    input = %{
      intent_id: "xi_1",
      from_chain_id: 8453,
      to_chain_id: 1,
      token_symbol: "USDC",
      token_address: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      fee_collected: "2205",
      tx_hash: "0xabc",
      settlement_type: :public
    }

    assert {:ok, :recorded} = SettlementRecorder.record(ledger, reader, input)
    {:ok, entry} = SettlementLedger.get_settlement(ledger, "xi_1")

    assert entry.gas_status == :confirmed
    assert Decimal.equal?(entry.gas_native, Decimal.new(45_148 * 2_384_942_069))
    assert entry.fee_currency == "USDC"
    assert entry.fee_decimals == 6
    assert entry.gas_symbol == "ETH"
  end

  test "shielded settlement records no public gas", %{ledger: ledger} do
    input = %{
      intent_id: "xi_s",
      from_chain_id: 8453,
      to_chain_id: 1,
      token_symbol: "USDC",
      fee_collected: "2000",
      tx_hash: nil,
      settlement_type: :shielded
    }

    assert {:ok, :recorded} = SettlementRecorder.record(ledger, Stub.new(), input)
    {:ok, entry} = SettlementLedger.get_settlement(ledger, "xi_s")
    assert entry.gas_native == nil
    assert entry.gas_status == :no_public_tx
  end

  test "a not-yet-mined receipt errors by default, records :pending on request",
       %{ledger: ledger} do
    reader = Stub.new(receipts: %{{1, "0xpend"} => :pending})

    input = %{
      intent_id: "xi_p",
      from_chain_id: 8453,
      to_chain_id: 1,
      token_symbol: "USDC",
      fee_collected: "2000",
      tx_hash: "0xpend",
      settlement_type: :public
    }

    assert {:error, :receipt_pending} = SettlementRecorder.record(ledger, reader, input)

    assert {:ok, :recorded} =
             SettlementRecorder.record(ledger, reader, input, record_pending: true)

    {:ok, entry} = SettlementLedger.get_settlement(ledger, "xi_p")
    assert entry.gas_status == :pending
    assert entry.gas_native == nil
  end

  test "missing tx_hash records with no_public_tx", %{ledger: ledger} do
    input = %{
      intent_id: "xi_n",
      from_chain_id: 8453,
      to_chain_id: 1,
      token_symbol: "USDC",
      fee_collected: "2000",
      tx_hash: nil,
      settlement_type: :public
    }

    assert {:ok, :recorded} = SettlementRecorder.record(ledger, Stub.new(), input)
    {:ok, entry} = SettlementLedger.get_settlement(ledger, "xi_n")
    assert entry.gas_status == :no_public_tx
  end

  test "a non-USDC fee token resolves 18 decimals from the contract", %{ledger: ledger} do
    weth = "0x4200000000000000000000000000000000000006"

    reader =
      Stub.new(
        receipts: %{
          {10, "0xweth"} => %{
            gas_used: 50_000,
            effective_gas_price: 1_000_000_000,
            status: :success
          }
        }
      )

    input = %{
      intent_id: "xi_w",
      from_chain_id: 10,
      to_chain_id: 10,
      token_symbol: "WETH",
      token_address: weth,
      fee_collected: "1000000000000000",
      tx_hash: "0xweth",
      settlement_type: :public
    }

    assert {:ok, :recorded} = SettlementRecorder.record(ledger, reader, input)
    {:ok, entry} = SettlementLedger.get_settlement(ledger, "xi_w")
    assert entry.fee_currency == "WETH"
    assert entry.fee_decimals == 18
  end

  test "re-recording the same intent is a duplicate", %{ledger: ledger} do
    reader =
      Stub.new(
        receipts: %{{1, "0xabc"} => %{gas_used: 1, effective_gas_price: 1, status: :success}}
      )

    input = %{
      intent_id: "xi_d",
      from_chain_id: 8453,
      to_chain_id: 1,
      fee_collected: "1",
      tx_hash: "0xabc",
      settlement_type: :public
    }

    assert {:ok, :recorded} = SettlementRecorder.record(ledger, reader, input)
    assert {:ok, :duplicate} = SettlementRecorder.record(ledger, reader, input)
  end
end
