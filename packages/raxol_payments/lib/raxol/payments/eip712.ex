defmodule Raxol.Payments.EIP712 do
  @moduledoc """
  EIP-712 typed-structured-data hashing.

  Produces the 32-byte digest defined by EIP-712:

      keccak256(0x19 || 0x01 || domainSeparator || hashStruct(message))

  The digest can then be passed to `ExSecp256k1.sign/2` (or any other
  secp256k1 signer) to produce the EIP-712 signature.

  Used by wallet implementations (`Raxol.Payments.Wallets.Env`,
  `Raxol.Payments.Wallets.Op`) and by ACP memo signing in `raxol_acp`.

  ## Example

      domain = %{
        name: "USD Coin",
        version: "2",
        chainId: 8453,
        verifyingContract: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
      }

      types = %{
        "TransferWithAuthorization" => [
          {"from", "address"},
          {"to", "address"},
          {"value", "uint256"},
          {"validAfter", "uint256"},
          {"validBefore", "uint256"},
          {"nonce", "bytes32"}
        ]
      }

      message = %{
        from: "0xabc...",
        to: "0xdef...",
        value: 1_000_000,
        validAfter: 0,
        validBefore: 9_999_999_999,
        nonce: "0x" <> String.duplicate("00", 32)
      }

      {:ok, digest} = Raxol.Payments.EIP712.hash(domain, types, message)
  """

  @doc """
  Hash an EIP-712 typed message into a 32-byte digest.

  - `domain` — EIP-712 domain separator fields. Recognized keys: `:name`,
    `:version`, `:chainId` (or `:chain_id`), `:verifyingContract` (or
    `:verifying_contract`). Only the keys present in the map are included
    in the domain type, matching reference implementations.
  - `types` — map of struct type names to field definitions. The first
    key in the map is treated as the primary type.
  - `message` — map of field values for the primary type.

  Returns `{:ok, digest}` on success or `{:error, reason}` if a value
  cannot be encoded under its declared type.
  """
  @spec hash(map(), map(), map()) :: {:ok, binary()} | {:error, term()}
  def hash(domain, types, message) do
    with {:ok, domain_separator} <-
           hash_struct("EIP712Domain", domain, eip712_domain_types(domain)),
         {:ok, message_hash} <- hash_struct(primary_type(types), message, types) do
      {:ok, ExKeccak.hash_256(<<0x19, 0x01, domain_separator::binary, message_hash::binary>>)}
    end
  end

  # -- Private --

  defp eip712_domain_types(domain) do
    fields =
      [
        if(Map.has_key?(domain, :name), do: {"name", "string"}),
        if(Map.has_key?(domain, :version), do: {"version", "string"}),
        if(Map.has_key?(domain, :chainId) || Map.has_key?(domain, :chain_id),
          do: {"chainId", "uint256"}
        ),
        if(Map.has_key?(domain, :verifyingContract) || Map.has_key?(domain, :verifying_contract),
          do: {"verifyingContract", "address"}
        )
      ]
      |> Enum.reject(&is_nil/1)

    %{"EIP712Domain" => fields}
  end

  defp primary_type(types) do
    types
    |> Map.keys()
    |> List.first()
  end

  # EIP-712: hashStruct(s) = keccak256(typeHash || encodeData(s))
  # where typeHash = keccak256(encodeType(s)) and encodeType returns the string.
  defp hash_struct(type_name, data, types) do
    type_hash = encode_type(type_name, types)

    case encode_data(type_name, data, types) do
      {:error, _} = err -> err
      encoded_data -> {:ok, ExKeccak.hash_256(<<type_hash::binary, encoded_data::binary>>)}
    end
  end

  defp encode_type(type_name, types) do
    fields = Map.get(types, type_name, [])

    type_string =
      type_name <>
        "(" <>
        (fields
         |> Enum.map(fn {name, type} -> "#{type} #{name}" end)
         |> Enum.join(",")) <>
        ")"

    ExKeccak.hash_256(type_string)
  end

  defp encode_data(type_name, data, types) do
    fields = Map.get(types, type_name, [])

    fields
    |> Enum.reduce_while(<<>>, fn {name, type}, acc ->
      value = Map.get(data, name) || safe_atom_get(data, name)

      case encode_value(type, value) do
        {:ok, encoded} -> {:cont, <<acc::binary, encoded::binary>>}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  # Look up a string key as an existing atom. Returns nil if the atom
  # doesn't exist, avoiding atom table exhaustion from external input.
  defp safe_atom_get(data, name) do
    Map.get(data, String.to_existing_atom(name))
  rescue
    ArgumentError -> nil
  end

  defp encode_value("address", value) when is_binary(value) do
    hex = String.trim_leading(value, "0x")

    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} when byte_size(bytes) == 20 ->
        {:ok, pad_left(bytes, 32)}

      {:ok, bytes} ->
        {:error, {:invalid_address_length, byte_size(bytes)}}

      :error ->
        {:error, {:invalid_hex, "address"}}
    end
  end

  defp encode_value("uint256", value) when is_integer(value) do
    {:ok, <<value::unsigned-big-256>>}
  end

  defp encode_value("uint256", value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> {:ok, <<int::unsigned-big-256>>}
      _ -> {:error, {:invalid_uint256, value}}
    end
  end

  defp encode_value("bytes32", value) when is_binary(value) do
    hex = String.trim_leading(value, "0x")

    case Base.decode16(hex, case: :mixed) do
      {:ok, bytes} -> {:ok, pad_right(bytes, 32)}
      :error -> {:error, {:invalid_hex, "bytes32"}}
    end
  end

  defp encode_value("string", value) when is_binary(value) do
    {:ok, ExKeccak.hash_256(value)}
  end

  defp encode_value("bool", true), do: {:ok, <<1::unsigned-big-256>>}
  defp encode_value("bool", false), do: {:ok, <<0::unsigned-big-256>>}

  # EIP-712 dynamic array: encodeData(T[]) = keccak256(concat(encodeData(T)_i)).
  # For a `string[]` field, each element gets `keccak256(s_i)` first (the
  # `encode_value("string", _)` clause above), then those 32-byte hashes
  # are concatenated and hashed again. The same recursion handles
  # `address[]`, `uint256[]`, `bytes32[]`, and `bool[]` correctly.
  defp encode_value(type, value) when is_binary(type) and is_list(value) do
    case array_element_type(type) do
      {:ok, element_type} -> encode_array(element_type, value)
      :error -> {:error, {:list_for_scalar_type, type}}
    end
  end

  defp encode_value(_type, nil), do: {:ok, <<0::unsigned-big-256>>}

  defp encode_value(_type, value) when is_binary(value) do
    {:ok, pad_left(value, 32)}
  end

  defp array_element_type(type) do
    case String.split(type, "[]", parts: 2) do
      [element_type, ""] when element_type != "" -> {:ok, element_type}
      _ -> :error
    end
  end

  defp encode_array(element_type, values) do
    Enum.reduce_while(values, {:ok, <<>>}, fn v, {:ok, acc} ->
      case encode_value(element_type, v) do
        {:ok, encoded} -> {:cont, {:ok, <<acc::binary, encoded::binary>>}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, concatenated} -> {:ok, ExKeccak.hash_256(concatenated)}
      err -> err
    end
  end

  defp pad_left(bytes, size) do
    padding = size - byte_size(bytes)

    if padding > 0 do
      <<0::size(padding * 8), bytes::binary>>
    else
      binary_part(bytes, byte_size(bytes) - size, size)
    end
  end

  defp pad_right(bytes, size) do
    padding = size - byte_size(bytes)

    if padding > 0 do
      <<bytes::binary, 0::size(padding * 8)>>
    else
      binary_part(bytes, 0, size)
    end
  end
end
