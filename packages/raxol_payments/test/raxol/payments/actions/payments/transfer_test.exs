defmodule Raxol.Payments.Actions.Payments.TransferTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.Transfer
  alias Raxol.Payments.{Ledger, SpendingPolicy}

  defmodule StubWallet do
    @moduledoc false
    def address, do: "0xagentwallet"
  end

  defp start_ledger, do: start_supervised!({Ledger, [name: nil]})

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("5.00"),
      lifetime_max: Decimal.new("10.00"),
      session_window_ms: 3_600_000,
      approved_domains: nil
    }
  end

  test "missing wallet errors" do
    assert {:error, :missing_wallet} =
             Transfer.run(%{to: "0xabc", amount: "0.10"}, %{})
  end

  test "authorizes through the choke point and reserves budget atomically" do
    ledger = start_ledger()

    ctx = %{wallet: StubWallet, ledger: ledger, policy: policy(), agent_id: "a1"}

    assert {:ok, %{status: "pending", to: "0xabc", amount: "0.50"}} =
             Transfer.run(%{to: "0xabc", amount: "0.50"}, ctx)

    totals = Ledger.get_totals(ledger, "a1", policy())
    assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
  end

  test "over per_request limit is denied and nothing is recorded" do
    ledger = start_ledger()
    ctx = %{wallet: StubWallet, ledger: ledger, policy: policy(), agent_id: "a1"}

    assert {:error, {:over_budget, :per_request}} =
             Transfer.run(%{to: "0xabc", amount: "2.00"}, ctx)

    totals = Ledger.get_totals(ledger, "a1", policy())
    assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
  end

  test "confirmation threshold denies without on_confirm" do
    ledger = start_ledger()
    pol = %{policy() | require_confirmation_above: Decimal.new("0.10")}
    ctx = %{wallet: StubWallet, ledger: ledger, policy: pol, agent_id: "a1"}

    assert {:error, {:requires_confirmation, _}} =
             Transfer.run(%{to: "0xabc", amount: "0.50"}, ctx)
  end
end
