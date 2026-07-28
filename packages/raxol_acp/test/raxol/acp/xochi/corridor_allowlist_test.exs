defmodule Raxol.ACP.Xochi.CorridorAllowlistTest do
  # async: false -- enabled?/0 reads app env, which some cases override.
  use ExUnit.Case, async: false

  alias Raxol.ACP.Xochi.CorridorAllowlist

  @usdc_chains [1, 10, 137, 8453, 42_161]
  @usdt_chains [1, 10, 137, 8453, 42_161]
  @robinhood 4663

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

    test "USDC to/from a non-CCTP chain (Robinhood) is not a same-asset corridor" do
      refute CorridorAllowlist.allowed?("USDC", "USDC", 8453, 4663)
      refute CorridorAllowlist.allowed?("USDC", "USDC", 4663, 8453)
    end
  end

  describe "allowed?/4 -- USDT full mesh (Base included)" do
    test "every ordered pair of the five EVM chains is allowed" do
      for from <- @usdt_chains, to <- @usdt_chains, from != to do
        assert CorridorAllowlist.allowed?("USDT", "USDT", from, to),
               "expected USDT #{from}->#{to} allowed"
      end
    end

    test "USDT on Base is now a corridor (either direction)" do
      assert CorridorAllowlist.allowed?("USDT", "USDT", 8453, 42_161)
      assert CorridorAllowlist.allowed?("USDT", "USDT", 42_161, 8453)
      assert CorridorAllowlist.allowed?("USDT", "USDT", 137, 8453)
    end

    test "same-chain USDT is not a corridor" do
      refute CorridorAllowlist.allowed?("USDT", "USDT", 137, 137)
    end

    test "the USDT set matches Riddler's full relay mesh" do
      # Cross-check against riddler Relay.Routes: all ordered pairs of @usdt_chains.
      usdt = for {"USDT", "USDT", from, to} <- CorridorAllowlist.corridors(), do: {from, to}
      expected = for f <- @usdt_chains, t <- @usdt_chains, f != t, do: {f, t}
      assert Enum.sort(usdt) == Enum.sort(expected)
    end
  end

  describe "allowed?/4 -- USDG cross-asset (Robinhood 4663)" do
    test "USDG exit drains to USDC on any mesh chain" do
      for to <- @usdc_chains do
        assert CorridorAllowlist.allowed?("USDG", "USDC", @robinhood, to),
               "expected USDG #{@robinhood}->#{to} (USDC) allowed"
      end
    end

    test "USDG exit drains to USDT on any mesh chain" do
      for to <- @usdt_chains do
        assert CorridorAllowlist.allowed?("USDG", "USDT", @robinhood, to)
      end
    end

    test "USDG inbound entry from USDC/USDT on any mesh chain is allowed" do
      for from <- @usdc_chains do
        assert CorridorAllowlist.allowed?("USDC", "USDG", from, @robinhood)
      end

      for from <- @usdt_chains do
        assert CorridorAllowlist.allowed?("USDT", "USDG", from, @robinhood)
      end
    end

    test "USDG legs must pivot on Robinhood (4663)" do
      # USDG only exists on 4663; a USDG leg on any other chain is not a corridor.
      refute CorridorAllowlist.allowed?("USDG", "USDC", 8453, 42_161)
      refute CorridorAllowlist.allowed?("USDC", "USDG", 8453, 42_161)
    end

    test "USDG same-asset (USDG->USDG) is not a corridor" do
      refute CorridorAllowlist.allowed?("USDG", "USDG", 4663, 8453)
    end
  end

  describe "allowed?/4 -- USDC <-> USDT cross-asset" do
    test "USDC->USDT and USDT->USDC are allowed across the mesh" do
      assert CorridorAllowlist.allowed?("USDC", "USDT", 8453, 42_161)
      assert CorridorAllowlist.allowed?("USDT", "USDC", 42_161, 8453)
    end

    test "same-chain cross-asset is not a corridor" do
      refute CorridorAllowlist.allowed?("USDC", "USDT", 8453, 8453)
      refute CorridorAllowlist.allowed?("USDT", "USDC", 137, 137)
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
  end

  describe "corridors/0" do
    test "enumerates the full production matrix (20 USDC + 20 USDT + 20 USDG + 40 cross)" do
      corridors = CorridorAllowlist.corridors()
      # 20 USDC mesh + 20 USDT mesh + 10 USDG-out + 10 USDG-in + 40 USDC<->USDT.
      assert length(corridors) == 100
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
