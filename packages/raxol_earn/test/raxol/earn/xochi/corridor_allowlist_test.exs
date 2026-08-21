defmodule Raxol.Earn.Xochi.CorridorAllowlistTest do
  # async: false -- enabled?/0 reads app env, which some cases override.
  use ExUnit.Case, async: false

  alias Raxol.Earn.Xochi.CorridorAllowlist
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Relay.Schemas, as: RelaySchemas

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

  # `Offering.requirement_schema/0` hard-requires `pull_signature` on every
  # signed_intent bundle, so an ACP job can only be a corridor whose ORIGIN can
  # sign a gasless pull. A non-EVM origin (Tron, Solana) funds a deposit address
  # instead and has no pull to sign, so such a buyer would be turned away at the
  # shape gate as malformed rather than as an unsupported corridor.
  #
  # That narrowing costs nothing while no non-pulling origin is quotable at all,
  # which is what this pins. If it fails, a corridor was added whose origin
  # cannot pull: make `pull_signature` required per-mode in
  # `requirement_schema/1` instead of in the shared base. See GitHub #665.
  describe "pull-signature precondition" do
    # The property is "the origin can sign a gasless pull", i.e. it is an EVM leg
    # signing ERC-3009 or Permit2. `Raxol.Payments.Assets` is the registry of EVM
    # chains the payments stack prices gas for, so membership there IS that
    # property. Restating the chain ids in this file instead would make any newly
    # allowlisted EVM chain -- Linea, Scroll, which sign both just fine -- fail
    # with a diagnosis that is simply false.
    test "every corridor origin is an EVM chain whose buyer can sign a gasless pull" do
      corridors = CorridorAllowlist.corridors()
      assert corridors != []

      for {src, dst, from, to} <- corridors do
        assert Assets.native_symbol(from),
               "corridor #{src}->#{dst} (#{from}->#{to}) has origin chain #{from}, which " <>
                 "Raxol.Payments.Assets does not know as an EVM chain. A non-EVM origin " <>
                 "funds a deposit address and so has no pull to sign, while " <>
                 "Offering.requirement_schema/0 demands a pull_signature from every " <>
                 "bundle. Either register the chain, or make pull_signature required " <>
                 "per-mode in requirement_schema/1. See GitHub #665."

        refute RelaySchemas.tron_chain?(from),
               "Tron is quotable as a corridor origin (#{src}->#{dst}), but it funds by " <>
                 "deposit address and its buyer has no pull_signature to send."
      end
    end

    test "Tron is quotable as neither origin nor destination" do
      tron = RelaySchemas.tron_chain_id()

      # A positive control, because `allowed?/4` ends in a catch-all returning
      # false: refutes alone would still pass if `tron` were a typo, or if the
      # argument order here drifted. This proves the same call shape can be true.
      assert CorridorAllowlist.allowed?("USDC", "USDC", 8453, 10)

      # Derived from the corridor list rather than a hand-written pair list, so
      # every symbol pairing is covered and a new one cannot slip past.
      for {src, dst, from, to} <- CorridorAllowlist.corridors() do
        refute CorridorAllowlist.allowed?(src, dst, tron, to)
        refute CorridorAllowlist.allowed?(src, dst, from, tron)
      end
    end
  end

  describe "enabled?/0" do
    test "an explicit config boolean wins over the deployment default" do
      Application.put_env(:raxol_earn, :stablecoin_corridors_only, true)
      assert CorridorAllowlist.enabled?()

      Application.put_env(:raxol_earn, :stablecoin_corridors_only, false)
      refute CorridorAllowlist.enabled?()
    after
      Application.delete_env(:raxol_earn, :stablecoin_corridors_only)
    end

    test "defaults to the production deployment flag when unset (off in test)" do
      Application.delete_env(:raxol_earn, :stablecoin_corridors_only)
      assert CorridorAllowlist.enabled?() == Raxol.Payments.Deployment.production?()
    end
  end

  # corridors/0 tuples are {src, dst, from, to}; feed them straight to allowed?/4.
  defp corridor_allowed?({src, dst, from, to}), do: CorridorAllowlist.allowed?(src, dst, from, to)
end
