defmodule Raxol.Payments.AssetsTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Assets

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
end
