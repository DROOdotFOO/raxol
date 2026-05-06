defmodule Raxol.ACP.Chain do
  @moduledoc """
  Static chain configuration for the ACP supported networks.

  Returns one configuration map per network. Anything that varies in
  test/dev (e.g. local Anvil RPC URL, contract address that has not
  been deployed yet) is overridable through application config:

      config :raxol_acp,
        chain_overrides: %{
          sepolia: %{rpc_url: "http://localhost:8545"}
        }

  The actual ACP contract addresses, x402 facilitator URL, and USDC
  token addresses must be filled in once Virtuals publishes the
  `BASE_MAINNET_ACP_X402_CONFIG_V2` constants. v0.1 ships with the
  well-known USDC addresses and a placeholder for the ACP contract.
  """

  @type network :: :mainnet | :sepolia
  @type config :: %{
          chain_id: pos_integer(),
          name: String.t(),
          rpc_url: String.t(),
          usdc_address: String.t(),
          acp_contract_address: String.t() | nil,
          x402_facilitator_url: String.t() | nil
        }

  @mainnet %{
    chain_id: 8453,
    name: "Base Mainnet",
    rpc_url: "https://mainnet.base.org",
    # USDC on Base mainnet
    usdc_address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    # Filled in once we vendor BASE_MAINNET_ACP_X402_CONFIG_V2
    acp_contract_address: nil,
    x402_facilitator_url: nil
  }

  @sepolia %{
    chain_id: 84_532,
    name: "Base Sepolia",
    rpc_url: "https://sepolia.base.org",
    # USDC on Base Sepolia
    usdc_address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    acp_contract_address: nil,
    x402_facilitator_url: nil
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
