defmodule Raxol.Payments.AccountingWiringTest do
  # Proves the runtime wiring the host supervisor sets up: a named SettlementLedger
  # plus a SettlementAccountant and RebalanceMonitor that reference it *by name*
  # (as Raxol.Earn.Supervisor does), interoperating end-to-end.
  use ExUnit.Case, async: false

  alias Raxol.Payments.{RebalanceMonitor, RebalancePolicy, SettlementAccountant, SettlementLedger}
  alias Raxol.Payments.ChainReader.Stub

  test "named ledger + accountant + monitor start and interoperate" do
    uniq = System.unique_integer([:positive])
    ledger_name = :"wiring_ledger_#{uniq}"
    accountant_name = :"wiring_acct_#{uniq}"

    reader =
      Stub.new(
        receipts: %{
          {1, "0xfill"} => %{
            gas_used: 21_000,
            effective_gas_price: 1_000_000_000,
            status: :success
          }
        },
        balances: %{{8453, "0xsolver"} => 0}
      )

    # Start them the way the supervisor does: the ledger registers a name, and the
    # accountant + monitor take that name (not a pid).
    start_supervised!({SettlementLedger, name: ledger_name, table_name: :"wiring_tbl_#{uniq}"})

    start_supervised!(
      {SettlementAccountant,
       name: accountant_name, ledger: ledger_name, reader: reader, handler_id: "wiring-#{uniq}"}
    )

    monitor =
      start_supervised!(
        {RebalanceMonitor,
         name: :"wiring_mon_#{uniq}",
         ledger: ledger_name,
         reader: reader,
         solver_address: "0xsolver",
         policy: RebalancePolicy.default(),
         chains: [8453],
         price_fn: fn _sym -> nil end,
         initial_delay_ms: 3_600_000}
      )

    # A settlement on the wire is booked into the named ledger.
    :telemetry.execute([:raxol, :payments, :xochi, :settled], %{elapsed_ms: 1}, %{
      intent_id: "xi_wire",
      from_chain_id: 8453,
      to_chain_id: 1,
      from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      to_token: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      from_amount: "1100000",
      to_amount: "1002487",
      xochi_fee: "2205",
      tx_hash: "0xfill",
      settlement_type: :public
    })

    _ = :sys.get_state(Process.whereis(accountant_name))

    assert {:ok, entry} = SettlementLedger.get_settlement(ledger_name, "xi_wire")
    assert entry.gas_status == :confirmed

    # The monitor reads the same named ledger's drain and produces recommendations.
    assert is_list(RebalanceMonitor.sweep_now(monitor))
  end
end
