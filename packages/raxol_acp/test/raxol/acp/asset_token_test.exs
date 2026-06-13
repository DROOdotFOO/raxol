defmodule Raxol.ACP.AssetTokenTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.AssetToken

  describe "usdc/2" do
    test "Base mainnet: 0.1 USDC -> 100_000 raw" do
      token = AssetToken.usdc(0.1, 8453)
      assert token.symbol == "USDC"
      assert token.decimals == 6
      assert token.raw_amount == 100_000
      assert token.chain_id == 8453
      assert token.address == "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
    end

    test "Base Sepolia: 1 USDC -> 1_000_000 raw" do
      token = AssetToken.usdc(1, 84_532)
      assert token.raw_amount == 1_000_000
      assert token.chain_id == 84_532
    end

    test "Decimal input accepted" do
      token = AssetToken.usdc(Decimal.new("0.25"), 8453)
      assert token.raw_amount == 250_000
    end

    test "unknown chain raises" do
      assert_raise ArgumentError, ~r/unknown chain_id/, fn ->
        AssetToken.usdc(1, 12345)
      end
    end
  end

  describe "usdc_from_raw/2" do
    test "round-trips with to_human/1" do
      token = AssetToken.usdc_from_raw(2_500_000, 8453)
      assert Decimal.equal?(AssetToken.to_human(token), Decimal.new("2.5"))
    end
  end

  describe "create/1" do
    test "WETH on Base mainnet" do
      token =
        AssetToken.create(
          address: "0x4200000000000000000000000000000000000006",
          symbol: "WETH",
          decimals: 18,
          amount: Decimal.new("1.5"),
          chain_id: 8453
        )

      assert token.raw_amount == 1_500_000_000_000_000_000
      assert token.symbol == "WETH"
    end

    test "raw_amount overrides amount when both could be provided" do
      token =
        AssetToken.create(
          address: "0x" <> String.duplicate("ab", 20),
          symbol: "FOO",
          decimals: 8,
          raw_amount: 12_345,
          chain_id: 8453
        )

      assert token.raw_amount == 12_345
    end
  end
end
