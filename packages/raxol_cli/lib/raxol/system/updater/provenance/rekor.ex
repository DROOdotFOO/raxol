defmodule Raxol.System.Updater.Provenance.Rekor do
  @moduledoc """
  The Rekor (v1) transparency-log entry of a Sigstore bundle, and what
  proves it:

    * the entry's canonicalized body is a `dsse` 0.0.1 entry for exactly
      this envelope, signed by exactly this certificate;
    * an RFC 6962 inclusion proof from that body's leaf hash to the root
      hash of a checkpoint the log signed;
    * the signed entry timestamp (the inclusion promise), the log's
      signature over the body, integrated time, log id and log index.

  The integrated time is only trusted once the signed entry timestamp
  verifies; `verify/4` is what makes it so.
  """

  import Bitwise

  alias Jason.OrderedObject
  alias Raxol.System.Updater.Provenance.{Crypto, Dsse, TrustedRoot}

  @checkpoint_signature_prefix "\u2014 "

  # Each field of the bundle's tlog entry: its JSON path and how it parses.
  @entry_fields [
    log_id: {["logId", "keyId"], :base64},
    log_index: {["logIndex"], :uint},
    integrated_time: {["integratedTime"], :uint},
    body: {["canonicalizedBody"], :base64},
    signed_entry_timestamp:
      {["inclusionPromise", "signedEntryTimestamp"], :base64}
  ]

  @proof_fields [
    log_index: {["inclusionProof", "logIndex"], :uint},
    tree_size: {["inclusionProof", "treeSize"], :uint},
    root_hash: {["inclusionProof", "rootHash"], :base64},
    hashes: {["inclusionProof", "hashes"], :hashes},
    checkpoint: {["inclusionProof", "checkpoint", "envelope"], :string}
  ]

  @type proof :: %{
          log_index: non_neg_integer(),
          tree_size: non_neg_integer(),
          root_hash: binary(),
          hashes: [binary()],
          checkpoint: String.t()
        }

  @type t :: %__MODULE__{
          log_id: binary(),
          log_index: non_neg_integer(),
          integrated_time: non_neg_integer(),
          body: binary(),
          signed_entry_timestamp: binary(),
          proof: proof()
        }

  @enforce_keys [
    :log_id,
    :log_index,
    :integrated_time,
    :body,
    :signed_entry_timestamp,
    :proof
  ]
  defstruct @enforce_keys

  @doc "The bundle's one `dsse` 0.0.1 tlog entry."
  @spec entry(term()) :: {:ok, t()} | {:error, term()}
  def entry([entry]), do: parse(entry)
  def entry([]), do: {:error, :missing_tlog_entry}

  def entry(entries) when is_list(entries),
    do: {:error, {:unexpected_tlog_entries, length(entries)}}

  def entry(_entries), do: {:error, {:malformed_tlog_entry, "tlogEntries"}}

  defp parse(
         %{"kindVersion" => %{"kind" => "dsse", "version" => "0.0.1"}} = entry
       ) do
    with {:ok, fields} <- fields(entry, @entry_fields),
         {:ok, proof} <- fields(entry, @proof_fields) do
      {:ok, struct!(__MODULE__, Map.put(fields, :proof, proof))}
    end
  end

  defp parse(%{"kindVersion" => %{"kind" => kind, "version" => version}}),
    do: {:error, {:unsupported_tlog_entry, kind, version}}

  defp parse(_entry), do: {:error, {:malformed_tlog_entry, "kindVersion"}}

  defp fields(entry, specs) do
    Enum.reduce_while(specs, {:ok, %{}}, fn {key, {path, type}}, {:ok, acc} ->
      case entry |> dig(path) |> parse_value(type) do
        {:ok, value} ->
          {:cont, {:ok, Map.put(acc, key, value)}}

        :error ->
          {:halt, {:error, {:malformed_tlog_entry, Enum.join(path, ".")}}}
      end
    end)
  end

  defp dig(value, []), do: value
  defp dig(%{} = map, [key | path]), do: map |> Map.get(key) |> dig(path)
  defp dig(_value, _path), do: nil

  defp parse_value(value, :base64), do: Crypto.decode64(value)
  defp parse_value(value, :uint), do: Crypto.parse_uint(value)
  defp parse_value(value, :string) when is_binary(value), do: {:ok, value}

  defp parse_value(hashes, :hashes) when is_list(hashes),
    do: decode_hashes(hashes, [])

  defp parse_value(_value, _type), do: :error

  # Every audit-path hash is a 32-byte SHA-256.
  defp decode_hashes([], acc), do: {:ok, Enum.reverse(acc)}

  defp decode_hashes([hash | rest], acc) do
    case Crypto.decode64(hash) do
      {:ok, <<_::binary-32>> = decoded} -> decode_hashes(rest, [decoded | acc])
      _other -> :error
    end
  end

  @doc """
  Verifies the entry against `envelope`, the leaf certificate `leaf_der`,
  and the Rekor keys of the trusted root.
  """
  @spec verify(t(), Dsse.t(), binary(), [TrustedRoot.log()]) ::
          :ok | {:error, term()}
  def verify(%__MODULE__{} = entry, %Dsse{} = envelope, leaf_der, tlogs) do
    with {:ok, log} <- trusted_log(entry, tlogs),
         :ok <- commits_to(entry.body, envelope, leaf_der),
         :ok <- verify_inclusion(entry),
         :ok <- verify_checkpoint(entry.proof, log) do
      verify_signed_entry_timestamp(entry, log)
    end
  end

  defp trusted_log(entry, tlogs) do
    case TrustedRoot.find_log(tlogs, entry.log_id, entry.integrated_time) do
      {:ok, log} ->
        {:ok, log}

      :error ->
        {:error, {:untrusted_transparency_log, Base.encode64(entry.log_id)}}
    end
  end

  # --- the entry body commits to this envelope and certificate ---

  defp commits_to(body, envelope, leaf_der) do
    case Jason.decode(body) do
      {:ok, %{"kind" => "dsse", "apiVersion" => "0.0.1", "spec" => %{} = spec}} ->
        commits_to_spec(spec, envelope, leaf_der)

      _other ->
        {:error, {:tlog_entry_mismatch, :kind}}
    end
  end

  defp commits_to_spec(spec, envelope, leaf_der) do
    cond do
      Map.get(spec, "payloadHash") != sha256_hash(envelope.payload) ->
        {:error, {:tlog_entry_mismatch, :payload_hash}}

      Map.get(spec, "envelopeHash") !=
          sha256_hash(Dsse.canonical_json(envelope)) ->
        {:error, {:tlog_entry_mismatch, :envelope_hash}}

      not same_signatures?(Map.get(spec, "signatures"), envelope, leaf_der) ->
        {:error, {:tlog_entry_mismatch, :signatures}}

      true ->
        :ok
    end
  end

  defp sha256_hash(data),
    do: %{"algorithm" => "sha256", "value" => Crypto.hex(Crypto.sha256(data))}

  # One entry signature per envelope signature: the same bytes, and the
  # leaf certificate (PEM, base64) as its verifier.
  defp same_signatures?(signatures, envelope, leaf_der)
       when is_list(signatures) and
              length(signatures) == length(envelope.signatures) do
    envelope.signatures
    |> Enum.zip(signatures)
    |> Enum.all?(fn {%{sig: sig}, entry_signature} ->
      entry_signature?(entry_signature, sig, leaf_der)
    end)
  end

  defp same_signatures?(_signatures, _envelope, _leaf_der), do: false

  defp entry_signature?(
         %{"signature" => signature, "verifier" => verifier},
         sig,
         leaf_der
       ) do
    with {:ok, ^sig} <- Crypto.decode64(signature),
         {:ok, pem} <- Crypto.decode64(verifier),
         [{:Certificate, ^leaf_der, :not_encrypted}] <-
           :public_key.pem_decode(pem) do
      true
    else
      _other -> false
    end
  end

  defp entry_signature?(_entry_signature, _sig, _leaf_der), do: false

  # --- RFC 6962 / RFC 9162 section 2.1.3.2 inclusion proof ---

  defp verify_inclusion(%__MODULE__{body: body, proof: proof}) do
    leaf_hash = Crypto.sha256([<<0>>, body])

    if proof.log_index < proof.tree_size and
         root_from_path(
           proof.log_index,
           proof.tree_size - 1,
           leaf_hash,
           proof.hashes
         ) ==
           {:ok, proof.root_hash},
       do: :ok,
       else: {:error, :inclusion_proof_invalid}
  end

  defp root_from_path(_index, 0, hash, []), do: {:ok, hash}
  defp root_from_path(_index, _last, _hash, []), do: :error
  defp root_from_path(_index, 0, _hash, [_ | _]), do: :error

  defp root_from_path(index, last, hash, [sibling | path]) do
    if (index &&& 1) == 1 or index == last do
      {index, last} =
        if (index &&& 1) == 0,
          do: skip_right_edge(index, last),
          else: {index, last}

      root_from_path(index >>> 1, last >>> 1, node_hash(sibling, hash), path)
    else
      root_from_path(index >>> 1, last >>> 1, node_hash(hash, sibling), path)
    end
  end

  defp skip_right_edge(index, last) when (index &&& 1) == 0 and index != 0,
    do: skip_right_edge(index >>> 1, last >>> 1)

  defp skip_right_edge(index, last), do: {index, last}

  defp node_hash(left, right), do: Crypto.sha256([<<1>>, left, right])

  # --- the checkpoint (a signed note) the proof's root hash is taken from ---

  defp verify_checkpoint(proof, log) do
    with {:ok, text, signatures} <- split_note(proof.checkpoint),
         true <-
           Enum.any?(signatures, &note_signed?(&1, text, log)) || :unsigned,
         [_origin, size, root | _extensions] <-
           String.split(text, "\n", trim: true) do
      checkpoint_matches(proof, size, root)
    else
      :unsigned ->
        {:error, :checkpoint_signature_invalid}

      _malformed ->
        {:error, {:malformed_tlog_entry, "inclusionProof.checkpoint.envelope"}}
    end
  end

  # The signed tree the proof was computed against.
  defp checkpoint_matches(proof, size, root) do
    cond do
      size != Integer.to_string(proof.tree_size) ->
        {:error, {:checkpoint_mismatch, :tree_size}}

      Crypto.decode64(root) != {:ok, proof.root_hash} ->
        {:error, {:checkpoint_mismatch, :root_hash}}

      true ->
        :ok
    end
  end

  # The signed text is everything up to and including the newline before
  # the blank line; each signature line is `— <name> <base64(key hint ||
  # signature)>`.
  defp split_note(note) do
    case String.split(note, "\n\n", parts: 2) do
      [text, signatures] ->
        {:ok, text <> "\n", String.split(signatures, "\n", trim: true)}

      _no_signatures ->
        :error
    end
  end

  # Rekor's key hint is the first four bytes of its log id, the SHA-256 of
  # its public key.
  defp note_signed?(@checkpoint_signature_prefix <> line, text, log) do
    <<hint::binary-4, _rest::binary>> = log.log_id

    with [_name, encoded] <- String.split(line, " "),
         {:ok, <<^hint::binary-4, signature::binary>>} <-
           Crypto.decode64(encoded) do
      Crypto.verify(text, log.digest, signature, log.key)
    else
      _other -> false
    end
  end

  defp note_signed?(_line, _text, _log), do: false

  # --- the signed entry timestamp ---

  defp verify_signed_entry_timestamp(entry, log) do
    payload =
      Jason.encode!(
        OrderedObject.new([
          {"body", Base.encode64(entry.body)},
          {"integratedTime", entry.integrated_time},
          {"logID", Crypto.hex(entry.log_id)},
          {"logIndex", entry.log_index}
        ])
      )

    if Crypto.verify(
         payload,
         log.digest,
         entry.signed_entry_timestamp,
         log.key
       ),
       do: :ok,
       else: {:error, :signed_entry_timestamp_invalid}
  end
end
