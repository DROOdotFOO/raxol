defmodule Raxol.ACP.ChainTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.Chain

  setup do
    on_exit(fn -> Application.delete_env(:raxol_acp, :chain_overrides) end)
    :ok
  end

  describe "mainnet/0" do
    test "returns Base mainnet config with all required keys" do
      config = Chain.mainnet()

      assert config.chain_id == 8453
      assert config.name == "Base Mainnet"
      assert String.starts_with?(config.rpc_url, "https://")
      assert String.match?(config.usdc_address, ~r/^0x[0-9a-fA-F]{40}$/)
      assert Map.has_key?(config, :acp_contract_address)
      assert Map.has_key?(config, :x402_facilitator_url)
    end
  end

  describe "sepolia/0" do
    test "returns Base sepolia config with chain_id 84532" do
      config = Chain.sepolia()

      assert config.chain_id == 84_532
      assert config.name == "Base Sepolia"
      assert String.match?(config.usdc_address, ~r/^0x[0-9a-fA-F]{40}$/)
    end

    test "mainnet and sepolia have distinct USDC addresses" do
      assert Chain.mainnet().usdc_address != Chain.sepolia().usdc_address
    end
  end

  describe "get/1" do
    test "resolves :mainnet" do
      assert {:ok, config} = Chain.get(:mainnet)
      assert config.chain_id == 8453
    end

    test "resolves :sepolia" do
      assert {:ok, config} = Chain.get(:sepolia)
      assert config.chain_id == 84_532
    end

    test "returns error for unknown network" do
      assert {:error, :unknown_network} = Chain.get(:goerli)
      assert {:error, :unknown_network} = Chain.get(:not_a_network)
    end
  end

  describe "Application.get_env overrides" do
    test "overrides individual keys for the named network" do
      Application.put_env(:raxol_acp, :chain_overrides, %{
        sepolia: %{rpc_url: "http://localhost:8545"}
      })

      config = Chain.sepolia()
      assert config.rpc_url == "http://localhost:8545"
      # Other keys still come from the base config
      assert config.chain_id == 84_532
    end

    test "overrides do not leak across networks" do
      Application.put_env(:raxol_acp, :chain_overrides, %{
        sepolia: %{rpc_url: "http://localhost:8545"}
      })

      assert Chain.mainnet().rpc_url == "https://mainnet.base.org"
    end

    test "missing override map leaves config untouched" do
      Application.put_env(:raxol_acp, :chain_overrides, %{})
      assert Chain.mainnet().chain_id == 8453
    end

    test "supports overriding placeholder fields like acp_contract_address" do
      Application.put_env(:raxol_acp, :chain_overrides, %{
        mainnet: %{acp_contract_address: "0x" <> String.duplicate("ab", 20)}
      })

      assert Chain.mainnet().acp_contract_address ==
               "0x" <> String.duplicate("ab", 20)
    end
  end
end
