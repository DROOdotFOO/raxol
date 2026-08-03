defmodule Raxol.Earn.Relay.OnchainBroadcaster do
  @moduledoc """
  Real `Raxol.Payments.Relay.Broadcaster` backed by raxol_earn's EVM transaction
  stack. It funds a Relay deposit by broadcasting an ERC-20 `transfer` to the
  Riddler deposit address on the source EVM chain.

  This lives in raxol_earn (not raxol_payments) because that is where the proven
  EIP-1559 signing / RLP / nonce / JSON-RPC stack lives, and raxol_earn depends on
  raxol_payments. raxol_payments stays free of fund-moving transaction code; the
  action injects this module.

  ## Wiring

  Supply a `Raxol.Earn.ProviderAdapter` (a `JSONRPC` adapter for production) either
  per call via the `:provider` param, or once at startup:

      provider = Raxol.Earn.ProviderAdapter.JSONRPC.new(
        chains: %{8453 => System.fetch_env!("BASE_RPC_URL")},
        private_key: agent_eoa_private_key
      )

      Raxol.Earn.Relay.OnchainBroadcaster.configure(provider)

  The provider's EOA must be the same funded address the agent's
  `Raxol.Payments.Wallet` represents, since it both holds the source funds and
  pays gas for the deposit.
  """

  @behaviour Raxol.Payments.Relay.Broadcaster

  alias Raxol.Earn.{ABI, ProviderAdapter}

  @transfer_signature "transfer(address,uint256)"
  @app :raxol_earn
  @config_key :relay_broadcaster_provider

  @doc """
  Set the default provider used when a `send_deposit/1` call does not carry one.
  """
  @spec configure(ProviderAdapter.adapter()) :: :ok
  def configure(%{adapter: _} = provider) do
    Application.put_env(@app, @config_key, provider)
  end

  @impl true
  def send_deposit(%{chain_id: chain_id, token: token, to: to, amount_atomic: amount} = params) do
    with {:ok, provider} <- provider(params),
         {:ok, amount_int} <- parse_amount(amount),
         {:ok, hashes} <-
           ProviderAdapter.send_calls(provider, chain_id, [transfer_call(token, to, amount_int)]) do
      first_hash(hashes)
    end
  end

  @doc """
  Build the ERC-20 `transfer(to, amount)` call (selector `0xa9059cbb` + args).
  Exposed so the encoding can be verified without broadcasting.
  """
  @spec transfer_call(String.t(), String.t(), non_neg_integer()) :: ProviderAdapter.call()
  def transfer_call(token, to, amount_int) when is_integer(amount_int) do
    %{
      to: token,
      data: ABI.encode_call(@transfer_signature, [{"address", to}, {"uint256", amount_int}]),
      value: 0
    }
  end

  defp provider(params) do
    case Map.get(params, :provider) || Application.get_env(@app, @config_key) do
      %{adapter: _} = provider -> {:ok, provider}
      _ -> {:error, :no_broadcaster_provider}
    end
  end

  defp parse_amount(amount) when is_integer(amount) and amount > 0, do: {:ok, amount}

  defp parse_amount(amount) when is_binary(amount) do
    case Integer.parse(amount) do
      {value, ""} when value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_amount, amount}}
    end
  end

  defp parse_amount(amount), do: {:error, {:invalid_amount, amount}}

  defp first_hash([hash | _]), do: {:ok, hash}
  defp first_hash([]), do: {:error, :no_tx_hash}
end
