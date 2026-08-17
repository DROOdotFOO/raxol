defmodule Mix.Tasks.RaxolEarn.OrderTest do
  # async: false -- Mix.shell/1 and the task's env reads are process-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.RaxolEarn.Order

  @spender "0xE9B020941015e428876f60C1979B3fc2A38a2f53"

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

  describe "the --solver pin" do
    test "is a real switch, not one OptionParser silently drops" do
      # `strict:` routes an unregistered switch to `invalid` and parse_argv drops
      # it, so an unregistered --solver would leave the pin unset while the
      # operator watched themselves type it.
      assert Order.parse_argv(["--solver", @spender]) == [solver: @spender]
    end

    test "a malformed address is refused before the signer sidecar boots" do
      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--solver", "0xnope", "--dry-run"]) end)

      assert message =~ "is not a 0x-hex 20-byte address"
      assert message =~ "pins the origin-pull spender"
    end

    test "ORDER_SOLVER is read when the flag is absent, and validated the same way" do
      put_solver_env("not-an-address")

      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--dry-run"]) end)

      assert message =~ "ORDER_SOLVER"
      assert message =~ "is not a 0x-hex 20-byte address"
    end

    test "an empty --solver falls back to ORDER_SOLVER instead of suppressing it" do
      # `--solver ""` is truthy in Elixir, so an empty flag used to win the `||`
      # and leave the run unpinned while ORDER_SOLVER sat there set.
      put_solver_env("not-an-address")

      %Mix.Error{message: message} =
        assert_raise(Mix.Error, fn -> Order.run(["--solver", "  ", "--dry-run"]) end)

      # The env value is what got validated, so it is the value named back.
      assert message =~ ~s|"not-an-address"|
      assert message =~ "is not a 0x-hex 20-byte address"
    end
  end

  # The value is process-global, so a test that deletes it on the way out erases
  # whatever the operator (or an outer gate run) had set.
  defp put_solver_env(value) do
    prior = System.get_env("ORDER_SOLVER")
    System.put_env("ORDER_SOLVER", value)
    on_exit(fn -> restore_env("ORDER_SOLVER", prior) end)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

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
