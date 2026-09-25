defmodule Raxol.System.Updater.Provenance.Sct do
  @moduledoc """
  Certificate transparency for a Fulcio leaf: the signed certificate
  timestamps (SCTs, RFC 6962) Fulcio embeds in every leaf it issues.

  An SCT signs the precertificate: the leaf's `TBSCertificate` without the
  SCT-list extension, plus the SHA-256 of the issuer's public key. At
  least one SCT must verify against a CT log key the trusted root trusts
  at the SCT's timestamp.
  """

  require Record

  alias Raxol.System.Updater.Provenance.{Certificate, Crypto, TrustedRoot}

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(
    :cert,
    :Certificate,
    Record.extract(:Certificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :tbs,
    :TBSCertificate,
    Record.extract(:TBSCertificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: @hrl)
  )

  @sct_list {1, 3, 6, 1, 4, 1, 11_129, 2, 4, 2}
  @hash_algorithms %{4 => :sha256, 5 => :sha384, 6 => :sha512}

  @doc """
  `:ok` when one of the leaf's embedded SCTs verifies; `issuer_der` is the
  certificate that issued the leaf.
  """
  @spec verify(Certificate.t(), binary(), [TrustedRoot.log()]) ::
          :ok | {:error, term()}
  def verify(%Certificate{der: der}, issuer_der, ctlogs) do
    with {:ok, precert_tbs, scts} <- precertificate(der),
         {:ok, issuer_key_hash} <- issuer_key_hash(issuer_der) do
      if Enum.any?(scts, &verified?(&1, precert_tbs, issuer_key_hash, ctlogs)),
        do: :ok,
        else: {:error, :sct_not_verified}
    end
  end

  # The leaf's TBSCertificate re-encoded without the SCT list, and the SCTs.
  defp precertificate(der) do
    tbs = der |> :public_key.pkix_decode_cert(:plain) |> cert(:tbsCertificate)
    {sct_extensions, others} = Enum.split_with(extensions(tbs), &sct_list?/1)

    with [extension(extnValue: value)] <- sct_extensions,
         {:ok, list} <- Crypto.der_content(0x04, value),
         {:ok, scts} <- parse_list(list) do
      {:ok,
       :public_key.der_encode(:TBSCertificate, tbs(tbs, extensions: others)),
       scts}
    else
      _missing_or_malformed -> {:error, :sct_missing}
    end
  rescue
    _malformed in [MatchError, ErlangError, ArgumentError, FunctionClauseError] ->
      {:error, :sct_missing}
  end

  defp extensions(tbs) do
    case tbs(tbs, :extensions) do
      extensions when is_list(extensions) -> extensions
      _none -> []
    end
  end

  defp sct_list?(extension(extnID: @sct_list)), do: true
  defp sct_list?(_extension), do: false

  defp issuer_key_hash(issuer_der) do
    spki =
      issuer_der
      |> :public_key.pkix_decode_cert(:plain)
      |> cert(:tbsCertificate)
      |> tbs(:subjectPublicKeyInfo)

    {:ok, Crypto.sha256(:public_key.der_encode(:SubjectPublicKeyInfo, spki))}
  rescue
    _malformed in [MatchError, ErlangError, ArgumentError, FunctionClauseError] ->
      {:error, :sct_missing}
  end

  defp parse_list(<<length::16, scts::binary-size(length)>>),
    do: parse_scts(scts, [])

  defp parse_list(_list), do: :error

  defp parse_scts(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_scts(<<length::16, sct::binary-size(length), rest::binary>>, acc) do
    case parse_sct(sct) do
      {:ok, parsed} -> parse_scts(rest, [parsed | acc])
      :error -> :error
    end
  end

  defp parse_scts(_bytes, _acc), do: :error

  # SignedCertificateTimestamp v1 (RFC 6962 section 3.2).
  defp parse_sct(
         <<0, log_id::binary-32, timestamp::64, ext_length::16,
           extensions::binary-size(ext_length), hash, _signature_algorithm,
           sig_length::16, signature::binary-size(sig_length)>>
       ),
       do:
         {:ok,
          %{
            log_id: log_id,
            timestamp: timestamp,
            extensions: extensions,
            digest: Map.get(@hash_algorithms, hash),
            signature: signature
          }}

  defp parse_sct(_sct), do: :error

  defp verified?(%{digest: nil}, _tbs, _issuer_key_hash, _ctlogs), do: false

  defp verified?(sct, tbs, issuer_key_hash, ctlogs) do
    case TrustedRoot.find_log(ctlogs, sct.log_id, div(sct.timestamp, 1000)) do
      {:ok, log} ->
        signed =
          <<0, 0, sct.timestamp::64, 1::16, issuer_key_hash::binary,
            byte_size(tbs)::24, tbs::binary, byte_size(sct.extensions)::16,
            sct.extensions::binary>>

        Crypto.verify(signed, sct.digest, sct.signature, log.key)

      :error ->
        false
    end
  end
end
