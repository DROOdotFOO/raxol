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
end
