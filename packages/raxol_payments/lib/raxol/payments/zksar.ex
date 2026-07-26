defmodule Raxol.Payments.Zksar do
  @moduledoc """
  ZKSAR (Zero-Knowledge Sanctions/AML Reporting) attestation verification.

  Verifies Xochi oracle-signed attestation results. The actual ZK proof
  verification (Noir UltraHonk) happens on-chain or in the Xochi oracle.
  This module verifies the oracle's signed result: type, expiry, issuer,
  structural integrity, and (the security-relevant part) that the
  attestation's ECDSA `signature` actually recovers to the claimed `issuer`
  and that the issuer is on the caller's trusted allowlist.

  Without the signature check a caller could forge an attestation by simply
  naming a trusted `issuer`, inflating its `Raxol.Payments.Zksar.TrustScore`
  to claim a higher `Raxol.Payments.PrivacyTier` and a lower settlement fee
  tier than earned (and defeat the local sanctions/AML gate this module is
  named for). `verify/2` therefore recovers the signer and requires
  `signer == issuer in allowed_issuers` by default.

  > #### Provisional digest scheme {: .warning}
  >
  > `attestation_digest/1` defines the bytes the oracle is assumed to sign
  > (an EIP-191 `personal_sign` over the canonical attestation fields). This
  > encoding has NOT yet been confirmed byte-for-byte against the live Xochi
  > oracle signer. Verification fails closed on any mismatch, so a wrong
  > scheme rejects real attestations (safe) rather than accepting forged ones.
  > The scheme must still be reconciled with Xochi, and a real on-chain
  > vector added, before enabling signature checks against production data.

  ## Proof Types

  Six ZK proof types from Noir circuits:

  | Code | Type             | Purpose                                    |
  | ---- | ---------------- | ------------------------------------------ |
  | 0x01 | Compliance       | Score below jurisdiction threshold          |
  | 0x02 | Risk Score       | Score comparison without revealing score    |
  | 0x03 | Pattern          | No structuring/velocity anomalies          |
  | 0x04 | Attestation      | Valid credential exists                    |
  | 0x05 | Membership       | Address in whitelist                       |
  | 0x06 | Non-Membership   | NOT on sanctions list                      |
  """

  @type proof_type ::
          :compliance
          | :risk_score
          | :pattern
          | :attestation
          | :membership
          | :non_membership

  @type proof :: %{
          type_code: pos_integer(),
          issuer: String.t(),
          subject: String.t(),
          issued_at: integer(),
          expires_at: integer(),
          signature: String.t(),
          payload: binary()
        }

  @type verified_proof :: %{
          type: proof_type(),
          subject: String.t(),
          issuer: String.t(),
          issued_at: integer(),
          expires_at: integer(),
          valid: true
        }

  @type verification_error ::
          :expired
          | :unknown_type
          | :invalid_issuer
          | :issuer_required
          | :invalid_signature
          | :malformed

  @proof_types %{
    0x01 => :compliance,
    0x02 => :risk_score,
    0x03 => :pattern,
    0x04 => :attestation,
    0x05 => :membership,
    0x06 => :non_membership
  }

  @proof_type_codes Map.new(@proof_types, fn {k, v} -> {v, k} end)

  @doc """
  Verify a single attestation proof.

  Checks type code, expiry, structural integrity, the issuer allowlist, and
  (by default) that the ECDSA `signature` recovers to the claimed `issuer`.

  ## Options

  - `:now` -- override current time (unix seconds) for testing.
  - `:allowed_issuers` -- list of trusted oracle addresses (case-insensitive).
    Required when `:verify_signature` is on (the default): a missing allowlist
    fails closed with `:issuer_required`, since trust cannot be established
    without knowing which signer is trusted.
  - `:verify_signature` -- recover the signer from `signature` and require it
    to equal `issuer`. Defaults to `true`. Pass `false` only for structural
    checks where no real signature is available (tests, the pre-reconciliation
    transition window); this restores the old lenient allowlist behavior and
    is NOT safe against forgery.

  ## Errors

  `:malformed | :expired | :unknown_type | :issuer_required | :invalid_issuer
  | :invalid_signature`
  """
  @spec verify(proof(), keyword()) ::
          {:ok, verified_proof()} | {:error, verification_error()}
  def verify(proof, opts \\ [])

  def verify(%{type_code: code} = proof, opts)
      when is_map_key(@proof_types, code) do
    now = Keyword.get(opts, :now, :os.system_time(:second))

    with :ok <- check_structure(proof),
         :ok <- check_expiry(proof, now),
         :ok <- check_issuer(proof, opts),
         :ok <- check_signature(proof, opts) do
      {:ok,
       %{
         type: @proof_types[code],
         subject: proof.subject,
         issuer: proof.issuer,
         issued_at: proof.issued_at,
         expires_at: proof.expires_at,
         valid: true
       }}
    end
  end

  def verify(%{type_code: _code}, _opts), do: {:error, :unknown_type}
  def verify(_proof, _opts), do: {:error, :malformed}

  @doc """
  Verify a batch of proofs. Does not fail-fast.

  Returns `{verified, errors}` where errors are `{proof, reason}` tuples.
  """
  @spec verify_batch([proof()], keyword()) ::
          {[verified_proof()], [{proof(), verification_error()}]}
  def verify_batch(proofs, opts \\ []) when is_list(proofs) do
    Enum.reduce(proofs, {[], []}, fn proof, {verified, errors} ->
      case verify(proof, opts) do
        {:ok, vp} -> {[vp | verified], errors}
        {:error, reason} -> {verified, [{proof, reason} | errors]}
      end
    end)
    |> then(fn {v, e} -> {Enum.reverse(v), Enum.reverse(e)} end)
  end

  @doc "Look up proof type name from numeric code."
  @spec proof_type_name(pos_integer()) :: {:ok, proof_type()} | :error
  def proof_type_name(code) when is_map_key(@proof_types, code),
    do: {:ok, @proof_types[code]}

  def proof_type_name(_code), do: :error

  @doc "Look up numeric code from proof type name."
  @spec proof_type_code(proof_type()) :: {:ok, pos_integer()} | :error
  def proof_type_code(name) when is_map_key(@proof_type_codes, name),
    do: {:ok, @proof_type_codes[name]}

  def proof_type_code(_name), do: :error

  @doc "All known proof type names."
  @spec proof_types() :: [proof_type()]
  def proof_types, do: Map.values(@proof_types)

  @doc """
  The 32-byte digest the oracle is assumed to sign for an attestation.

  An EIP-191 `personal_sign` over the canonical, newline-joined attestation
  fields (a domain tag, then type code, issuer, subject, issued-at,
  expires-at, and the lowercase-hex payload). Exposed so the Xochi oracle and
  any local signer can reproduce the exact bytes, and so the scheme can be
  reconciled across repos (see the module note on the provisional scheme).
  """
  @spec attestation_digest(proof()) :: <<_::256>>
  def attestation_digest(%{
        type_code: type_code,
        issuer: issuer,
        subject: subject,
        issued_at: issued_at,
        expires_at: expires_at,
        payload: payload
      }) do
    message =
      Enum.join(
        [
          "ZKSAR-Attestation-v1",
          Integer.to_string(type_code),
          Raxol.Payments.EIP712.normalize_address(issuer),
          Raxol.Payments.EIP712.normalize_address(subject),
          Integer.to_string(issued_at),
          Integer.to_string(expires_at),
          Base.encode16(payload, case: :lower)
        ],
        "\n"
      )

    Raxol.Payments.Eip191.digest(message)
  end

  @doc """
  Parse a proof from Xochi API JSON (camelCase).

  Expected keys: `typeCode`, `issuer`, `subject`, `issuedAt`, `expiresAt`,
  `signature`, `payload` (hex-encoded).
  """
  @spec from_json(map()) :: {:ok, proof()} | {:error, :malformed}
  def from_json(%{
        "typeCode" => type_code,
        "issuer" => issuer,
        "subject" => subject,
        "issuedAt" => issued_at,
        "expiresAt" => expires_at,
        "signature" => signature,
        "payload" => payload_hex
      })
      when is_integer(type_code) and is_binary(issuer) and is_binary(subject) and
             is_integer(issued_at) and is_integer(expires_at) and
             is_binary(signature) and
             is_binary(payload_hex) do
    case Base.decode16(payload_hex, case: :mixed) do
      {:ok, payload} ->
        {:ok,
         %{
           type_code: type_code,
           issuer: issuer,
           subject: subject,
           issued_at: issued_at,
           expires_at: expires_at,
           signature: signature,
           payload: payload
         }}

      :error ->
        {:error, :malformed}
    end
  end

  def from_json(_), do: {:error, :malformed}

  # -- Private --

  defp check_structure(%{subject: s, issuer: i, signature: sig})
       when is_binary(s) and byte_size(s) > 0 and
              is_binary(i) and byte_size(i) > 0 and
              is_binary(sig) and byte_size(sig) > 0,
       do: :ok

  defp check_structure(_), do: {:error, :malformed}

  defp check_expiry(%{expires_at: exp}, now) when is_integer(exp) and exp > now,
    do: :ok

  defp check_expiry(_, _), do: {:error, :expired}

  defp check_issuer(proof, opts) do
    case Keyword.get(opts, :allowed_issuers) do
      issuers when is_list(issuers) ->
        if Enum.any?(issuers, &addr_eq?(&1, proof.issuer)),
          do: :ok,
          else: {:error, :invalid_issuer}

      nil ->
        # Trust cannot be established without a trusted-issuer allowlist. Fail
        # closed by default; only the explicit signature-disabled escape hatch
        # restores the old lenient "accept any issuer" behavior.
        if Keyword.get(opts, :verify_signature, true),
          do: {:error, :issuer_required},
          else: :ok
    end
  end

  defp check_signature(proof, opts) do
    if Keyword.get(opts, :verify_signature, true) do
      case recover_signer(attestation_digest(proof), proof.signature) do
        {:ok, recovered} ->
          if addr_eq?(recovered, proof.issuer),
            do: :ok,
            else: {:error, :invalid_signature}

        :error ->
          {:error, :invalid_signature}
      end
    else
      :ok
    end
  end

  defp recover_signer(digest, signature) do
    with {:ok, {r, s, recovery_id}} <- decode_signature(signature),
         {:ok, pubkey} <- ExSecp256k1.recover(digest, r, s, recovery_id) do
      {:ok, Raxol.Payments.EIP712.address_from_pubkey(pubkey)}
    else
      _ -> :error
    end
  end

  defp decode_signature("0x" <> hex), do: decode_signature(hex)

  defp decode_signature(hex) when is_binary(hex) and byte_size(hex) == 130 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>} ->
        {:ok, {r, s, Raxol.Payments.Eip191.normalize_recovery_id(v)}}

      _ ->
        :error
    end
  end

  defp decode_signature(_), do: :error

  defp addr_eq?(a, b) when is_binary(a) and is_binary(b),
    do:
      Raxol.Payments.EIP712.normalize_address(a) ==
        Raxol.Payments.EIP712.normalize_address(b)

  defp addr_eq?(_, _), do: false
end
