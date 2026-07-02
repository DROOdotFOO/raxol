defmodule Raxol.Payments.SettlementAccountantTest do
  # async: false -- the accountant attaches a global :telemetry handler on the
  # settled event; serial runs keep one test's emit from reaching another's ledger.
  use ExUnit.Case, async: false

  alias Raxol.Payments.{SettlementAccountant, SettlementLedger}
  alias Raxol.Payments.ChainReader.Stub

  setup do
    uniq = System.unique_integer([:positive])
    ledger = start_supervised!({SettlementLedger, table_name: :"sa_ledger_#{uniq}"})

    reader =
      Stub.new(
        receipts: %{
          {1, "0xfill"} => %{
            gas_used: 45_148,
            effective_gas_price: 2_000_000_000,
            status: :success
          }
        }
      )

    accountant =
      start_supervised!(
        {SettlementAccountant,
         name: :"acct_#{uniq}", ledger: ledger, reader: reader, handler_id: "sa-test-#{uniq}"}
      )

    %{ledger: ledger, accountant: accountant}
  end

  defp emit(meta) do
    :telemetry.execute([:raxol, :payments, :xochi, :settled], %{elapsed_ms: 1000}, meta)
  end

  defp base_meta do
    %{
      intent_id: "xi_1",
      from_chain_id: 8453,
      to_chain_id: 1,
      from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      to_token: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      from_amount: "1100000",
      to_amount: "1002487",
      xochi_fee: "2205",
      tx_hash: "0xfill",
      settlement_type: :public
    }
  end

  test "books a settled event into the ledger with confirmed gas", ctx do
    emit(base_meta())
    # cast is enqueued before this call, so the record has run once :sys returns.
    _ = :sys.get_state(ctx.accountant)

    assert {:ok, entry} = SettlementLedger.get_settlement(ctx.ledger, "xi_1")
    assert entry.gas_status == :confirmed
    assert entry.to_chain_id == 1
    assert entry.token_symbol == "USDC"
    assert Decimal.equal?(entry.gas_native, Decimal.new(45_148 * 2_000_000_000))
    assert Decimal.equal?(entry.from_amount, Decimal.new("1100000"))
    assert Decimal.equal?(entry.to_amount, Decimal.new("1002487"))
    assert entry.from_symbol == "USDC"
    assert entry.to_symbol == "USDC"
  end

  test "a re-emitted intent is deduped by the ledger", ctx do
    emit(base_meta())
    emit(base_meta())
    _ = :sys.get_state(ctx.accountant)

    assert length(SettlementLedger.list_settlements(ctx.ledger)) == 1
  end
end
