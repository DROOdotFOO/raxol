defmodule Raxol.System.Updater.Provenance do
  @moduledoc """
  Verifies a release asset against its Sigstore provenance bundle, natively
  (`:public_key`, `:crypto`, Jason), with no `gh` or `cosign` involved.

  `raxol-cli-v*` releases carry `raxol-cli-attestation.sigstore.json`,
  written by `actions/attest` in `.github/workflows/release-raxol-cli.yml`:
  a `application/vnd.dev.sigstore.bundle.v0.3+json` bundle holding a DSSE
  envelope with an in-toto SLSA provenance statement over the release
  binaries, the Fulcio certificate that signed it, and its Rekor entry.
  `verify/4` accepts an asset only when all of this holds:

    1. The Rekor integrated time falls inside the leaf certificate's
       validity period.
    2. The DSSE signature over the envelope's pre-authentication encoding
       verifies with the leaf certificate's ECDSA key.
    3. The leaf chains to a Fulcio root in the pinned trusted root, as of
       the integrated time, and carries the code-signing extended key usage.
    4. One of the leaf's embedded certificate-transparency SCTs verifies
       against a CT log key in the trusted root.
    5. The Rekor entry is a `dsse` 0.0.1 entry for this envelope (payload
       hash, envelope hash, signature) and this certificate; its RFC 6962
       inclusion proof reaches the root hash of a checkpoint signed by the
       pinned Rekor key; and its signed entry timestamp verifies, which is
       what makes the integrated time trustworthy.
    6. The certificate identity matches the `Provenance.Policy`: issuer,
       source repository, source ref, SAN (workflow at that ref), runner.
    7. The in-toto statement is SLSA provenance v1 and names the asset with
       the expected digest.

  Every failure is a distinct `{:error, reason}`; nothing raises.

  Not verified: RFC 3161 timestamps (the SET-verified integrated time is
  the time source, so a bundle without a Rekor v1 entry and its inclusion
  promise, such as a Rekor v2 one, is refused) and bundle versions other
  than v0.3. The trusted root is pinned at build time
  (`Provenance.TrustedRoot`), not refreshed over TUF.
  """

  alias Raxol.System.Updater.Provenance.{
    Certificate,
    Crypto,
    Dsse,
    Policy,
    Rekor,
    Sct,
    TrustedRoot
  }

  @bundle_media_type "application/vnd.dev.sigstore.bundle.v0.3+json"
  @in_toto_payload "application/vnd.in-toto+json"
  @statement_types [
    "https://in-toto.io/Statement/v1",
    "https://in-toto.io/Statement/v0.1"
  ]
  @slsa_provenance "https://slsa.dev/provenance/v1"

  @typedoc """
  The asset to find in the statement: its name, and a digest as the
  in-toto algorithm name and lowercase hex (e.g. `{"sha256", hex}`).
  """
  @type subject :: {String.t(), {String.t(), String.t()}}

  @type verified :: %{
          identity: Certificate.identity(),
          integrated_time: non_neg_integer(),
          log_index: non_neg_integer()
        }

  @doc """
  Verifies `bundle_json` for `subject` under `policy`.

  `opts[:trusted_root]` replaces the pinned `TrustedRoot.default/0`.
  """
  @spec verify(binary(), subject(), Policy.t(), keyword()) ::
          {:ok, verified()} | {:error, term()}
  def verify(bundle_json, subject, %Policy{} = policy, opts \\ []) do
    with :ok <- check_subject_input(subject),
         {:ok, root} <- trusted_root(opts),
         {:ok, bundle} <- decode(bundle_json),
         :ok <- verify_signing(bundle, root),
         identity = Certificate.identity(bundle.leaf),
         :ok <- Policy.check(identity, policy),
         :ok <- check_statement(bundle.envelope, subject) do
      {:ok,
       %{
         identity: identity,
         integrated_time: bundle.entry.integrated_time,
         log_index: bundle.entry.log_index
       }}
    end
  end

  # Checks 1-5: the envelope was signed by a Fulcio certificate while it
  # was valid, and the signing is on the transparency log.
  defp verify_signing(%{envelope: envelope, leaf: leaf, entry: entry}, root) do
    with :ok <- signed_while_valid(leaf, entry.integrated_time),
         :ok <- verify_envelope(envelope, leaf),
         :ok <- verify_certificate(leaf, entry.integrated_time, root) do
      Rekor.verify(entry, envelope, leaf.der, root.tlogs)
    end
  end

  defp verify_envelope(envelope, leaf) do
    with {:ok, key, digest} <- Certificate.public_key(leaf),
         do: Dsse.verify(envelope, key, digest)
  end

  defp verify_certificate(leaf, time, root) do
    with {:ok, issuer} <-
           Certificate.verify_chain(leaf, time, root.certificate_authorities),
         :ok <- code_signing(leaf) do
      Sct.verify(leaf, issuer, root.ctlogs)
    end
  end

  defp check_subject_input({name, {algorithm, digest}})
       when is_binary(name) and is_binary(algorithm) and is_binary(digest) do
    if Regex.match?(~r/\A[0-9a-fA-F]+\z/, digest),
      do: :ok,
      else: {:error, {:invalid_subject, name}}
  end

  defp check_subject_input(subject), do: {:error, {:invalid_subject, subject}}

  defp trusted_root(opts) do
    case Keyword.fetch(opts, :trusted_root) do
      {:ok, %TrustedRoot{} = root} -> {:ok, root}
      :error -> TrustedRoot.default()
    end
  end

  defp decode(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"mediaType" => @bundle_media_type} = bundle} ->
        contents(bundle)

      {:ok, %{"mediaType" => other}} ->
        {:error, {:unsupported_bundle_media_type, other}}

      {:ok, _other} ->
        {:error, {:malformed_bundle, :media_type}}

      {:error, _reason} ->
        {:error, {:malformed_bundle, :json}}
    end
  end

  defp decode(_json), do: {:error, {:malformed_bundle, :json}}

  defp contents(%{
         "dsseEnvelope" => envelope,
         "verificationMaterial" => %{
           "certificate" => %{"rawBytes" => raw},
           "tlogEntries" => entries
         }
       }) do
    with {:ok, envelope} <- Dsse.parse(envelope),
         {:ok, leaf} <- decode_certificate(raw),
         {:ok, entry} <- Rekor.entry(entries) do
      {:ok, %{envelope: envelope, leaf: leaf, entry: entry}}
    end
  end

  defp contents(_bundle), do: {:error, {:malformed_bundle, :content}}

  defp decode_certificate(raw) do
    case Crypto.decode64(raw) do
      {:ok, der} -> Certificate.decode(der)
      :error -> {:error, {:malformed_bundle, :certificate}}
    end
  end

  defp signed_while_valid(leaf, integrated_time) do
    if Certificate.valid_at?(leaf, integrated_time),
      do: :ok,
      else: {:error, :integrated_time_outside_certificate_validity}
  end

  defp code_signing(leaf) do
    if Certificate.code_signing?(leaf),
      do: :ok,
      else: {:error, :certificate_not_for_code_signing}
  end

  defp check_statement(
         %Dsse{payload_type: @in_toto_payload, payload: payload},
         subject
       ) do
    case Jason.decode(payload) do
      {:ok,
       %{
         "_type" => type,
         "predicateType" => @slsa_provenance,
         "subject" => subjects
       }}
      when type in @statement_types and is_list(subjects) ->
        find_subject(subjects, subject)

      {:ok, %{"predicateType" => other}} when other != @slsa_provenance ->
        {:error, {:unexpected_predicate_type, other}}

      _other ->
        {:error, :malformed_statement}
    end
  end

  defp check_statement(%Dsse{payload_type: other}, _subject),
    do: {:error, {:unsupported_payload_type, other}}

  defp find_subject(subjects, {name, {algorithm, digest}}) do
    expected = String.downcase(digest)

    case Enum.filter(subjects, &match?(%{"name" => ^name}, &1)) do
      [] ->
        {:error, {:subject_not_found, name}}

      named ->
        if Enum.any?(named, &(subject_digest(&1, algorithm) == expected)),
          do: :ok,
          else: {:error, {:subject_digest_mismatch, name}}
    end
  end

  defp subject_digest(%{"digest" => %{} = digests}, algorithm) do
    case Map.get(digests, algorithm) do
      value when is_binary(value) -> String.downcase(value)
      _other -> nil
    end
  end

  defp subject_digest(_subject, _algorithm), do: nil
end
