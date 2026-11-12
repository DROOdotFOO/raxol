defmodule Raxol.System.Updater.Provenance.Certificate do
  @moduledoc """
  The Fulcio leaf certificate of a Sigstore bundle: its key, validity,
  signer identity, and chain to a pinned Fulcio root.

  A Fulcio leaf lives for about ten minutes, so the chain is validated at
  the time Rekor recorded the entry (the integrated time), not now.

  The identity comes from Fulcio's certificate extensions
  (<https://github.com/sigstore/fulcio/blob/main/docs/oid-info.md>):
  `1.3.6.1.4.1.57264.1.1` (issuer, raw string, deprecated) and
  `1.3.6.1.4.1.57264.1.8` onwards (DER `UTF8String`s).
  """

  require Record

  alias Raxol.System.Updater.Provenance.{Crypto, TrustedRoot}

  @hrl "public_key/include/public_key.hrl"
  Record.defrecordp(
    :otp_cert,
    :OTPCertificate,
    Record.extract(:OTPCertificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :otp_tbs,
    :OTPTBSCertificate,
    Record.extract(:OTPTBSCertificate, from_lib: @hrl)
  )

  Record.defrecordp(
    :otp_spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  Record.defrecordp(
    :key_algorithm,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(
    :extension,
    :Extension,
    Record.extract(:Extension, from_lib: @hrl)
  )

  Record.defrecordp(
    :validity,
    :Validity,
    Record.extract(:Validity, from_lib: @hrl)
  )

  @ec_public_key {1, 2, 840, 10_045, 2, 1}
  @curve_digests %{
    {1, 2, 840, 10_045, 3, 1, 7} => :sha256,
    {1, 3, 132, 0, 34} => :sha384,
    {1, 3, 132, 0, 35} => :sha512
  }

  @subject_alt_name {2, 5, 29, 17}
  @ext_key_usage {2, 5, 29, 37}
  @code_signing {1, 3, 6, 1, 5, 5, 7, 3, 3}

  # `1.3.6.1.4.1.57264.1.1` is a raw string; `.1.8` onwards are DER UTF8Strings.
  @issuer_v1 {1, 3, 6, 1, 4, 1, 57_264, 1, 1}
  @der_fields %{
    8 => :issuer,
    9 => :build_signer_uri,
    11 => :runner_environment,
    12 => :source_repository_uri,
    13 => :source_repository_digest,
    14 => :source_repository_ref
  }

  @type identity :: %{
          san: [String.t()],
          issuer: String.t() | nil,
          build_signer_uri: String.t() | nil,
          runner_environment: String.t() | nil,
          source_repository_uri: String.t() | nil,
          source_repository_digest: String.t() | nil,
          source_repository_ref: String.t() | nil
        }

  @type t :: %__MODULE__{
          der: binary(),
          otp: tuple(),
          not_before: integer(),
          not_after: integer()
        }

  @enforce_keys [:der, :otp, :not_before, :not_after]
  defstruct @enforce_keys

  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(der) do
    otp = :public_key.pkix_decode_cert(der, :otp)

    case validity_window(otp) do
      {:ok, {not_before, not_after}} ->
        {:ok,
         %__MODULE__{
           der: der,
           otp: otp,
           not_before: not_before,
           not_after: not_after
         }}

      :error ->
        {:error, {:malformed_bundle, :certificate}}
    end
  rescue
    _malformed in [
      MatchError,
      ErlangError,
      ArgumentError,
      FunctionClauseError,
      CaseClauseError
    ] ->
      {:error, {:malformed_bundle, :certificate}}
  end

  @doc "Whether unix time `time` is inside the certificate's validity period."
  @spec valid_at?(t(), integer()) :: boolean()
  def valid_at?(%__MODULE__{not_before: from, not_after: until}, time),
    do: from <= time and time <= until

  @doc "The certificate's ECDSA key and the digest its curve signs with."
  @spec public_key(t()) :: {:ok, term(), atom()} | {:error, term()}
  def public_key(%__MODULE__{otp: otp}) do
    spki = otp |> otp_cert(:tbsCertificate) |> otp_tbs(:subjectPublicKeyInfo)

    case {otp_spki(spki, :algorithm), otp_spki(spki, :subjectPublicKey)} do
      {key_algorithm(
         algorithm: @ec_public_key,
         parameters: {:namedCurve, curve}
       ), point}
      when is_map_key(@curve_digests, curve) ->
        {:ok, {point, {:namedCurve, curve}}, Map.fetch!(@curve_digests, curve)}

      {key_algorithm(algorithm: algorithm), _key} ->
        {:error, {:unsupported_certificate_key, algorithm}}
    end
  end

  @doc "Whether the certificate's extended key usage includes code signing."
  @spec code_signing?(t()) :: boolean()
  def code_signing?(%__MODULE__{} = cert) do
    case extension_value(cert, @ext_key_usage) do
      usages when is_list(usages) -> @code_signing in usages
      _other -> false
    end
  end

  @doc """
  Who the certificate was issued to: its URI SANs and the Fulcio claims a
  release policy checks. A claim the certificate lacks is `nil`.
  """
  @spec identity(t()) :: identity()
  def identity(%__MODULE__{} = cert) do
    fulcio = fulcio_claims(cert)

    %{
      san: san_uris(cert),
      issuer: fulcio[:issuer] || raw_issuer(cert),
      build_signer_uri: fulcio[:build_signer_uri],
      runner_environment: fulcio[:runner_environment],
      source_repository_uri: fulcio[:source_repository_uri],
      source_repository_digest: fulcio[:source_repository_digest],
      source_repository_ref: fulcio[:source_repository_ref]
    }
  end

  @doc """
  Validates the certificate up to a pinned Fulcio root, as of unix time
  `time`: each certificate in the chain must be valid then, and the
  certificate authority must be trusted then. Returns the DER of the
  certificate that issued the leaf.
  """
  @spec verify_chain(t(), integer(), [TrustedRoot.certificate_authority()]) ::
          {:ok, binary()} | {:error, term()}
  def verify_chain(%__MODULE__{} = leaf, time, authorities) do
    authorities
    |> Enum.filter(&TrustedRoot.valid_at?(&1.valid_for, time))
    |> Enum.reduce_while(
      {:error, {:certificate_chain_invalid, :no_trusted_authority}},
      fn authority, error ->
        case validate_path(leaf, authority.chain, time) do
          {:ok, _result} -> {:halt, {:ok, hd(authority.chain)}}
          {:error, reason} -> {:cont, keep_first_error(error, reason)}
        end
      end
    )
  end

  defp keep_first_error(
         {:error, {:certificate_chain_invalid, :no_trusted_authority}},
         reason
       ),
       do: {:error, {:certificate_chain_invalid, reason}}

  defp keep_first_error(error, _reason), do: error

  # `chain` is leaf-most first and ends with the root, which is the trust
  # anchor. The certificates between them come from the pinned root too;
  # the path to validate runs from the anchor's child down to the leaf.
  defp validate_path(leaf, chain, time) do
    anchor = List.last(chain)
    path = Enum.reverse([leaf.der | Enum.drop(chain, -1)])

    with {:ok, anchor_cert} <- decode(anchor),
         true <-
           valid_at?(anchor_cert, time) ||
             {:error, :root_not_valid_at_integrated_time} do
      :public_key.pkix_path_validation(anchor, path,
        verify_fun: {&verify_event/3, %{time: time, leaf: leaf.otp}}
      )
    end
  rescue
    _malformed in [MatchError, ErlangError, ArgumentError, FunctionClauseError] ->
      {:error, :malformed_chain}
  end

  # `pkix_path_validation/3` checks validity against the clock; here each
  # certificate is instead checked against the integrated time.
  defp verify_event(cert, {:bad_cert, :cert_expired}, state),
    do: valid_then(cert, state)

  # OTP refuses a CA certificate whose extended key usage (Fulcio's
  # intermediate carries code signing) lacks a matching key usage. The CA
  # certificates in the path are the pinned ones, so only the leaf is held
  # to it, and the leaf's code-signing usage is checked by `code_signing?/1`.
  defp verify_event(
         cert,
         {:bad_cert, {:key_usage_mismatch, _usages}} = event,
         state
       ) do
    if cert == state.leaf, do: {:fail, event}, else: {:valid, state}
  end

  defp verify_event(_cert, {:bad_cert, reason}, _state), do: {:fail, reason}

  defp verify_event(_cert, {:extension, _extension}, state),
    do: {:unknown, state}

  defp verify_event(cert, valid, state) when valid in [:valid, :valid_peer],
    do: valid_then(cert, state)

  defp valid_then(cert, state) do
    case validity_window(cert) do
      {:ok, {from, until}} when from <= state.time and state.time <= until ->
        {:valid, state}

      _expired ->
        {:fail, :not_valid_at_integrated_time}
    end
  end

  defp validity_window(otp) do
    validity(notBefore: not_before, notAfter: not_after) =
      otp |> otp_cert(:tbsCertificate) |> otp_tbs(:validity)

    with {:ok, from} <- Crypto.x509_time_to_unix(not_before),
         {:ok, until} <- Crypto.x509_time_to_unix(not_after) do
      {:ok, {from, until}}
    end
  end

  defp extensions(%__MODULE__{otp: otp}) do
    case otp |> otp_cert(:tbsCertificate) |> otp_tbs(:extensions) do
      extensions when is_list(extensions) -> extensions
      _none -> []
    end
  end

  defp extension_value(cert, oid) do
    Enum.find_value(extensions(cert), fn
      extension(extnID: ^oid, extnValue: value) -> value
      _other -> nil
    end)
  end

  defp san_uris(cert) do
    case extension_value(cert, @subject_alt_name) do
      names when is_list(names) ->
        for {:uniformResourceIdentifier, uri} <- names, do: to_string(uri)

      _other ->
        []
    end
  end

  defp raw_issuer(cert) do
    case extension_value(cert, @issuer_v1) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp fulcio_claims(cert) do
    for extension(extnID: oid, extnValue: value) <- extensions(cert),
        {:ok, field} <- [fulcio_field(oid)],
        {:ok, string} <- [Crypto.der_content(0x0C, value)],
        into: %{},
        do: {field, string}
  end

  defp fulcio_field({1, 3, 6, 1, 4, 1, 57_264, 1, n}),
    do: Map.fetch(@der_fields, n)

  defp fulcio_field(_oid), do: :error
end
