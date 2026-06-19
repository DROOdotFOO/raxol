defmodule Raxol.Payments.Tron.Address do
  @moduledoc """
  Tron Base58Check address codec.

  Tron mainnet addresses are a `0x41`-prefixed 21-byte payload encoded as
  Base58Check: `Base58(payload <> first4(sha256(sha256(payload))))`, which always
  renders with a leading `T`. This module validates such addresses and converts
  between the Base58 form and the `0x41`-prefixed hex form the chain uses
  internally, so the Relay client can reject malformed Tron addresses before any
  network call.

  This is not the EVM `0x`-20-byte form; a Tron address carries the extra `0x41`
  network prefix and a checksum.
  """

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  @char_to_value @alphabet |> Enum.with_index() |> Map.new()

  @mainnet_prefix 0x41
  # 1 prefix byte + 20 address bytes.
  @payload_bytes 21
  @checksum_bytes 4

  @type t :: String.t()

  @doc "True when `address` is a well-formed Tron mainnet Base58Check address."
  @spec valid?(term()) :: boolean()
  def valid?(address) when is_binary(address) do
    with true <- String.starts_with?(address, "T"),
         {:ok, decoded} <- base58_decode(address),
         true <- byte_size(decoded) == @payload_bytes + @checksum_bytes,
         <<payload::binary-size(@payload_bytes), checksum::binary-size(@checksum_bytes)>> <-
           decoded,
         <<@mainnet_prefix, _rest::binary-size(20)>> <- payload,
         true <- checksum_valid?(payload, checksum) do
      true
    else
      _ -> false
    end
  end

  def valid?(_), do: false

  @doc """
  Convert a Base58Check Tron address to its `0x41`-prefixed hex form (42 hex
  chars). Returns `{:error, :invalid_address}` for malformed input.
  """
  @spec to_hex(t()) :: {:ok, String.t()} | {:error, :invalid_address}
  def to_hex(address) when is_binary(address) do
    with {:ok, decoded} <- base58_decode(address),
         <<payload::binary-size(@payload_bytes), checksum::binary-size(@checksum_bytes)>> <-
           decoded,
         <<@mainnet_prefix, _rest::binary-size(20)>> <- payload,
         true <- checksum_valid?(payload, checksum) do
      {:ok, "0x" <> Base.encode16(payload, case: :lower)}
    else
      _ -> {:error, :invalid_address}
    end
  end

  def to_hex(_), do: {:error, :invalid_address}

  @doc """
  Convert a `0x41`-prefixed hex address (with or without the `0x`) to its
  Base58Check Tron form.
  """
  @spec from_hex(String.t()) :: {:ok, t()} | {:error, :invalid_address}
  def from_hex("0x" <> hex), do: from_hex(hex)

  def from_hex(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<@mainnet_prefix, _rest::binary-size(20)>> = payload} ->
        {:ok, base58_encode(payload <> compute_checksum(payload))}

      _ ->
        {:error, :invalid_address}
    end
  end

  def from_hex(_), do: {:error, :invalid_address}

  # -- Base58Check internals --

  defp checksum_valid?(payload, checksum) do
    :crypto.hash_equals(compute_checksum(payload), checksum)
  end

  defp compute_checksum(payload) do
    payload
    |> sha256()
    |> sha256()
    |> binary_part(0, @checksum_bytes)
  end

  defp sha256(data), do: :crypto.hash(:sha256, data)

  # -- Base58 --

  defp base58_encode(binary) when is_binary(binary) do
    leading = leading_zeros(binary)
    body = binary |> :binary.decode_unsigned() |> encode_int([])
    String.duplicate("1", leading) <> List.to_string(body)
  end

  defp encode_int(0, acc), do: acc
  defp encode_int(n, acc), do: encode_int(div(n, 58), [Enum.at(@alphabet, rem(n, 58)) | acc])

  defp base58_decode(string) do
    chars = String.to_charlist(string)

    case decode_int(chars, 0) do
      {:ok, int} ->
        leading = count_leading(chars, ?1)
        bytes = if int == 0, do: <<>>, else: :binary.encode_unsigned(int)
        {:ok, :binary.copy(<<0>>, leading) <> bytes}

      :error ->
        {:error, :decode_failed}
    end
  end

  defp decode_int([], acc), do: {:ok, acc}

  defp decode_int([char | rest], acc) do
    case Map.get(@char_to_value, char) do
      nil -> :error
      value -> decode_int(rest, acc * 58 + value)
    end
  end

  defp leading_zeros(binary), do: count_leading_bytes(binary, 0)

  defp count_leading_bytes(<<0, rest::binary>>, count), do: count_leading_bytes(rest, count + 1)
  defp count_leading_bytes(_binary, count), do: count

  defp count_leading([char | rest], char), do: 1 + count_leading(rest, char)
  defp count_leading(_chars, _char), do: 0
end
