defmodule Raxol.Earn.ChainTest do
  use ExUnit.Case, async: false

  alias Raxol.Earn.Chain

  setup do
    on_exit(fn -> Application.delete_env(:raxol_earn, :chain_overrides) end)
    :ok
  end

  describe "mainnet/0" do
    test "returns Base mainnet config with the canonical V1 ACPSimple address" do
      config = Chain.mainnet()

      assert config.chain_id == 8453
      assert config.name == "Base Mainnet"
      assert String.starts_with?(config.rpc_url, "https://")
      assert String.match?(config.usdc_address, ~r/^0x[0-9a-fA-F]{40}$/)
      # Verified on-chain: V1 ACPSimple proxy on Base.
      assert config.acp_contract_address == "0x6a1FE26D54ab0d3E1e3168f2e0c0cDa5cC0A0A4A"
      assert config.acp_router_address == "0xa6C9BA866992cfD7fd6460ba912bfa405adA9df0"
      assert config.acp_socket_url == "https://acpx.virtuals.io"
      assert config.x402_facilitator_url == "https://acp-x402.virtuals.io"
    end
  end

  describe "sepolia/0" do
    test "returns Base sepolia config with the canonical V1 ACPSimple address" do
      config = Chain.sepolia()

      assert config.chain_id == 84_532
      assert config.name == "Base Sepolia"
      assert String.match?(config.usdc_address, ~r/^0x[0-9a-fA-F]{40}$/)
      assert config.acp_contract_address == "0x8Db6B1c839Fc8f6bd35777E194677B67b4D51928"
      # No verified V2 deployment on sepolia
      assert config.acp_router_address == nil
      assert config.acp_socket_url == "https://acpx.virtuals.gg"
      assert config.x402_facilitator_url == "https://dev-acp-x402.virtuals.io"
    end

    test "mainnet and sepolia have distinct USDC + ACP addresses" do
      assert Chain.mainnet().usdc_address != Chain.sepolia().usdc_address
      assert Chain.mainnet().acp_contract_address != Chain.sepolia().acp_contract_address
    end
  end

  describe "v2 contract addresses" do
    # Values verified against
    # https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/core/constants.ts
    test "mainnet v2 contract addresses match acp-node-v2 source" do
      config = Chain.mainnet()

      assert config.acp_core_address == "0x238E541BfefD82238730D00a2208E5497F1832E0"
      assert config.fund_transfer_hook_address == "0x0EaD25150985Bce0B4925c54E4ee1D856381A86B"
      assert config.multi_hook_router_address == "0x77F67252a8d3A6b049f4383FD50Fb9Bf784D29D1"
      assert config.subscription_hook_address == "0xD087363615f36F2b0265Bb4AC78Cd730C6C0cc1D"
      assert config.subscription_state_address == "0x52c2C68f4f7fF3C70760E3D0B9b2FA91CFE443Ad"
      assert config.acp_server_url == "https://api.acp.virtuals.io"
    end

    test "sepolia v2 contract addresses match acp-node-v2 source" do
      config = Chain.sepolia()

      assert config.acp_core_address == "0x0b93793923CD5De81850aF8604a233f3f24d461e"
      assert config.fund_transfer_hook_address == "0xbbeC2c985F9483473B9e0Da0704395943034266B"
      assert config.multi_hook_router_address == "0x5Af0589bD265d2B5Abb617570Ceef8f34Ac6BcdD"
      assert config.subscription_hook_address == "0x6eA4c9C6dA120B193e3C2249CCA81ead3Cfb318f"
      assert config.subscription_state_address == "0x6f254046aA8A9c253f839eb64Da1FE284930100F"
      assert config.acp_server_url == "https://api-dev.acp.virtuals.io"
    end

    test "v2 contract addresses are distinct between networks" do
      mainnet = Chain.mainnet()
      sepolia = Chain.sepolia()

      for field <- [
            :acp_core_address,
            :fund_transfer_hook_address,
            :multi_hook_router_address,
            :subscription_hook_address,
            :subscription_state_address,
            :acp_server_url
          ] do
        assert Map.fetch!(mainnet, field) != Map.fetch!(sepolia, field),
               "Expected mainnet and sepolia #{field} to differ"
      end
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
      Application.put_env(:raxol_earn, :chain_overrides, %{
        sepolia: %{rpc_url: "http://localhost:8545"}
      })

      config = Chain.sepolia()
      assert config.rpc_url == "http://localhost:8545"
      # Other keys still come from the base config
      assert config.chain_id == 84_532
    end

    test "overrides do not leak across networks" do
      Application.put_env(:raxol_earn, :chain_overrides, %{
        sepolia: %{rpc_url: "http://localhost:8545"}
      })

      assert Chain.mainnet().rpc_url == "https://mainnet.base.org"
    end

    test "missing override map leaves config untouched" do
      Application.put_env(:raxol_earn, :chain_overrides, %{})
      assert Chain.mainnet().chain_id == 8453
    end

    test "supports overriding placeholder fields like acp_contract_address" do
      Application.put_env(:raxol_earn, :chain_overrides, %{
        mainnet: %{acp_contract_address: "0x" <> String.duplicate("ab", 20)}
      })

      assert Chain.mainnet().acp_contract_address ==
               "0x" <> String.duplicate("ab", 20)
    end
  end
end
