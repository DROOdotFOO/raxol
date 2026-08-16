defmodule Mix.Tasks.RaxolEarn.OrderTest do
  # async: false -- Mix.shell/1 and the task's env reads are process-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.RaxolEarn.Order

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
    :ok
  end

  # 3.00 USDC on Base at the default 8 bps, so the take rate -- and with it the
  # default ceiling -- is 2400 base units.
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

  # The real flag surface, so a ceiling raised on the command line is the ceiling
  # under test.
  defp gate(budget, argv), do: Order.enforce_budget!(cfg(), budget, Order.parse_argv(argv))

  describe "--corridor validation" do
    test "an unsupported destination lists only the chains USDC actually exists on" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--corridor", "8453>4663", "--dry-run"]) end)

      assert message =~ "no USDC address for the destination chain 4663"

      # 4663 (Robinhood Chain) carries USDG and WETH but no USDC, so offering it as
      # an alternative sends the operator straight back into this same error.
      refute message =~ "Robinhood Chain"

      for chain <- ["1 (Ethereum)", "10 (Optimism)", "137 (Polygon)", "8453 (Base)"] do
        assert message =~ chain
      end
    end

    test "an unsupported origin is named as the origin" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--corridor", "4663>8453", "--dry-run"]) end)

      assert message =~ "no USDC address for the origin chain 4663"
      refute message =~ "Robinhood Chain"
    end
  end

  describe "the escrow ceiling gate" do
    test "a budget above the ceiling aborts a --fund run before anything is approved" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> gate(2_000_000_000, ["--fund"]) end)

      assert message =~ "above the 2400 ceiling"
      assert message =~ "refusing to fund"

      # Why the number matters: it is the provider's, and --fund pays it.
      assert message =~ "what --fund approves and escrows"
      assert message =~ "re-run with a matching --fee-bps"
      assert message =~ "not charging what it advertises"
      assert message =~ "--max-escrow"
    end

    test "a budget exactly at the take rate passes" do
      assert gate(2_400, ["--fund"]) == :ok
      assert_received {:mix_shell, :info, ["[order] OK: budget == 8 bps of the principal"]}
    end

    test "a budget under the take rate is accepted, with the shortfall disclosed" do
      # Charging less than advertised costs the buyer nothing, so it must not abort.
      assert gate(2_000, ["--fund"]) == :ok

      assert_received {:mix_shell, :info,
                       ["[order] budget 2000 != expected 2400 (8 bps), within the ceiling 2400"]}
    end

    test "a run without --fund discloses a mismatch instead of stranding the job" do
      # By this point createJob has landed and the requirement is sent. A run that
      # escrows nothing has nothing to refuse.
      assert gate(2_000_000_000, []) == :ok
      assert_received {:mix_shell, :info, ["[order] WARN: provider set budget 2000000000" <> _]}
    end

    test "--max-escrow raises the ceiling so a refused budget is accepted" do
      assert_raise(Mix.Error, fn -> gate(50_000, ["--fund"]) end)

      assert gate(50_000, ["--fund", "--max-escrow", "0.05"]) == :ok
      assert_received {:mix_shell, :info, ["[order] budget 50000 != expected 2400" <> _]}
    end

    test "--max-escrow that is not a USDC amount is refused" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> gate(2_400, ["--fund", "--max-escrow", "lots"]) end)

      assert message =~ "is not a USDC amount"
    end
  end
end
