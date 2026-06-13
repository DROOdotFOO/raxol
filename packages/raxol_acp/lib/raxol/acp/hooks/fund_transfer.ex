defmodule Raxol.ACP.Hooks.FundTransfer do
  @moduledoc """
  Encoders / decoders for the `bytes data` parameter on ACP v2's
  `FundTransferHook`.

  The FundTransferHook intercepts ACP Core lifecycle calls
  (`setBudget`, `fund`, etc.) and routes a portion of the escrowed
  funds to a buyer-specified destination on completion. For the data
  bytes that travel through `setBudget(jobId, amount, data)`:

      abi.encode(uint256 transferAmount, address destination)

  - `transferAmount` is the fraction of the escrow the buyer wants
    delivered to `destination`. The remainder is the provider's
    service fee.
  - `destination` is the recipient EOA / contract that should receive
    `transferAmount` on completion.

  The `data` arg on `fund` is currently unused for the basic
  FundTransfer flow (the hook reads its config from the prior
  `setBudget`). We encode it as `<<>>` and accept anything that's the
  empty binary on decode.

  Verified shape against
  https://github.com/Virtual-Protocol/acp-node-v2/blob/main/src/core/fundTransferHookAbi.ts
  """

  alias Raxol.ACP.ABI

  @type transfer_amount :: non_neg_integer()
  @type address :: String.t()

  @doc """
  Encode the `bytes data` for `setBudget` against the FundTransferHook.

      abi.encode(uint256 transferAmount, address destination)
  """
  @spec encode_set_budget_data(transfer_amount(), address()) :: binary()
  def encode_set_budget_data(transfer_amount, destination)
      when is_integer(transfer_amount) and transfer_amount >= 0 and is_binary(destination) do
    # Both args are static -- no offset prefix, just two 32-byte slots.
    ABI.encode_args([
      {"uint256", transfer_amount},
      {"address", destination}
    ])
  end

  @doc """
  Decode previously-encoded `setBudget` data. Returns
  `{:ok, %{transfer_amount, destination}}` or `{:error, reason}`.
  """
  @spec decode_set_budget_data(binary()) ::
          {:ok, %{transfer_amount: transfer_amount(), destination: address()}} | {:error, term()}
  def decode_set_budget_data(<<transfer_amount::unsigned-big-256, addr_word::binary-size(32)>>) do
    # address is right-aligned in the 32-byte word
    <<_padding::binary-size(12), addr_bytes::binary-size(20)>> = addr_word
    {:ok, %{transfer_amount: transfer_amount, destination: "0x" <> Base.encode16(addr_bytes, case: :lower)}}
  end

  def decode_set_budget_data(other) do
    {:error, {:invalid_set_budget_data, byte_size(other)}}
  end

  @doc "Encode the `bytes data` for `fund`. Empty for the basic flow."
  @spec encode_fund_data() :: binary()
  def encode_fund_data, do: <<>>

  @doc """
  Encode the `bytes data` for `submit`. Reserved for future use; for
  now the deliverable is the bytes32 hash arg, and `data` is empty.
  """
  @spec encode_submit_data() :: binary()
  def encode_submit_data, do: <<>>
end
