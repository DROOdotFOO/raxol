defmodule Raxol.Payments.Assets.UsdcDomainsTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Assets.UsdcDomains

  describe "lookup/1" do
    test "mainnet USDC deployments resolve to 'USD Coin'" do
      for chain_id <- [1, 10, 137, 8453, 42_161] do
        assert UsdcDomains.lookup(chain_id) == %{name: "USD Coin", version: "2"},
               "chain #{chain_id} expected USD Coin"
      end
    end

    test "Eth/OP/Base Sepolia USDC deployments resolve to 'USDC'" do
      for chain_id <- [11_155_111, 11_155_420, 84_532] do
        assert UsdcDomains.lookup(chain_id) == %{name: "USDC", version: "2"},
               "chain #{chain_id} expected USDC"
      end
    end

    test "Arbitrum Sepolia USDC resolves to 'USD Coin' (verified on-chain)" do
      assert UsdcDomains.lookup(421_614) == %{name: "USD Coin", version: "2"}
    end

    test "unknown chain id falls back to mainnet default" do
      assert UsdcDomains.lookup(999_999) == %{name: "USD Coin", version: "2"}
    end
  end

  describe "known_chain_ids/0" do
    test "covers every chain in the riddler-client matrix" do
      ids = UsdcDomains.known_chain_ids() |> MapSet.new()

      expected =
        MapSet.new([
          1,
          10,
          137,
          8453,
          42_161,
          11_155_111,
          11_155_420,
          84_532,
          421_614
        ])

      assert MapSet.equal?(ids, expected)
    end
  end
end
