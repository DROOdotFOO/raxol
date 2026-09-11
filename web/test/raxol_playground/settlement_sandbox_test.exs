defmodule RaxolPlayground.SettlementSandboxTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}
  alias Raxol.Payments.{Failure, Ledger}
  alias RaxolPlayground.SettlementSandbox

  test "runs a fund-free settlement through the production action boundary" do
    assert {:ok, run} = SettlementSandbox.start()

    assert {:ok, intent} = ExecuteXochiIntent.call(run.payment, run.context)
    assert intent.intent_id == "demo_intent_4812"
    assert intent.status == "executing"
    assert intent.from_amount == "25000000"
    assert intent.to_amount == "24952500"
    assert SettlementSandbox.Wallet.signatures() == 1
    assert intent.xochi_fee == "47500"

    assert {:ok, receipt} =
             PollXochiStatus.call(%{intent_id: intent.intent_id}, run.context)

    assert receipt.status == "completed"
    assert receipt.settlement_type == "stealth"

    totals =
      Ledger.get_totals(
        run.context.ledger,
        run.context.agent_id,
        run.context.policy
      )

    assert Decimal.equal?(totals.session, Decimal.new("25.00"))

    assert {:error, %Failure{reason: :over_budget, retryable?: false} = denied} =
             ExecuteXochiIntent.call(
               %{run.payment | amount: "75.00"},
               run.context
             )

    assert SettlementSandbox.Wallet.signatures() == 1

    unchanged =
      Ledger.get_totals(
        run.context.ledger,
        run.context.agent_id,
        run.context.policy
      )

    assert Decimal.equal?(unchanged.session, Decimal.new("25.00"))

    lines =
      SettlementSandbox.lines(%{
        demo: run,
        intent: intent,
        receipt: receipt,
        denied: denied,
        safe?: true,
        t: 4
      })

    assert "XOCHI SANDBOX REPLAY · NO FUNDS" in lines

    assert Enum.any?(
             lines,
             &(&1 =~ "Base → Arbitrum One · 25.00 USDC · stealth")
           )

    assert Enum.any?(lines, &(&1 =~ "fee 0.0475 USDC (19 bps)"))
    assert Enum.any?(lines, &(&1 =~ "24.9525 USDC · demo_intent_4812"))
    assert Enum.any?(lines, &(&1 =~ "75.00 denied · no signature"))
    refute Enum.any?(lines, &(&1 =~ "ERROR"))
  end
end
