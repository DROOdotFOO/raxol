defmodule Raxol.ACP.Onchain.Rlp do
  @moduledoc """
  Recursive Length Prefix encoder for Ethereum.

  RLP is the canonical serialization for transactions, receipts, account
  state and tries on Ethereum. This module ships an encoder only -- we
  serialize transactions we send, but we never decode our own.

  ## Rules (from the Yellow Paper)

  Three input shapes:

  - **Integer**: encoded as the minimal big-endian byte string. Zero
    encodes as the empty string. Leading zero bytes are stripped.
  - **Binary** (byte string): a single byte `0x00..0x7f` encodes as
    itself; otherwise prefix with `0x80 + len` (len 0..55) or
    `0xb7 + length_of_length` followed by the big-endian length and the
    payload (len > 55).
  - **List**: each element is encoded recursively, the encodings are
    concatenated, and the concatenation is prefixed with `0xc0 + len`
    (total payload 0..55 bytes) or `0xf7 + length_of_length` followed
    by the big-endian length (> 55 bytes).

  ## Examples

      iex> Raxol.ACP.Onchain.Rlp.encode(0)
      <<0x80>>

      iex> Raxol.ACP.Onchain.Rlp.encode("dog")
      <<0x83, "d", "o", "g">>

      iex> Raxol.ACP.Onchain.Rlp.encode(["cat", "dog"])
      <<0xc8, 0x83, "c", "a", "t", 0x83, "d", "o", "g">>

      iex> Raxol.ACP.Onchain.Rlp.encode([])
      <<0xc0>>
  """

  @doc """
  Encode an integer, binary, or list (potentially nested).

  Integers must be non-negative.
  """
  @spec encode(non_neg_integer() | binary() | list()) :: binary()
  def encode(value) when is_integer(value) and value >= 0 do
    value |> to_minimal_be() |> encode_binary()
  end

  def encode(value) when is_binary(value) do
    encode_binary(value)
  end

  def encode(value) when is_list(value) do
    payload =
      value
      |> Enum.map(&encode/1)
      |> IO.iodata_to_binary()

    encode_list_prefix(byte_size(payload)) <> payload
  end

  # -- Binary --

  defp encode_binary(<<byte>>) when byte < 0x80, do: <<byte>>

  defp encode_binary(bin) when byte_size(bin) <= 55 do
    <<0x80 + byte_size(bin)>> <> bin
  end

  defp encode_binary(bin) do
    len = byte_size(bin)
    len_bytes = to_minimal_be(len)
    <<0xB7 + byte_size(len_bytes)>> <> len_bytes <> bin
  end

  # -- List prefix --

  defp encode_list_prefix(len) when len <= 55, do: <<0xC0 + len>>

  defp encode_list_prefix(len) do
    len_bytes = to_minimal_be(len)
    <<0xF7 + byte_size(len_bytes)>> <> len_bytes
  end

  # -- Integer to minimal big-endian --

  @doc false
  @spec to_minimal_be(non_neg_integer()) :: binary()
  def to_minimal_be(0), do: <<>>

  def to_minimal_be(n) when is_integer(n) and n > 0 do
    n |> :binary.encode_unsigned() |> strip_leading_zeros()
  end

  defp strip_leading_zeros(<<0, rest::binary>>) when rest != <<>>,
    do: strip_leading_zeros(rest)

  defp strip_leading_zeros(bin), do: bin
end
