defmodule Raxol.Payments.AssetsTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Assets

  # The Riddler solver fills USDC, USDT, and WETH on the five original EVM chains,
  # plus USDG and WETH on Robinhood Chain (4663). Each must be a registered Assets
  # entry: an unregistered token falls back to 6 decimals, wrong for an 18-decimal
  # token like WETH. This fixture pins the set so a dropped or wrong-decimal entry
  # fails here. Addresses mirror Riddler's config/token_registry.ex (lowercased).
  @solver_fillable [
    # Ethereum mainnet
    {1, "USDC", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48", 6},
    {1, "USDT", "0xdac17f958d2ee523a2206206994597c13d831ec7", 6},
    {1, "WETH", "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2", 18},
    # Optimism
    {10, "USDC", "0x0b2c639c533813f4aa9d7837caf62653d097ff85", 6},
    {10, "USDT", "0x94b008aa00579c1307b0ef2c499ad98a8ce58e58", 6},
    {10, "WETH", "0x4200000000000000000000000000000000000006", 18},
    # Polygon
    {137, "USDC", "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359", 6},
    {137, "USDT", "0xc2132d05d31c914a87c6611c10748aeb04b58e8f", 6},
    {137, "WETH", "0x7ceb23fd6bc0add59e62ac25578270cff1b9f619", 18},
    # Base
    {8453, "USDC", "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913", 6},
    {8453, "USDT", "0xfde4c96c8593536e31f229ea8f37b2ada2699bb2", 6},
    {8453, "WETH", "0x4200000000000000000000000000000000000006", 18},
    # Arbitrum
    {42_161, "USDC", "0xaf88d065e77c8cc2239327c5edb3a432268e5831", 6},
    {42_161, "USDT", "0xfd086bc7cd5c481dcc9c85ebe478a1c0b69fcbb9", 6},
    {42_161, "WETH", "0x82af49447d8a07e3bd95bd0d56f35241523fbab1", 18},
    # Robinhood Chain (USDG is the native stablecoin; WETH also canonical)
    {4663, "USDG", "0x5fc5360d0400a0fd4f2af552add042d716f1d168", 6},
    {4663, "WETH", "0x0bd7d308f8e1639fab988df18a8011f41eacad73", 18}
  ]

  describe "solver-fillable token parity" do
    test "each fillable token is explicitly registered across the supported EVM chains" do
      for {chain, symbol, address, _decimals} <- @solver_fillable do
        assert Assets.known?(chain, address),
               "#{symbol} on chain #{chain} (#{address}) is not a known Assets " <>
                 "entry; it would silently default to 6 decimals"
      end
    end

    test "each fillable token resolves to its correct decimals" do
      for {chain, symbol, address, decimals} <- @solver_fillable do
        assert Assets.decimals(chain, address) == decimals,
               "#{symbol} on chain #{chain} resolved the wrong decimals"
      end
    end

    test "known?/2 is false for an unregistered contract (the silent-default trap)" do
      bogus = "0x" <> String.duplicate("ab", 20)
      refute Assets.known?(137, bogus)
      # Decimals still falls back to 6; known?/2 reports it as unregistered.
      assert Assets.decimals(137, bogus) == 6
    end

    test "address/2 resolves each fillable (chain, symbol) to its pinned contract" do
      for {chain, symbol, address, _decimals} <- @solver_fillable do
        assert Assets.address(chain, symbol) == {:ok, address},
               "#{symbol} on chain #{chain} did not resolve to #{address}"
      end
    end

    test "address/2 returns :error for an unsupported pair" do
      # DAI is tracked but not solver-fillable, so it is intentionally absent.
      assert Assets.address(8453, "DAI") == :error
      assert Assets.address(999, "USDC") == :error
      assert Assets.address(8453, nil) == :error
    end

    test "symbols/0 is exactly the solver-fillable set" do
      assert Enum.sort(Assets.symbols()) == ["USDC", "USDG", "USDT", "WETH"]
    end

    test "symbol_for/2 resolves every fillable (chain, address) back to its symbol" do
      for {chain, symbol, address, _decimals} <- @solver_fillable do
        assert Assets.symbol_for(chain, address) == symbol,
               "#{address} on chain #{chain} did not resolve back to #{symbol}"
      end
    end

    test "symbol_for/2 is the inverse of address/2 and case-insensitive" do
      assert Assets.symbol_for(8453, "0x833589FCD6EDB6E08F4C7C32D4F71B54BDA02913") == "USDC"

      assert Assets.symbol_for("eip155:42161", "0xaf88d065e77c8cc2239327c5edb3a432268e5831") ==
               "USDC"
    end

    test "symbol_for/2 returns nil for an unregistered or cross-chain pair" do
      # Base USDC address, but queried on Arbitrum: not the same token there.
      assert Assets.symbol_for(42_161, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913") == nil
      assert Assets.symbol_for(8453, "0x" <> String.duplicate("ab", 20)) == nil
      assert Assets.symbol_for(8453, nil) == nil
      assert Assets.symbol_for(nil, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913") == nil
    end
  end

  describe "Robinhood Chain USDG" do
    @usdg "0x5fc5360d0400a0fd4f2af552add042d716f1d168"

    test "USDG is a registered 6-decimal token on chain 4663" do
      assert Assets.known?(4663, @usdg)
      assert Assets.decimals(4663, @usdg) == 6
      assert Assets.address(4663, "USDG") == {:ok, @usdg}
      assert Assets.symbol_for(4663, @usdg) == "USDG"
    end

    test "USDG is not classified as USDC (pulled via Permit2, not ERC-3009)" do
      # ERC-3009 signs against the USDC contract; USDG has no ERC-3009, so
      # usdc?/2 must be false or the agent would sign an invalid authorization.
      refute Assets.usdc?(4663, @usdg)
    end
  end

  describe "decimals/2 (chain + address)" do
    test "USDC on Base resolves to 6" do
      assert Assets.decimals(8453, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913") ==
               6
    end

    test "WETH on Base resolves to 18" do
      assert Assets.decimals(8453, "0x4200000000000000000000000000000000000006") ==
               18
    end

    test "USDC on Ethereum mainnet resolves to 6" do
      assert Assets.decimals(1, "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48") ==
               6
    end

    test "address case is normalized" do
      lower =
        Assets.decimals(8453, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")

      upper =
        Assets.decimals(8453, "0x833589FCD6EDB6E08F4C7C32D4F71B54BDA02913")

      assert lower == upper
    end

    test "CAIP-2 chain id string is accepted" do
      assert Assets.decimals(
               "eip155:8453",
               "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
             ) == 6
    end

    test "unknown contract defaults to 6 (USDC-safe)" do
      assert Assets.decimals(8453, "0x" <> String.duplicate("dd", 20)) == 6
    end

    test "unknown chain defaults to 6" do
      assert Assets.decimals(
               99_999,
               "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
             ) == 6
    end

    test "nil/empty contract defaults to 6" do
      assert Assets.decimals(8453, nil) == 6
      assert Assets.decimals(8453, "") == 6
    end
  end

  describe "decimals/1 (ticker)" do
    test "USDC resolves to 6" do
      assert Assets.decimals("USDC") == 6
    end

    test "ETH resolves to 18" do
      assert Assets.decimals("ETH") == 18
      assert Assets.decimals("WETH") == 18
    end

    test "DAI resolves to 18" do
      assert Assets.decimals("DAI") == 18
    end

    test "ticker is case-insensitive" do
      assert Assets.decimals("usdc") == 6
      assert Assets.decimals("Usdc") == 6
    end

    test "unknown ticker defaults to 6" do
      assert Assets.decimals("WIF") == 6
      assert Assets.decimals(nil) == 6
    end
  end

  describe "to_human/2" do
    test "10_000 with 6 decimals -> 0.01" do
      assert Decimal.equal?(Assets.to_human(10_000, 6), Decimal.new("0.01"))
    end

    test "1_000_000 with 6 decimals -> 1" do
      assert Decimal.equal?(Assets.to_human(1_000_000, 6), Decimal.new("1"))
    end

    test "10**18 with 18 decimals -> 1" do
      assert Decimal.equal?(
               Assets.to_human(Integer.pow(10, 18), 18),
               Decimal.new("1")
             )
    end

    test "accepts string input" do
      assert Decimal.equal?(Assets.to_human("10000", 6), Decimal.new("0.01"))
    end

    test "accepts Decimal input" do
      assert Decimal.equal?(
               Assets.to_human(Decimal.new(10_000), 6),
               Decimal.new("0.01")
             )
    end
  end

  describe "usdc?/2" do
    test "recognizes USDC across chains, case-insensitively" do
      assert Assets.usdc?(8453, "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913")
      assert Assets.usdc?(8453, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
      assert Assets.usdc?(42_161, "0xaf88d065e77c8cc2239327c5edb3a432268e5831")
      assert Assets.usdc?("eip155:1", "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    end

    test "rejects non-USDC tokens and unknown chains" do
      # WETH on Base
      refute Assets.usdc?(8453, "0x4200000000000000000000000000000000000006")
      # USDC address but wrong chain
      refute Assets.usdc?(42_161, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
      refute Assets.usdc?(8453, nil)
      refute Assets.usdc?(nil, "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913")
    end
  end

  describe "usdc_chains/0" do
    test "returns the CCTP mesh, ascending" do
      assert Assets.usdc_chains() == [1, 10, 137, 8453, 42_161]
    end

    test "every advertised chain actually recognizes a USDC contract" do
      # Guards against the chain list drifting from usdc?/2.
      for chain <- Assets.usdc_chains() do
        assert Enum.any?(
                 known_usdc_addresses(),
                 &Assets.usdc?(chain, &1)
               ),
               "chain #{chain} advertised but no USDC contract recognized"
      end
    end
  end

  defp known_usdc_addresses do
    [
      "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
      "0x3c499c542cef5e3811e1192ce70d8cc03d5c3359",
      "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    ]
  end
end
