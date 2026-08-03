defmodule Raxol.Earn.Chain do
  @moduledoc """
  Static chain configuration for the ACP supported networks.

  Addresses and URLs below are the canonical Virtuals values, taken
  from `@virtuals-protocol/acp-node`'s `baseAcpConfig` /
  `baseSepoliaAcpConfig` (V1) and verified on-chain via Blockscout.

  Anything that varies in test/dev (e.g. a local Anvil RPC URL) is
  overridable through application config:

      config :raxol_earn,
        chain_overrides: %{
          sepolia: %{rpc_url: "http://localhost:8545"}
        }

  ## Active contracts

  The active v2 path is **`acp_core_address`** -- the ACP Core
  (`AgenticCommerceV3`), paired with `fund_transfer_hook_address`,
  `multi_hook_router_address`, `subscription_hook_address`, and
  `subscription_state_address`. It is reached through
  `Raxol.Earn.HookClient`. The Xochi storefront offering runs here (plain
  jobs, `hook = address(0)`).

  `acp_contract_address` (the sunsetted V1 `ACPSimple` proxy, retired
  upstream 2026-06-01) and `acp_router_address` (the legacy ACPRouter hop,
  Base mainnet only) stay only so existing dashboards / event indexers
  don't break; do not target them for new work. Callers should not pick an
  address directly.
  """

  @type network :: :mainnet | :sepolia
  @type config :: %{
          chain_id: pos_integer(),
          name: String.t(),
          rpc_url: String.t(),
          usdc_address: String.t(),
          acp_contract_address: String.t() | nil,
          acp_router_address: String.t() | nil,
          acp_core_address: String.t() | nil,
          fund_transfer_hook_address: String.t() | nil,
          multi_hook_router_address: String.t() | nil,
          subscription_hook_address: String.t() | nil,
          subscription_state_address: String.t() | nil,
          service_registry_address: String.t() | nil,
          identity_registry_address: String.t() | nil,
          acp_socket_url: String.t() | nil,
          acp_server_url: String.t() | nil,
          x402_facilitator_url: String.t() | nil
        }

  @mainnet %{
    chain_id: 8453,
    name: "Base Mainnet",
    rpc_url: "https://mainnet.base.org",
    # USDC on Base mainnet (canonical Circle deployment)
    usdc_address: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
    # V1 ACPSimple proxy (impl 0x48c15725...). Sunsetted in v2; kept for
    # back-compat during the transition.
    acp_contract_address: "0x6a1FE26D54ab0d3E1e3168f2e0c0cDa5cC0A0A4A",
    # Legacy v1 ACPRouter -- interim hop, obsolete in true v2.
    acp_router_address: "0xa6C9BA866992cfD7fd6460ba912bfa405adA9df0",
    # ACP v2 core contract -- verified against
    # https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/core/constants.ts
    acp_core_address: "0x238E541BfefD82238730D00a2208E5497F1832E0",
    fund_transfer_hook_address: "0x0EaD25150985Bce0B4925c54E4ee1D856381A86B",
    multi_hook_router_address: "0x77F67252a8d3A6b049f4383FD50Fb9Bf784D29D1",
    subscription_hook_address: "0xD087363615f36F2b0265Bb4AC78Cd730C6C0cc1D",
    subscription_state_address: "0x52c2C68f4f7fF3C70760E3D0B9b2FA91CFE443Ad",
    # ACP Service/Identity Registry addresses: not yet published by Virtuals
    # (registration is currently done out-of-band via the acp-cli / dashboard).
    # Set via `chain_overrides` once confirmed; see `Raxol.Earn.Seller.Registration`.
    service_registry_address: nil,
    identity_registry_address: nil,
    # Legacy Socket.IO endpoint (v1). v2 uses SSE via acp_server_url.
    acp_socket_url: "https://acpx.virtuals.io",
    acp_server_url: "https://api.acp.virtuals.io",
    x402_facilitator_url: "https://acp-x402.virtuals.io"
  }

  @sepolia %{
    chain_id: 84_532,
    name: "Base Sepolia",
    rpc_url: "https://sepolia.base.org",
    # Canonical Circle Sepolia USDC. Note: the Virtuals v2 SDK uses a
    # Virtuals-specific test USDC (0xECc22a8F...) -- override via
    # :chain_overrides if you need the Virtuals test deployment.
    usdc_address: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
    acp_contract_address: "0x8Db6B1c839Fc8f6bd35777E194677B67b4D51928",
    acp_router_address: nil,
    # ACP v2 contracts on Base Sepolia (verified against acp-node-v2 source).
    acp_core_address: "0x0b93793923CD5De81850aF8604a233f3f24d461e",
    fund_transfer_hook_address: "0xbbeC2c985F9483473B9e0Da0704395943034266B",
    multi_hook_router_address: "0x5Af0589bD265d2B5Abb617570Ceef8f34Ac6BcdD",
    subscription_hook_address: "0x6eA4c9C6dA120B193e3C2249CCA81ead3Cfb318f",
    subscription_state_address: "0x6f254046aA8A9c253f839eb64Da1FE284930100F",
    service_registry_address: nil,
    identity_registry_address: nil,
    acp_socket_url: "https://acpx.virtuals.gg",
    acp_server_url: "https://api-dev.acp.virtuals.io",
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

  @doc """
  Return the Service Registry address, or `{:error, :service_registry_not_configured}`
  when it is unset (the default until Virtuals publishes it). Lets a registration
  path fail closed rather than target a nil address.
  """
  @spec require_service_registry(config()) ::
          {:ok, String.t()} | {:error, :service_registry_not_configured}
  def require_service_registry(%{service_registry_address: addr}) when is_binary(addr),
    do: {:ok, addr}

  def require_service_registry(_config), do: {:error, :service_registry_not_configured}

  defp with_overrides(network, base) do
    overrides =
      :raxol_earn
      |> Application.get_env(:chain_overrides, %{})
      |> Map.get(network, %{})

    Map.merge(base, overrides)
  end
end
