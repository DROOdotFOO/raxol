defmodule Raxol.Payments.Eip191 do
  @moduledoc """
  EIP-191 `personal_sign` message hashing and recovery-id normalization.

  The `0x45` (`personal_sign`) variant of EIP-191 prefixes a message with
  `"\\x19Ethereum Signed Message:\\n" <> byte_size(message)` before hashing
  with keccak256. The 32-byte digest is what secp256k1 signs and what
  `ecrecover` / viem `verifyMessage` recover against.
  """

  @prefix "\x19Ethereum Signed Message:\n"

  @doc """
  keccak256 digest of an EIP-191 `personal_sign` message.
  """
  @spec digest(binary()) :: binary()
  def digest(message) when is_binary(message) do
    ExKeccak.hash_256(
      @prefix <> Integer.to_string(byte_size(message)) <> message
    )
  end

  @doc """
  Normalize an Ethereum recovery id to the 0/1 form `ExSecp256k1.recover/4`
  expects. `personal_sign` uses `v` in {27, 28}; a raw 0/1 recovery id is
  returned unchanged.
  """
  @spec normalize_recovery_id(non_neg_integer()) :: non_neg_integer()
  def normalize_recovery_id(v) when v >= 27, do: v - 27
  def normalize_recovery_id(v), do: v
end
