defmodule Raxol.ACP.Onchain.Permit2Approver do
  @moduledoc """
  On-chain ERC-20 Permit2 allowance management, backed by raxol_acp's EVM
  transaction stack.

  A Xochi cross-chain transfer of USDT or WETH pulls the origin funds through
  the universal Permit2 contract, which requires a standing ERC-20 allowance the
  origin wallet must grant once per token per chain. (USDC pulls via ERC-3009 and
  needs no allowance.) This module reads the current allowance and, when it is
  short, broadcasts a max `approve(Permit2, uint256.max)` so the pull lands.

  It lives in raxol_acp (not raxol_payments) for the same reason as
  `Raxol.ACP.Relay.OnchainBroadcaster`: this is where the proven EIP-1559 signing
  / RLP / nonce / JSON-RPC stack lives, and raxol_payments stays free of
  fund-moving transaction code.

  ## Usage

      provider =
        Raxol.ACP.ProviderAdapter.JSONRPC.new(
          chains: %{8453 => System.fetch_env!("BASE_RPC_URL")},
          private_key: origin_eoa_private_key
        )

      {:ok, _} =
        Raxol.ACP.Onchain.Permit2Approver.ensure_allowance(
          provider,
          8453,
          usdt_on_base,
          Raxol.ACP.ProviderAdapter.get_address(provider)
        )

  The EOA behind `provider` (the JSON-RPC `ProviderAdapter`) must be the origin
  wallet that signs the Xochi Permit2 authorization, since that is the address
  Permit2 pulls from. In the storefront model the BUYER signs and holds this
  allowance (raxol relays the buyer's signed intent and never pulls), so pass the
  buyer's wallet here -- not the storefront/ACP-provider wallet.
  """

  alias Raxol.ACP.{ABI, ProviderAdapter}

  # Universal Permit2, identical on every EVM chain. Matches
  # `Raxol.Payments.Protocols.Permit2.verifying_contract/0`.
  @permit2_address "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  @approve_signature "approve(address,uint256)"
  @allowance_signature "allowance(address,address)"
  @max_uint256 Integer.pow(2, 256) - 1
  # Treat any allowance below half of max as "not a standing max approval", so a
  # spent-down, finite, or zero allowance triggers a fresh max approve.
  @allowance_floor Integer.pow(2, 255)

  @doc "The universal Permit2 contract address (the approval spender)."
  @spec permit2_address() :: String.t()
  def permit2_address, do: @permit2_address

  @doc "The maximum uint256 value granted by a default approve."
  @spec max_uint256() :: non_neg_integer()
  def max_uint256, do: @max_uint256

  @doc """
  Build the ERC-20 `approve(Permit2, amount)` call (selector `0x095ea7b3`).
  Exposed so the encoding can be verified without broadcasting.
  """
  @spec approve_call(String.t(), non_neg_integer()) :: ProviderAdapter.call()
  def approve_call(token, amount \\ @max_uint256)
      when is_binary(token) and is_integer(amount) and amount >= 0 do
    %{
      to: token,
      data:
        ABI.encode_call(@approve_signature, [{"address", @permit2_address}, {"uint256", amount}]),
      value: 0
    }
  end

  @doc """
  Read the current Permit2 allowance `owner` has granted for `token` on
  `chain_id`. Returns the allowance as a non-negative integer.
  """
  @spec allowance(ProviderAdapter.adapter(), pos_integer(), String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def allowance(provider, chain_id, token, owner)
      when is_binary(token) and is_binary(owner) do
    params = %{
      address: token,
      signature: @allowance_signature,
      args: [{"address", owner}, {"address", @permit2_address}]
    }

    with {:ok, raw} <- ProviderAdapter.read_contract(provider, chain_id, params) do
      decode_uint256(raw)
    end
  end

  @doc """
  Ensure `owner` has granted Permit2 a sufficient allowance for `token` on
  `chain_id`, broadcasting a max `approve` only when it is short. Idempotent: a
  standing max approval returns `{:ok, :sufficient}` with no transaction.

  ## Options

  - `:min_allowance` -- the allowance considered sufficient. Defaults to `2^255`
    (a standing max approval); pass the transfer amount to approve lazily.
  - `:amount` -- the amount to approve when short. Defaults to `uint256.max`.
  """
  @spec ensure_allowance(
          ProviderAdapter.adapter(),
          pos_integer(),
          String.t(),
          String.t(),
          keyword()
        ) ::
          {:ok, :sufficient} | {:ok, {:approved, String.t()}} | {:error, term()}
  def ensure_allowance(provider, chain_id, token, owner, opts \\ [])
      when is_binary(token) and is_binary(owner) do
    min_required = Keyword.get(opts, :min_allowance, @allowance_floor)
    amount = Keyword.get(opts, :amount, @max_uint256)

    with {:ok, current} <- allowance(provider, chain_id, token, owner) do
      if current >= min_required do
        {:ok, :sufficient}
      else
        approve(provider, chain_id, token, amount)
      end
    end
  end

  # -- Internal --

  defp approve(provider, chain_id, token, amount) do
    case ProviderAdapter.send_calls(provider, chain_id, [approve_call(token, amount)]) do
      {:ok, [hash | _]} -> {:ok, {:approved, hash}}
      {:ok, []} -> {:error, :no_tx_hash}
      {:error, _} = err -> err
    end
  end

  # read_contract returns the raw eth_call word: "0x" + 64 hex from JSON-RPC, or
  # an integer from a canned mock. Both decode to a non-negative integer.
  defp decode_uint256(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp decode_uint256("0x"), do: {:ok, 0}

  defp decode_uint256("0x" <> hex) when is_binary(hex) do
    case Integer.parse(hex, 16) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:invalid_allowance, "0x" <> hex}}
    end
  end

  defp decode_uint256(other), do: {:error, {:invalid_allowance, other}}
end
