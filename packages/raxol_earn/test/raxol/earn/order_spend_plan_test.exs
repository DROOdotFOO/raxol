defmodule Raxol.Earn.OrderSpendPlanTest do
  @moduledoc """
  The spend plan `mix raxol_earn.order` prints before its first on-chain write,
  and the receipt-derived actuals it prints after each one.

  These assertions exist because the numbers were reported wrong in practice: a
  3.00 USDC run was described as moving 3.00 into escrow, when it moves ~0.0024
  (the fee) plus USDC-denominated gas, and the principal never moves in this
  task's writes at all -- it is only authorized for the solver to pull later.
  An overstatement of ~175x.

  The accounting can misreport in its own right, so the same scrutiny applies to
  it: an unread receipt must not print as a zero, and an unplanned recipient must
  not print as routine gas.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.RaxolEarn.Order

  @core "0x238E541BfefD82238730D00a2208E5497F1832E0"
  @paymaster "0x5d74bdab1ce9ddadd7e2e333d1d173830860694a"

  # 3.00 USDC on Base at the default 8 bps.
  defp cfg do
    %{
      buyer: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      from: 8453,
      src_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      core: @core,
      amount: "3.00",
      principal_atomic: 3_000_000,
      fee_bps: 8
    }
  end

  defp plan(opts), do: Order.spend_plan_lines(cfg(), opts) |> Enum.join("\n")

  defp actual(reads),
    do: Order.spend_actual_lines(cfg(), "approve+fund", reads) |> Enum.join("\n")

  describe "escrow" do
    test "is the fee, not the principal" do
      text = plan(fund: true)

      # 8 bps of 3.000000 USDC = 2400 atomic = 0.0024.
      assert text =~ "0.0024"
      refute text =~ "3.00 expected"
    end

    test "scales with fee_bps" do
      lines = Order.spend_plan_lines(%{cfg() | fee_bps: 100}, fund: true)
      # 100 bps of 3.000000 = 30000 atomic = 0.03.
      assert Enum.join(lines, "\n") =~ "0.03"
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

    test "the funding log line does not contradict the plan" do
      line = Order.funding_line(72_993)

      refute line =~ "sponsored"
      assert line =~ "gas billed to the buyer in USDC"
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

  describe "spend actual" do
    test "a read receipt with no buyer transfers is a definite zero" do
      text = actual([{"0xaaa", {:ok, []}}])

      assert text =~ "no USDC left the buyer"
      refute text =~ "LOWER BOUND"
      refute text =~ "not yet available"
    end

    test "read receipts total authoritatively" do
      text = actual([{"0xaaa", {:ok, [{@core, 2_400}]}}, {"0xbbb", {:ok, [{@paymaster, 7_500}]}}])

      # 2400 + 7500 = 9900 atomic = 0.0099.
      assert text =~ "0.0099 USDC left the buyer"
      refute text =~ "LOWER BOUND"
    end

    test "an unread receipt makes the total a lower bound, and names the hash" do
      text =
        actual([
          {"0xaaa", {:ok, [{@core, 2_400}]}},
          {"0xbbb", {:error, {:transport, {:http_status, 429, ""}}}}
        ])

      assert text =~ "at least 0.0024 USDC left the buyer -- LOWER BOUND"
      assert text =~ "1 receipt(s) unread"
      assert text =~ "UNREAD receipt 0xbbb"
      assert text =~ "http_status, 429"
      assert text =~ "https://basescan.org/tx/0xbbb"
    end

    test "a wholly unread read is a lower bound of zero, never a reported zero" do
      text = actual([{"0xbbb", {:error, :timeout}}])

      assert text =~ "LOWER BOUND"
      assert text =~ "UNREAD receipt 0xbbb"
      refute text =~ "no USDC left the buyer"
    end
  end

  describe "destination notes" do
    test "the ACP Core is the fee escrow" do
      assert actual([{"0xaaa", {:ok, [{@core, 2_400}]}}]) =~ "(ACP Core -- the fee escrow)"
    end

    test "the known paymaster is gas" do
      assert actual([{"0xaaa", {:ok, [{@paymaster, 7_500}]}}]) =~ "(gas: ERC-20 paymaster)"
    end

    test "any other recipient is flagged unexpected, not explained away as gas" do
      text =
        actual([{"0xaaa", {:ok, [{"0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef", 3_000_000}]}}])

      assert text =~ "(UNEXPECTED recipient -- neither the fee escrow nor the known paymaster)"
      refute text =~ "gas: ERC-20 paymaster"
    end
  end
end
