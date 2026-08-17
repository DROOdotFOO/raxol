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
  it: an unread receipt must not print as a zero, an unplanned recipient must not
  print as routine gas, and a resumed job's escrow must not be invented from
  flags that job never saw.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.RaxolEarn.Order

  @core "0x238E541BfefD82238730D00a2208E5497F1832E0"
  @paymaster "0x5d74bdab1ce9ddadd7e2e333d1d173830860694a"

  @spender "0xE9B020941015e428876f60C1979B3fc2A38a2f53"

  # 3.00 USDC on Base at the default 8 bps, under the default managed-SCA signer.
  defp cfg do
    %{
      buyer: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      from: 8453,
      src_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      core: @core,
      amount: "3.00",
      principal_atomic: 3_000_000,
      fee_bps: 8,
      signer: "privy",
      solver: nil
    }
  end

  defp plan(opts, escrow \\ :new_job),
    do: Order.spend_plan_lines(cfg(), opts, escrow) |> Enum.join("\n")

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
      lines = Order.spend_plan_lines(%{cfg() | fee_bps: 100}, [fund: true], :new_job)
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

    test "an EOA run says ETH, since no paymaster bills it USDC" do
      lines = Order.spend_plan_lines(%{cfg() | signer: "eoa"}, [fund: true], :new_job)
      text = Enum.join(lines, "\n")

      assert text =~ "paid in ETH by the buyer EOA"
      assert text =~ "NOT in USDC"
      # An EOA broadcasts plain transactions; calling them UserOps sends the
      # operator looking for a paymaster charge that never appears.
      refute text =~ "UserOp"
    end

    test "the funding log line does not contradict the plan" do
      line = Order.funding_line(72_993, :not_needed)

      refute line =~ "sponsored"
      assert line =~ "gas billed to the buyer in USDC"
    end
  end

  describe "legs" do
    test "a funded run names every write, the carried approve included" do
      assert plan(fund: true) =~
               "writes this run: createJob, approve+fund " <>
                 "(carrying the approve(Permit2) if the pull needs it)"
    end

    test "an unfunded run still warns that createJob costs gas" do
      text = plan([])

      assert text =~ "writes this run: createJob"
      assert text =~ "no --fund: no escrow this run"
      assert text =~ "still costs gas"
    end

    test "resuming an existing job drops the createJob leg" do
      assert plan([job_id: 73_295, fund: true], {:ok, 2_400}) =~
               "writes this run: approve+fund (carrying the approve(Permit2) if the pull needs it)"
    end

    test "a resumed unfunded run claims no writes, because it can make none" do
      text = plan([job_id: 73_295], {:ok, 2_400})

      # The approve now rides in the funding batch, so without --fund and without
      # createJob there is nothing left to broadcast. Naming the approve as a leg
      # here would promise a write this run cannot make.
      assert text =~ "writes this run: none (without --fund and without createJob"
      assert text =~ "this run signs an intent and broadcasts nothing"
      assert text =~ "stays unexecutable"
    end

    test "a dry run names no writes at all" do
      text = plan(dry_run: true, fund: true)

      assert text =~ "SPEND PLAN"
      assert text =~ "writes this run: none (--dry-run writes nothing on-chain)"
      assert text =~ "spends nothing"
    end
  end

  describe "the Permit2 approve" do
    test "is named as riding inside the funding write, not as one of its own" do
      text = plan(fund: true)

      assert text =~ "rides INSIDE the approve+fund UserOp"
      assert text =~ "no separate write, no extra gas"
      assert text =~ "the buyer's allowance is short"
    end

    test "is disclosed as bounded, not as a standing max approval" do
      text = plan(fund: true)

      assert text =~ "approves exactly the intent's authorized pull, not a standing max"
    end

    test "an unfunded run says the allowance is not granted, and what that costs" do
      text = plan([])

      # --fund is what carries the approve, so without it a signed Permit2 intent
      # is left with a pull that cannot execute. Saying nothing here is how that
      # surfaces later as an unexplained settlement failure.
      assert text =~ "no approve(Permit2) UserOp without --fund"
      assert text =~ "unexecutable until a --fund run grants the allowance"
    end

    test "is a tx, not a UserOp, under --signer eoa" do
      lines = Order.spend_plan_lines(%{cfg() | signer: "eoa"}, [fund: true], :new_job)

      assert Enum.join(lines, "\n") =~ "rides INSIDE the approve+fund tx"
    end

    test "names the pinned spender when one was supplied" do
      lines = Order.spend_plan_lines(%{cfg() | solver: @spender}, [fund: true], :new_job)

      assert Enum.join(lines, "\n") =~ "spender pin: #{@spender}"
    end

    test "says a Permit2 pull is refused when no spender is pinned" do
      text = plan(fund: true)

      assert text =~ "spender pin: NONE"
      assert text =~ "refused before signing"
      assert text =~ "--solver"
      assert text =~ "no on-chain recipient guard"
    end

    test "a dry run promises no approve, only a report" do
      text = plan(dry_run: true)

      assert text =~ "no approve(Permit2) UserOp is sent under --dry-run"
      refute text =~ "rides INSIDE"
    end
  end

  describe "resumed jobs" do
    test "print the job's own on-chain budget, not the --amount/--fee-bps default" do
      text = plan([job_id: 73_295, fund: true], {:ok, 5_000})

      assert text =~ "escrow      0.005 ON-CHAIN"
      assert text =~ "the resumed job's own budget"
      # 8 bps of the default 3.00 has nothing to do with this job.
      refute text =~ "0.0024 expected"
    end

    test "say so when the budget cannot be read, rather than inventing one" do
      text = plan([job_id: 73_295, fund: true], :unreadable)

      assert text =~ "escrow      UNKNOWN"
      assert text =~ "could not read the resumed job's budget"
      refute text =~ "0.0024 expected"
    end

    test "note that the flags do not describe the resumed job" do
      assert plan([job_id: 73_295], {:ok, 5_000}) =~
               "--amount/--fee-bps do not describe a resumed job"
    end
  end

  describe "escrow ceiling" do
    test "the plan names the ceiling --fund will refuse to exceed" do
      assert plan(fund: true) =~ "refusing anything above 0.0024 (raise it with --max-escrow)"
    end

    test "--max-escrow raises the printed ceiling" do
      assert plan(fund: true, max_escrow: "0.05") =~ "refusing anything above 0.05"
    end

    test "a budget matching the asserted take-rate passes" do
      assert {:ok, line} = Order.budget_verdict(cfg(), 2_400, 2_400)
      assert line =~ "OK: budget == 8 bps"
    end

    test "a budget under the ceiling passes with the mismatch named" do
      assert {:ok, line} = Order.budget_verdict(cfg(), 2_000, 2_400)
      assert line =~ "budget 2000 != expected 2400"
      assert line =~ "within the ceiling 2400"
    end

    test "a budget over the ceiling is refused, not warned about" do
      assert {:error, message} = Order.budget_verdict(cfg(), 2_000_000_000, 2_400)
      assert message =~ "above the 2400 ceiling"
      assert message =~ "refusing to fund"
      assert message =~ "--max-escrow"
    end

    test "--max-escrow accepts a budget that would otherwise be refused" do
      assert {:ok, line} = Order.budget_verdict(cfg(), 3_000_000, 3_000_000)
      assert line =~ "within the ceiling 3000000"
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
