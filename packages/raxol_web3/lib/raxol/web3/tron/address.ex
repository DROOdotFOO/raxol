defmodule Raxol.Web3.Tron.Address do
  @moduledoc """
  Tron Base58Check address codec, and the canonical form of a Tron account
  reference.

  A Tron mainnet address is a `0x41`-prefixed 21-byte payload encoded as
  Base58Check: `Base58(payload <> first4(sha256(sha256(payload))))`, which
  always renders with a leading `T`. This module validates such addresses and
  converts between that form and the `0x41`-prefixed hex form the chain uses
  internally.

  It is not the EVM `0x`-20-byte form. A Tron address carries an extra network
  prefix byte and a checksum, which is why `Raxol.Web3.Backend`'s account
  reference is a tagged tuple rather than a string: `{:tron, value}` and
  `{:evm, value}` are different address spaces that both render as hex.

  ## Two encodings, one reference

  Callers hold either encoding and upstreams disagree about which they accept,
  so `canonical/1` collapses both onto Base58 before a reference reaches a URL
  or a tool argument. Without that, one account asked about twice under two
  encodings is two cache entries, two rate-limit spends, and two
  different-looking answers to one question.

  ## One verification path

  Everything here goes through `decode/1`, which refuses the shape, the length,
  the network prefix and the checksum in that order and hands back the payload.
  `valid?/1`, `to_hex/1` and `canonical/1` are all thin over it. That is
  deliberate rather than incidental: `Raxol.Payments.Tron.Address` is the same
  codec with the checks repeated per entry point, ADR-0033 decision 2's move
  table collapses the two, and a single verification path is what makes the
  collapse a delete plus a delegation rather than a merge of three near-copies.
  Behaviour is identical and the ground-truth vectors in both test files are the
  same, which is what makes that claim checkable.
  """

  @alphabet ~c"123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
  # A tuple for the encode direction, so a digit is one `elem/2` rather than a
  # list walk, and a map for the decode direction, which also rejects a
  # character outside the alphabet without a guard per call site.
  @digits List.to_tuple(@alphabet)
  @values @alphabet |> Enum.with_index() |> Map.new()

  @mainnet_prefix 0x41
  @address_bytes 20
  @payload_bytes 21
  @checksum_bytes 4

  @type t :: String.t()

  @typedoc "Why an address was refused. One reason, because a caller can act on one."
  @type reason :: :invalid_address

  @doc """
  The 21-byte payload behind a Base58Check address.

  Refuses, in order: a value that is not a string, a string that is not Base58,
  a decoded length that is not payload plus checksum, a payload whose first byte
  is not the mainnet prefix, and a checksum that does not verify.
  """
  @spec decode(term()) :: {:ok, binary()} | {:error, reason()}
  def decode(address) when is_binary(address) do
    with {:ok, decoded} <- base58_decode(address),
         <<payload::binary-size(@payload_bytes), checksum::binary-size(@checksum_bytes)>> <-
           decoded,
         <<@mainnet_prefix, _rest::binary-size(@address_bytes)>> <- payload,
         true <- :crypto.hash_equals(checksum_of(payload), checksum) do
      {:ok, payload}
    else
      _refused -> {:error, :invalid_address}
    end
  end

  def decode(_other), do: {:error, :invalid_address}

  @doc "True when `address` is a well-formed Tron mainnet Base58Check address."
  @spec valid?(term()) :: boolean()
  def valid?(address), do: match?({:ok, _payload}, decode(address))

  @doc """
  The canonical Base58Check form of either encoding.

  Accepts a Base58Check address and a `0x41`-prefixed hex address with or
  without the `0x`. A 20-byte EVM address is refused rather than given a network
  prefix: inventing the `0x41` would mint a Tron address for an account that was
  never on this chain, which is the confusion the tagged reference exists to
  prevent.
  """
  @spec canonical(term()) :: {:ok, t()} | {:error, reason()}
  def canonical(address) when is_binary(address) do
    case decode(address) do
      {:ok, _payload} -> {:ok, address}
      {:error, :invalid_address} -> from_hex(address)
    end
  end

  def canonical(_other), do: {:error, :invalid_address}

  @doc "The `0x41`-prefixed hex form, 42 hex characters including the `0x`."
  @spec to_hex(term()) :: {:ok, String.t()} | {:error, reason()}
  def to_hex(address) do
    with {:ok, payload} <- decode(address) do
      {:ok, "0x" <> :binary.encode_hex(payload, :lowercase)}
    end
  end

  @doc "The Base58Check form of a `0x41`-prefixed hex address, with or without the `0x`."
  @spec from_hex(term()) :: {:ok, t()} | {:error, reason()}
  def from_hex("0x" <> hex), do: from_hex(hex)

  def from_hex(hex) when is_binary(hex) and byte_size(hex) == @payload_bytes * 2 do
    case safe_decode_hex(hex) do
      <<@mainnet_prefix, _rest::binary-size(@address_bytes)>> = payload ->
        {:ok, base58_encode(payload <> checksum_of(payload))}

      _refused ->
        {:error, :invalid_address}
    end
  end

  def from_hex(_other), do: {:error, :invalid_address}

  defp safe_decode_hex(hex) do
    :binary.decode_hex(hex)
  rescue
    ArgumentError -> :error
  end

  defp checksum_of(payload) do
    <<checksum::binary-size(@checksum_bytes), _rest::binary>> =
      :crypto.hash(:sha256, :crypto.hash(:sha256, payload))

    checksum
  end

  defp base58_encode(binary) do
    zeros = leading_zero_bytes(binary, 0)
    digits = binary |> :binary.decode_unsigned() |> to_digits([])

    String.duplicate("1", zeros) <> List.to_string(digits)
  end

  defp to_digits(0, digits), do: digits
  defp to_digits(number, digits), do: to_digits(div(number, 58), [digit(number) | digits])

  defp digit(number), do: elem(@digits, rem(number, 58))

  defp base58_decode(string) do
    chars = String.to_charlist(string)

    case to_integer(chars, 0) do
      {:ok, 0} ->
        {:ok, :binary.copy(<<0>>, leading_ones(chars, 0))}

      {:ok, number} ->
        {:ok, :binary.copy(<<0>>, leading_ones(chars, 0)) <> encode_unsigned(number)}

      :error ->
        {:error, :invalid_address}
    end
  end

  defp encode_unsigned(number), do: :binary.encode_unsigned(number)

  defp to_integer([], number), do: {:ok, number}

  defp to_integer([char | rest], number) do
    case Map.fetch(@values, char) do
      {:ok, value} -> to_integer(rest, number * 58 + value)
      :error -> :error
    end
  end

  defp leading_zero_bytes(<<0, rest::binary>>, count), do: leading_zero_bytes(rest, count + 1)
  defp leading_zero_bytes(_binary, count), do: count

  defp leading_ones([?1 | rest], count), do: leading_ones(rest, count + 1)
  defp leading_ones(_chars, count), do: count
end
