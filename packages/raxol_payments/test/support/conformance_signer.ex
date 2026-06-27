defmodule Raxol.Payments.Test.ConformanceSigner do
  @moduledoc """
  Shared signing / recovery helpers for the EIP-712 conformance suites.

  The riddler-client conformance fixture pins, per vector, the ethers
  `expected_signature` and `expected_signer` alongside the digest. These helpers
  let the Xochi, ERC-3009 (x402), and Permit2 conformance tests assert those
  byte-for-byte without a node or a live wallet.

  Mirrors the production primitives so the assertions exercise the real path:

  - `sign_hex/2` is `Raxol.Payments.Wallets.Env.sign_hash/2` (`ExSecp256k1.sign`
    then `Raxol.Payments.EIP712.pack_signature/1`, RFC 6979, low-s, canonical v
    of 27/28).
  - `recover_address/2` is the `Raxol.Payments.Mandate` signer recovery
    (`ExSecp256k1.recover` then keccak-of-pubkey address derivation).
  """

  alias Raxol.Payments.EIP712

  @doc """
  Sign a 32-byte EIP-712 `digest` with `privkey` (raw 32 bytes), returning the
  canonical `0x` + r||s||v signature hex (v normalized to 27/28).
  """
  @spec sign_hex(<<_::256>>, <<_::256>>) :: String.t()
  def sign_hex(<<digest::binary-size(32)>>, <<privkey::binary-size(32)>>) do
    {:ok, signature} = ExSecp256k1.sign(digest, privkey)
    "0x" <> Base.encode16(EIP712.pack_signature(signature), case: :lower)
  end

  @doc """
  Recover the lowercase `0x` Ethereum address that produced `signature` (a `0x`
  r||s||v hex) over `digest` (raw 32 bytes).
  """
  @spec recover_address(<<_::256>>, String.t()) :: String.t()
  def recover_address(<<digest::binary-size(32)>>, signature) when is_binary(signature) do
    <<r::binary-size(32), s::binary-size(32), v::8>> = decode_hex!(signature)
    {:ok, pubkey} = ExSecp256k1.recover(digest, r, s, v - 27)
    <<_prefix::8, key_bytes::binary>> = pubkey
    <<_first_12::binary-size(12), address_bytes::binary-size(20)>> = ExKeccak.hash_256(key_bytes)
    "0x" <> Base.encode16(address_bytes, case: :lower)
  end

  @doc "Decode a `0x`-prefixed hex string to raw bytes."
  @spec decode_hex!(String.t()) :: binary()
  def decode_hex!("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
end
