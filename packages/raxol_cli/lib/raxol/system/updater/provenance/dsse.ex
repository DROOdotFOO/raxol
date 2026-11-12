defmodule Raxol.System.Updater.Provenance.Dsse do
  @moduledoc """
  A DSSE envelope (<https://github.com/secure-systems-lab/dsse>) as a
  Sigstore bundle carries it: one signature over the pre-authentication
  encoding (PAE) of the payload type and payload.
  """

  alias Jason.OrderedObject
  alias Raxol.System.Updater.Provenance.Crypto

  @type signature :: %{keyid: String.t(), sig: binary()}
  @type t :: %__MODULE__{
          payload_type: String.t(),
          payload: binary(),
          signatures: [signature()]
        }

  @enforce_keys [:payload_type, :payload, :signatures]
  defstruct @enforce_keys

  @doc "Decodes a bundle's `dsseEnvelope`. Exactly one signature is accepted."
  @spec parse(term()) :: {:ok, t()} | {:error, term()}
  def parse(%{
        "payloadType" => type,
        "payload" => payload,
        "signatures" => [signature]
      })
      when is_binary(type) do
    with {:ok, payload} <- Crypto.decode64(payload),
         {:ok, signature} <- parse_signature(signature) do
      {:ok,
       %__MODULE__{
         payload_type: type,
         payload: payload,
         signatures: [signature]
       }}
    else
      :error -> {:error, {:malformed_bundle, :dsse_envelope}}
    end
  end

  def parse(_envelope), do: {:error, {:malformed_bundle, :dsse_envelope}}

  defp parse_signature(%{"sig" => sig} = signature) do
    keyid = Map.get(signature, "keyid", "")

    case Crypto.decode64(sig) do
      {:ok, sig} when is_binary(keyid) -> {:ok, %{keyid: keyid, sig: sig}}
      _other -> :error
    end
  end

  defp parse_signature(_signature), do: :error

  @doc "`\"DSSEv1\" SP LEN(type) SP type SP LEN(body) SP body`, lengths in decimal bytes."
  @spec pae(String.t(), binary()) :: binary()
  def pae(type, body),
    do: "DSSEv1 #{byte_size(type)} #{type} #{byte_size(body)} " <> body

  @doc "Verifies the envelope's signature over its PAE with `key`."
  @spec verify(t(), term(), atom()) :: :ok | {:error, :dsse_signature_invalid}
  def verify(%__MODULE__{signatures: [%{sig: sig}]} = envelope, key, digest) do
    if Crypto.verify(
         pae(envelope.payload_type, envelope.payload),
         digest,
         sig,
         key
       ),
       do: :ok,
       else: {:error, :dsse_signature_invalid}
  end

  @doc """
  The envelope as Rekor canonicalizes it before hashing it into a `dsse`
  entry's `envelopeHash`: keys sorted, bytes as standard base64, an empty
  `keyid` omitted.
  """
  @spec canonical_json(t()) :: binary()
  def canonical_json(%__MODULE__{} = envelope) do
    signatures =
      Enum.map(envelope.signatures, fn
        %{keyid: "", sig: sig} ->
          OrderedObject.new([{"sig", Base.encode64(sig)}])

        %{keyid: keyid, sig: sig} ->
          OrderedObject.new([{"keyid", keyid}, {"sig", Base.encode64(sig)}])
      end)

    Jason.encode!(
      OrderedObject.new([
        {"payload", Base.encode64(envelope.payload)},
        {"payloadType", envelope.payload_type},
        {"signatures", signatures}
      ])
    )
  end
end
