defmodule Raxol.ACP.Wallet.SCA.EntryPoint do
  @moduledoc """
  ERC-4337 v0.7 EntryPoint read helpers shared by the SCA write paths.

  `EntryPoint.getNonce(account, key)` returns the full 256-bit nonce for
  a smart account under a given validating-entity key. The high 192 bits
  are the `key` (which Modular Account v2 packs the entity id into, see
  `Raxol.ACP.Wallet.SCA.ModularAccount.nonce_key/3`); the low 64 bits are
  the sequence the EntryPoint maintains.

  Extracted so the `Raxol.ACP.ProviderAdapter.SCA` and
  `Raxol.ACP.Wallet.SCA.Provisioner` write paths query nonces the same
  way.
  """

  alias Raxol.ACP.ABI
  alias Raxol.ACP.Onchain.RPC

  @sig_get_nonce "getNonce(address,uint192)"

  @doc """
  Fetch the full 256-bit EntryPoint nonce for `account` under `key`.

  `key` is the 192-bit validating-entity key (see
  `ModularAccount.nonce_key/3`). Returns the decoded integer nonce, or an
  error when the RPC fails or returns a malformed response.
  """
  @spec get_nonce(RPC.client(), String.t(), String.t(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def get_nonce(client, entry_point, account, key)
      when is_binary(entry_point) and is_binary(account) and is_integer(key) and key >= 0 do
    call_data = ABI.encode_call(@sig_get_nonce, [{"address", account}, {"uint192", key}])

    case RPC.eth_call(client, %{to: entry_point, data: call_data}) do
      {:ok, hex} ->
        case decode_uint256(hex) do
          {:ok, nonce} -> {:ok, nonce}
          :error -> {:error, {:invalid_nonce_response, hex}}
        end

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Decode an `eth_call` uint256 result to an integer.

  Fails closed with `:error` on a malformed / non-hex response rather than
  raising -- a bad RPC reply must not crash the send pipeline, nor silently
  become nonce 0. The empty result `"0x"` decodes as 0.
  """
  @spec decode_uint256(binary()) :: {:ok, non_neg_integer()} | :error
  def decode_uint256("0x"), do: {:ok, 0}

  def decode_uint256("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  def decode_uint256(_), do: :error
end
