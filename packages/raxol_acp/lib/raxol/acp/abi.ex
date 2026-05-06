defmodule Raxol.ACP.ABI do
  @moduledoc """
  Minimal Solidity ABI encoder for ACP contract calls.

  Supports the type set used by the four ACP contract methods:

  - Static: `uint256`, `address`, `bytes32`, `bool`
  - Dynamic: `bytes`, `string`

  Implements the head/tail offset layout from the Solidity ABI spec for
  dynamic types. Distinct from `Raxol.Payments.EIP712`: ABI encoding for
  contract calls inlines the length-prefixed payload of dynamic types,
  whereas EIP-712 hashes them.

  ## Example

      Raxol.ACP.ABI.encode_call(
        "transfer(address,uint256)",
        [
          {"address", "0x" <> String.duplicate("ab", 20)},
          {"uint256", 1000}
        ]
      )

  Returns the ABI-encoded calldata as a binary, ready for an `eth_call` /
  `eth_sendRawTransaction` payload.
  """

  @selector_size 4
  @word_size 32

  @doc """
  Compute the 4-byte function selector for a canonical signature.

  The signature must be normalized: no spaces, parameter types as
  Solidity primitives. Tuple/array types are not supported in v0.1.

      iex> Raxol.ACP.ABI.function_selector("transfer(address,uint256)")
      <<0xa9, 0x05, 0x9c, 0xbb>>
  """
  @spec function_selector(String.t()) :: binary()
  def function_selector(signature) when is_binary(signature) do
    signature
    |> ExKeccak.hash_256()
    |> binary_part(0, @selector_size)
  end

  @doc """
  Encode a contract call: function selector followed by ABI-encoded args.

  `args` is a list of `{type, value}` tuples. Order matters and must
  match the order in `signature`.
  """
  @spec encode_call(String.t(), [{String.t(), term()}]) :: binary()
  def encode_call(signature, args) when is_binary(signature) and is_list(args) do
    function_selector(signature) <> encode_args(args)
  end

  # -- Internal --

  # Solidity ABI head/tail encoding:
  #   head_size = sum of static slot sizes (32 each, including 32-byte
  #     offset placeholders for dynamic types)
  #   for each arg: emit a static word into head OR an offset word that
  #     points into the tail; dynamic payloads are appended to tail.
  defp encode_args(args) do
    head_size = length(args) * @word_size

    {heads, tails, _final_offset} =
      Enum.reduce(args, {[], [], head_size}, fn {type, value}, {heads, tails, offset} ->
        if dynamic?(type) do
          encoded_value = encode_dynamic(type, value)

          {
            heads ++ [encode_uint256(offset)],
            tails ++ [encoded_value],
            offset + byte_size(encoded_value)
          }
        else
          {heads ++ [encode_static(type, value)], tails, offset}
        end
      end)

    IO.iodata_to_binary([heads, tails])
  end

  defp dynamic?("bytes"), do: true
  defp dynamic?("string"), do: true
  defp dynamic?(_), do: false

  # -- Static encoders (always 32 bytes) --

  defp encode_static("uint256", value), do: encode_uint256(value)
  defp encode_static("address", value), do: encode_address(value)
  defp encode_static("bytes32", value), do: encode_bytes32(value)
  defp encode_static("bool", true), do: <<1::unsigned-big-256>>
  defp encode_static("bool", false), do: <<0::unsigned-big-256>>

  defp encode_static(type, _value) do
    raise ArgumentError, "Raxol.ACP.ABI: unsupported static type #{inspect(type)}"
  end

  defp encode_uint256(value) when is_integer(value) and value >= 0 do
    <<value::unsigned-big-256>>
  end

  defp encode_address("0x" <> hex), do: encode_address(hex)

  defp encode_address(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 20 ->
        <<0::size(96), bytes::binary-size(20)>>

      {:ok, bytes} ->
        raise ArgumentError, "Raxol.ACP.ABI: address must be 20 bytes, got #{byte_size(bytes)}"

      :error ->
        raise ArgumentError, "Raxol.ACP.ABI: invalid hex in address"
    end
  end

  defp encode_bytes32("0x" <> hex), do: encode_bytes32(hex)

  defp encode_bytes32(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) <= @word_size ->
        pad_right(bytes, @word_size)

      {:ok, bytes} ->
        raise ArgumentError,
              "Raxol.ACP.ABI: bytes32 must be at most 32 bytes, got #{byte_size(bytes)}"

      :error ->
        raise ArgumentError, "Raxol.ACP.ABI: invalid hex in bytes32"
    end
  end

  # -- Dynamic encoders (length-prefixed, padded to word boundary) --

  defp encode_dynamic("bytes", value) when is_binary(value) do
    encode_dynamic_payload(value)
  end

  defp encode_dynamic("string", value) when is_binary(value) do
    encode_dynamic_payload(value)
  end

  defp encode_dynamic_payload(payload) do
    length_word = encode_uint256(byte_size(payload))
    padded = pad_right(payload, ceil_word(byte_size(payload)))
    <<length_word::binary, padded::binary>>
  end

  # -- Helpers --

  defp ceil_word(0), do: 0

  defp ceil_word(n) do
    rem = rem(n, @word_size)
    if rem == 0, do: n, else: n + (@word_size - rem)
  end

  defp pad_right(bytes, size) do
    padding = size - byte_size(bytes)

    cond do
      padding > 0 -> <<bytes::binary, 0::size(padding * 8)>>
      padding == 0 -> bytes
      true -> binary_part(bytes, 0, size)
    end
  end
end
