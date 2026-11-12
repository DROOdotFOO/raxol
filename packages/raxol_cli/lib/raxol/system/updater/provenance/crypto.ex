defmodule Raxol.System.Updater.Provenance.Crypto do
  @moduledoc """
  Non-raising primitives the Sigstore verifier is built from: signature
  checks, public-key and DER decoding, base64, and the integers that
  protobuf JSON writes as strings.

  Every function here answers malformed input with `false` or `:error`,
  never an exception, so a hostile bundle can only ever produce a refusal.
  """

  @doc """
  Whether `signature` is a valid signature over `message`. A malformed
  signature or key is not valid.
  """
  @spec verify(binary(), atom(), binary(), term()) :: boolean()
  def verify(message, digest, signature, key)
      when is_binary(message) and is_binary(signature) do
    :public_key.verify(message, digest, signature, key)
  rescue
    _malformed in [ErlangError, ArgumentError, FunctionClauseError] -> false
  end

  def verify(_message, _digest, _signature, _key), do: false

  @doc "Decodes a DER `SubjectPublicKeyInfo` into a `:public_key` key."
  @spec decode_spki(binary()) :: {:ok, term()} | :error
  def decode_spki(der) when is_binary(der) do
    {:ok,
     :public_key.pem_entry_decode({:SubjectPublicKeyInfo, der, :not_encrypted})}
  rescue
    _malformed in [MatchError, ErlangError, ArgumentError, FunctionClauseError] ->
      :error
  end

  @spec sha256(iodata()) :: binary()
  def sha256(data), do: :crypto.hash(:sha256, data)

  @spec hex(binary()) :: String.t()
  def hex(bytes), do: Base.encode16(bytes, case: :lower)

  @doc "Standard (padded) base64, as protobuf JSON writes `bytes` fields."
  @spec decode64(term()) :: {:ok, binary()} | :error
  def decode64(value) when is_binary(value), do: Base.decode64(value)
  def decode64(_value), do: :error

  @doc "A protobuf JSON `int64`: a decimal string, or a plain integer."
  @spec parse_uint(term()) :: {:ok, non_neg_integer()} | :error
  def parse_uint(value) when is_integer(value) and value >= 0, do: {:ok, value}

  def parse_uint(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} when int >= 0 -> {:ok, int}
      _other -> :error
    end
  end

  def parse_uint(_value), do: :error

  @doc """
  The content of one DER element with the given tag byte, which must fill
  `der` exactly.
  """
  @spec der_content(non_neg_integer(), binary()) :: {:ok, binary()} | :error
  def der_content(tag, <<tag, rest::binary>>) do
    case der_length(rest) do
      {:ok, length, content} when byte_size(content) == length -> {:ok, content}
      _other -> :error
    end
  end

  def der_content(_tag, _der), do: :error

  defp der_length(<<length, content::binary>>) when length < 0x80,
    do: {:ok, length, content}

  defp der_length(<<0x81, length, content::binary>>) when length >= 0x80,
    do: {:ok, length, content}

  defp der_length(<<0x82, length::16, content::binary>>) when length >= 0x100,
    do: {:ok, length, content}

  defp der_length(_der), do: :error

  @doc """
  An X.509 `Time` (`UTCTime` or `GeneralizedTime`, in UTC) as unix seconds.
  A two-digit `UTCTime` year below 50 is 20YY (RFC 5280 4.1.2.5.1).
  """
  @spec x509_time_to_unix({:utcTime | :generalTime, charlist() | String.t()}) ::
          {:ok, integer()} | :error
  def x509_time_to_unix({:utcTime, time}) do
    case to_string(time) do
      <<yy::binary-2, _rest::binary>> = utc when yy >= "50" ->
        general_time("19" <> utc)

      utc ->
        general_time("20" <> utc)
    end
  end

  def x509_time_to_unix({:generalTime, time}),
    do: time |> to_string() |> general_time()

  def x509_time_to_unix(_time), do: :error

  defp general_time(
         <<year::binary-4, month::binary-2, day::binary-2, hour::binary-2,
           minute::binary-2, second::binary-2, "Z">>
       ) do
    case DateTime.from_iso8601(
           "#{year}-#{month}-#{day}T#{hour}:#{minute}:#{second}Z"
         ) do
      {:ok, datetime, 0} -> {:ok, DateTime.to_unix(datetime)}
      _invalid -> :error
    end
  end

  defp general_time(_time), do: :error
end
