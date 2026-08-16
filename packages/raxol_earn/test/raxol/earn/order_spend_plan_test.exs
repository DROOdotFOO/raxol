defmodule Raxol.Earn.OrderSpendPlanTest do
  @moduledoc """
  The spend plan `mix raxol_earn.order` prints before its first on-chain write.

  These assertions exist because the numbers were reported wrong in practice: a
  3.00 USDC run was described as moving 3.00 into escrow, when it moves ~0.0024
  (the fee) plus USDC-denominated gas, and the principal never moves in this
  task's writes at all -- it is only authorized for the solver to pull later.
  An overstatement of ~175x.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.RaxolEarn.Order

  # 3.00 USDC on Base at the default 8 bps.
  defp cfg do
    %{
      buyer: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      from: 8453,
      src_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      core: "0x238E541BfefD82238730D00a2208E5497F1832E0",
      amount: "3.00",
      principal_atomic: 3_000_000,
      fee_bps: 8
    }
  end

  defp plan(opts), do: Order.spend_plan_lines(cfg(), opts) |> Enum.join("\n")

  describe "escrow" do
    test "is the fee, not the principal" do
      text = plan(fund: true)

      # 8 bps of 3.000000 USDC = 2400 atomic = 0.0024.
      assert text =~ "0.0024"
      refute text =~ "3.00 expected"
    end

    test "scales with fee_bps" do
      lines = Order.spend_plan_lines(%{cfg() | fee_bps: 100}, fund: true) |> Enum.join("\n")
      # 100 bps of 3.000000 = 30000 atomic = 0.03.
      assert lines =~ "0.03"
    end
  end

  describe "principal" do
    test "is described as authorized, never as moved" do
      text = plan(fund: true)

      assert text =~ "principal   3.00 AUTHORIZED"
      assert text =~ "not moved here"
    end
  end

  describe "gas" do
    test "is not claimed to be sponsored or free" do
      text = plan(fund: true)

      assert text =~ "NOT in ETH"
      assert text =~ "NOT free"
      refute text =~ "sponsored"
    end
  end

  describe "legs" do
    test "a funded run names both UserOps" do
      assert plan(fund: true) =~ "UserOps this run: createJob, approve+fund"
    end

    test "an unfunded run still warns that createJob costs gas" do
      text = plan([])

      assert text =~ "UserOps this run: createJob"
      assert text =~ "no --fund: no escrow this run"
      assert text =~ "still costs USDC gas"
    end

    test "resuming an existing job drops the createJob leg" do
      assert plan(job_id: 73_295, fund: true) =~ "UserOps this run: approve+fund"
    end
  end
end
