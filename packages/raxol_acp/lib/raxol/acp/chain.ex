defmodule Raxol.ACP.Chain do
  @moduledoc """
  Static chain configuration for the ACP supported networks.

  Addresses and URLs below are the canonical Virtuals values, taken
  from `@virtuals-protocol/acp-node`'s `baseAcpConfig` /
  `baseSepoliaAcpConfig` (V1) and verified on-chain via Blockscout.

  Anything that varies in test/dev (e.g. a local Anvil RPC URL) is
  overridable through application config:

      config :raxol_acp,
        chain_overrides: %{
          sepolia: %{rpc_url: "http://localhost:8545"}
        }

  ## Contract version (V1 vs V2)

  `acp_contract_address` points at the **V1 `ACPSimple`** proxy, which
  is what `Raxol.ACP.ContractClient.Onchain`'s selectors and the
  vendored `priv/abi/acp_simple.json` target. Virtuals also runs a
  newer **V2 `ACPRouter`** (Base mainnet `0xa6C9BA866992cfD7fd6460ba912bfa405adA9df0`)
  with a different ABI -- not wired here; using it would require the
  V2 ABI/selectors.
  """

  @type network :: :mainnet | :sepolia
  @type config :: %{
          chain_id: pos_integer(),
          name: String.t(),
          rpc_url: String.t(),
          usdc_address: String.t(),
          acp_contract_address: String.t() | nil,
          acp_socket_url: String.t() | nil,
          x402_facilitator_url: String.t() | nil
        }

  @mainnet %{
    chain_id: 8453,
    name: "Base Mainnet",
    rpc_url: "https://mainnet.base.org",
    # USDC on Base mainnet
    usdc_address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    # V1 ACPSimple proxy (impl 0x48c15725...); verified on Basescan
    acp_contract_address: "0x6a1FE26D54ab0d3E1e3168f2e0c0cDa5cC0A0A4A",
    # Virtuals ACP Socket.IO endpoint
    acp_socket_url: "https://acpx.virtuals.io",
    x402_facilitator_url: "https://acp-x402.virtuals.io"
  }

  @sepolia %{
    chain_id: 84_532,
    name: "Base Sepolia",
    rpc_url: "https://sepolia.base.org",
    # USDC on Base Sepolia
    usdc_address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    # V1 ACPSimple proxy (impl 0xF9663D54...); verified on Basescan
    acp_contract_address: "0x8Db6B1c839Fc8f6bd35777E194677B67b4D51928",
    acp_socket_url: "https://acpx.virtuals.gg",
    x402_facilitator_url: "https://dev-acp-x402.virtuals.io"
  }

  @doc "Return the configuration map for `:mainnet`, with overrides applied."
  @spec mainnet() :: config()
  def mainnet, do: with_overrides(:mainnet, @mainnet)

  @doc "Return the configuration map for `:sepolia`, with overrides applied."
  @spec sepolia() :: config()
  def sepolia, do: with_overrides(:sepolia, @sepolia)

  @doc """
  Look up a network by name.

  Returns `{:error, :unknown_network}` for anything other than `:mainnet`
  or `:sepolia` so callers do not need a separate validation step.
  """
  @spec get(network()) :: {:ok, config()} | {:error, :unknown_network}
  def get(:mainnet), do: {:ok, mainnet()}
  def get(:sepolia), do: {:ok, sepolia()}
  def get(_), do: {:error, :unknown_network}

  defp with_overrides(network, base) do
    overrides =
      :raxol_acp
      |> Application.get_env(:chain_overrides, %{})
      |> Map.get(network, %{})

    Map.merge(base, overrides)
  end
end
