defmodule Raxol.Payments.Xochi.DepositAttestation do
  @moduledoc """
  Client-side verification of a Xochi deposit-route quote's `deposit_attestation`.

  A non-EVM origin (Tron/Solana) has no gasless pull, so a deposit-route quote
  returns a bare `deposit_address` for the payer to send funds to directly. A
  MITM or a compromised quote endpoint could swap that address and steal the
  deposit, so Riddler signs the quote's binding fields with a dedicated,
  solver-distinct key whose address is published in `GET /xochi/capabilities` as
  `deposit_attestation_signer`. raxol pins that address and verifies the
  attestation recovers to it BEFORE any funds move, failing closed otherwise.

  Byte-exact parity with the Riddler signer
  (`Riddler.Integrations.Xochi.DepositAttestation`): the signed message is seven
  lines joined by a single `\\n` (no trailing newline), UTF-8:

      xochi-deposit-attestation:v1
      <intent_id>
      <quote_id>
      <from_chain_id>
      <from_token>
      <from_amount>
      <deposit_address>

  EVM (`0x`-hex) addresses are lowercased; base58 values (a Tron TRC-20 contract,
  the Tron deposit address) are verbatim. `from_chain_id` and `from_amount` are
  decimal; `from_amount` is in base units, matching the quote's `from_amount`.
  The signature is `0x` + 65 bytes (`r || s || v`), `v` in {27, 28}, an EIP-191
  `personal_sign`.
  """

  @message_prefix "xochi-deposit-attestation:v1"
  @eip191_prefix "\x19Ethereum Signed Message:\n"

  @type fields :: %{
          intent_id: String.t(),
          quote_id: String.t(),
          from_chain_id: integer(),
          from_token: String.t(),
          from_amount: String.t() | integer(),
          deposit_address: String.t()
        }

  @doc "The byte-exact attestation message for the given quote binding fields."
  @spec message(fields()) :: String.t()
  def message(%{
        intent_id: intent_id,
        quote_id: quote_id,
        from_chain_id: from_chain_id,
        from_token: from_token,
        from_amount: from_amount,
        deposit_address: deposit_address
      }) do
    Enum.join(
      [
        @message_prefix,
        to_string(intent_id),
        to_string(quote_id),
        Integer.to_string(from_chain_id),
        normalize_address(from_token),
        to_string(from_amount),
        normalize_address(deposit_address)
      ],
      "\n"
    )
  end

  @doc """
  Recover the signer address (lowercased `0x`) from an attestation over `fields`.
  """
  @spec recover(fields(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def recover(%{} = fields, "0x" <> hex), do: recover(fields, hex)

  def recover(%{} = fields, hex) when is_binary(hex) and byte_size(hex) == 130 do
    with {:ok, {r, s, recovery_id}} <- decode_signature(hex),
         digest = eip191_digest(message(fields)),
         {:ok, pubkey} <- ExSecp256k1.recover(digest, r, s, recovery_id) do
      {:ok, address_from_pubkey(pubkey)}
    else
      _ -> {:error, :invalid_signature}
    end
  end

  def recover(_fields, _sig), do: {:error, :invalid_signature}

  @doc """
  Verify `signature` over `fields` recovers to `expected_signer`, fail closed.

    * `{:error, :missing_attestation}` -- the quote carried no signature.
    * `{:error, :signer_unavailable}` -- no signer is pinned (nothing to verify
      against; refuse rather than trust the bare deposit address).
    * `{:error, :attestation_mismatch}` -- it recovers to a different address.
    * `{:error, :invalid_signature}` -- it cannot be recovered.
  """
  @spec verify(fields(), String.t() | nil, String.t() | nil) :: :ok | {:error, atom()}
  def verify(_fields, nil, _signer), do: {:error, :missing_attestation}
  def verify(_fields, "", _signer), do: {:error, :missing_attestation}
  def verify(_fields, _signature, nil), do: {:error, :signer_unavailable}
  def verify(_fields, _signature, ""), do: {:error, :signer_unavailable}

  def verify(%{} = fields, signature, expected_signer)
      when is_binary(signature) and is_binary(expected_signer) do
    case recover(fields, signature) do
      {:ok, recovered} ->
        if addr_eq?(recovered, expected_signer),
          do: :ok,
          else: {:error, :attestation_mismatch}

      {:error, _} ->
        {:error, :invalid_signature}
    end
  end

  # -- Private --

  # EVM addresses lowercased; base58 (Tron/Solana) values verbatim. Non-address
  # strings (intent/quote ids) never reach here.
  defp normalize_address("0x" <> _ = address), do: String.downcase(address)
  defp normalize_address(other), do: other

  defp eip191_digest(message) do
    prefixed = @eip191_prefix <> Integer.to_string(byte_size(message)) <> message
    ExKeccak.hash_256(prefixed)
  end

  defp decode_signature(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>} ->
        {:ok, {r, s, normalize_recovery_id(v)}}

      _ ->
        {:error, :invalid_signature}
    end
  end

  # EIP-191/personal_sign uses v in {27, 28}; ExSecp256k1 wants a 0/1 recovery id.
  defp normalize_recovery_id(v) when v >= 27, do: v - 27
  defp normalize_recovery_id(v), do: v

  # address = last 20 bytes of keccak256(uncompressed pubkey without the 0x04 tag).
  defp address_from_pubkey(<<_prefix::8, xy::binary-size(64)>>) do
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  defp addr_eq?(a, b), do: String.downcase(a) == String.downcase(b)
end
