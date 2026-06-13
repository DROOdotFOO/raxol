defmodule Raxol.Payments.Assets.UsdcDomains do
  @moduledoc """
  Per-chain USDC EIP-712 domain `name` and `version` values.

  USDC's EIP-712 domain `name` is not uniform across chains: mainnet
  deployments report `"USD Coin"`, but Ethereum/Base/OP Sepolia report
  `"USDC"`. Signing with the wrong name produces a digest USDC's
  `transferWithAuthorization` will reject.

  Values were verified on-chain via Blockscout. Source of truth for
  cross-checking: `riddler-permit2-erc3009/src/config.js` (`usdcName`
  and `usdcVersion` per chain).

  ## Example

      iex> Raxol.Payments.Assets.UsdcDomains.lookup(8453)
      %{name: "USD Coin", version: "2"}

      iex> Raxol.Payments.Assets.UsdcDomains.lookup(11_155_111)
      %{name: "USDC", version: "2"}
  """

  @default %{name: "USD Coin", version: "2"}

  @domains %{
    # Mainnets
    1 => %{name: "USD Coin", version: "2"},
    10 => %{name: "USD Coin", version: "2"},
    137 => %{name: "USD Coin", version: "2"},
    8453 => %{name: "USD Coin", version: "2"},
    42_161 => %{name: "USD Coin", version: "2"},
    # Testnets -- Sepolias use "USDC" except Arbitrum Sepolia
    11_155_111 => %{name: "USDC", version: "2"},
    11_155_420 => %{name: "USDC", version: "2"},
    84_532 => %{name: "USDC", version: "2"},
    421_614 => %{name: "USD Coin", version: "2"}
  }

  @doc """
  Return `%{name, version}` for the given chain ID.

  Falls back to `%{name: "USD Coin", version: "2"}` (the mainnet default)
  for unknown chain IDs so legacy callers continue to work.
  """
  @spec lookup(pos_integer()) :: %{name: String.t(), version: String.t()}
  def lookup(chain_id) when is_integer(chain_id) do
    Map.get(@domains, chain_id, @default)
  end

  @doc "Return the set of chain IDs with explicit overrides."
  @spec known_chain_ids() :: [pos_integer()]
  def known_chain_ids, do: Map.keys(@domains)
end
