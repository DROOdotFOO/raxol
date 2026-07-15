defmodule Raxol.ACP.Xochi.CorridorAllowlistTest do
  # async: false -- enabled?/0 reads app env, which some cases override.
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.CorridorAllowlist

  @usdc_chains [1, 10, 137, 8453, 42_161]

  describe "allowed?/4 -- USDC full mesh" do
    test "every ordered pair of the five CCTP chains is allowed" do
      for from <- @usdc_chains, to <- @usdc_chains, from != to do
        assert CorridorAllowlist.allowed?("USDC", "USDC", from, to),
               "expected USDC #{from}->#{to} allowed"
      end
    end

    test "same-chain USDC is not a corridor" do
      refute CorridorAllowlist.allowed?("USDC", "USDC", 8453, 8453)
    end

    test "USDC to/from a non-CCTP chain (Robinhood) is declined" do
      refute CorridorAllowlist.allowed?("USDC", "USDC", 8453, 4663)
      refute CorridorAllowlist.allowed?("USDC", "USDC", 4663, 8453)
    end
  end

  describe "allowed?/4 -- USDT relay corridors only" do
    test "the four explicit corridors are allowed" do
      assert CorridorAllowlist.allowed?("USDT", "USDT", 42_161, 137)
      assert CorridorAllowlist.allowed?("USDT", "USDT", 137, 42_161)
      assert CorridorAllowlist.allowed?("USDT", "USDT", 137, 10)
      assert CorridorAllowlist.allowed?("USDT", "USDT", 137, 1)
    end

    test "USDT on Base is not a relay corridor (either direction)" do
      refute CorridorAllowlist.allowed?("USDT", "USDT", 8453, 42_161)
      refute CorridorAllowlist.allowed?("USDT", "USDT", 42_161, 8453)
      refute CorridorAllowlist.allowed?("USDT", "USDT", 137, 8453)
    end

    test "an unlisted USDT hub direction (10->137) is declined" do
      refute CorridorAllowlist.allowed?("USDT", "USDT", 10, 137)
      refute CorridorAllowlist.allowed?("USDT", "USDT", 1, 137)
    end

    test "the USDT set matches Riddler's relay corridors exactly" do
      # Cross-check against riddler Relay.Routes @usdt_corridors.
      usdt = for {"USDT", "USDT", from, to} <- CorridorAllowlist.corridors(), do: {from, to}
      assert Enum.sort(usdt) == Enum.sort([{42_161, 137}, {137, 42_161}, {137, 10}, {137, 1}])
    end
  end

  describe "allowed?/4 -- USDG drain from Robinhood" do
    test "Robinhood USDG -> USDC on a hub (Arb, Base) is allowed" do
      assert CorridorAllowlist.allowed?("USDG", "USDC", 4663, 42_161)
      assert CorridorAllowlist.allowed?("USDG", "USDC", 4663, 8453)
    end

    test "USDG inbound to Robinhood is declined (drain direction only)" do
      refute CorridorAllowlist.allowed?("USDC", "USDG", 42_161, 4663)
      refute CorridorAllowlist.allowed?("USDC", "USDG", 8453, 4663)
    end

    test "USDG to a non-hub USDC chain is declined at launch scope" do
      refute CorridorAllowlist.allowed?("USDG", "USDC", 4663, 1)
      refute CorridorAllowlist.allowed?("USDG", "USDC", 4663, 10)
      refute CorridorAllowlist.allowed?("USDG", "USDC", 4663, 137)
    end

    test "USDG same-asset (USDG->USDG) is not a corridor" do
      refute CorridorAllowlist.allowed?("USDG", "USDG", 4663, 8453)
    end
  end

  describe "allowed?/4 -- everything else declined" do
    test "WETH is never allowed" do
      refute CorridorAllowlist.allowed?("WETH", "WETH", 8453, 42_161)
      refute CorridorAllowlist.allowed?("WETH", "WETH", 10, 137)
    end

    test "an unknown token (nil symbol) is never allowed" do
      refute CorridorAllowlist.allowed?(nil, "USDC", 8453, 42_161)
      refute CorridorAllowlist.allowed?("USDC", nil, 8453, 42_161)
      refute CorridorAllowlist.allowed?(nil, nil, 8453, 42_161)
    end

    test "a cross-asset pair we do not support (USDC->USDT) is declined" do
      refute CorridorAllowlist.allowed?("USDC", "USDT", 8453, 42_161)
    end
  end

  describe "corridors/0" do
    test "enumerates 20 USDC + 4 USDT + 2 USDG corridors" do
      corridors = CorridorAllowlist.corridors()
      assert length(corridors) == 26
      assert Enum.all?(corridors, &corridor_allowed?/1)
    end
  end

  describe "enabled?/0" do
    test "an explicit config boolean wins over the deployment default" do
      Application.put_env(:raxol_acp, :stablecoin_corridors_only, true)
      assert CorridorAllowlist.enabled?()

      Application.put_env(:raxol_acp, :stablecoin_corridors_only, false)
      refute CorridorAllowlist.enabled?()
    after
      Application.delete_env(:raxol_acp, :stablecoin_corridors_only)
    end

    test "defaults to the production deployment flag when unset (off in test)" do
      Application.delete_env(:raxol_acp, :stablecoin_corridors_only)
      assert CorridorAllowlist.enabled?() == Raxol.Payments.Deployment.production?()
    end
  end

  # corridors/0 tuples are {src, dst, from, to}; feed them straight to allowed?/4.
  defp corridor_allowed?({src, dst, from, to}), do: CorridorAllowlist.allowed?(src, dst, from, to)
end
