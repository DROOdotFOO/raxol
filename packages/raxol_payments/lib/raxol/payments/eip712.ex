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
    `:verifying_contract`), and `:salt` (bytes32). Only the keys present in
    the map are included in the domain type, matching reference implementations.
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
      {:ok,
       ExKeccak.hash_256(
         <<0x19, 0x01, domain_separator::binary, message_hash::binary>>
       )}
    end
  end

  @doc """
  Pack an `ExSecp256k1.sign/2` result into Ethereum's canonical 65-byte
  signature `r || s || v`.

  `ExSecp256k1.sign/2` returns the recovery id as `0` or `1`. Ethereum's
  `ecrecover` -- and the ERC-3009 / Permit2 on-chain authorizations the Xochi
  origin pull and x402 settlement are verified against -- require the canonical
  `27` / `28`, returning `address(0)` for `v < 27`. Normalizing here keeps every
  wallet's output verifiable both on-chain and off-chain (viem accepts either
  form). Idempotent: a signature already carrying `27` / `28` is unchanged.
  """
  @spec pack_signature({binary(), binary(), 0..28}) :: binary()
  def pack_signature({<<r::binary-size(32)>>, <<s::binary-size(32)>>, v})
      when is_integer(v) do
    <<r::binary-size(32), s::binary-size(32), canonical_v(v)::8>>
  end

  @doc """
  Derive the `0x`-prefixed, lowercase Ethereum address from a 65-byte
  uncompressed secp256k1 public key (`0x04 || X || Y`): the last 20 bytes of
  `keccak256(X || Y)`.
  """
  @spec address_from_pubkey(<<_::520>>) :: String.t()
  def address_from_pubkey(<<_prefix::8, xy::binary-size(64)>>) do
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  @doc """
  Canonicalize an EVM address for comparison: trim, downcase, and strip a
  leading `0x`. Returns the lowercase hex body (no `0x`).
  """
  @spec normalize_address(binary()) :: binary()
  def normalize_address(addr) when is_binary(addr) do
    addr
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("0x", "")
  end

  # -- Private --

  defp canonical_v(v) when v in [0, 1], do: v + 27
  defp canonical_v(v) when v in [27, 28], do: v

  # A secp256k1 recovery id is 0/1 (or the 27/28 Ethereum form). Anything else
  # (an EIP-155 chain-encoded v, or a buggy signer) would silently pack a
  # non-recovering signature, so fail loud rather than emit one.
  defp canonical_v(v),
    do:
      raise(ArgumentError, "non-canonical secp256k1 recovery id: #{inspect(v)}")

  # EIP-712 defines exactly five domain fields, in this order: name, version,
  # chainId, verifyingContract, salt. Only the keys present in the domain map are
  # emitted, matching reference implementations. `salt` (bytes32) is required by
  # contracts that domain-separate without a verifyingContract -- the Xochi
  # XochiIntent domain is keyed by name/version/chainId/salt, so omitting it
  # hashes a 3-field separator against the worker's 4-field one and the signature
  # cannot recover.
  defp eip712_domain_types(domain) do
    fields =
      [
        if(Map.has_key?(domain, :name), do: {"name", "string"}),
        if(Map.has_key?(domain, :version), do: {"version", "string"}),
        if(Map.has_key?(domain, :chainId) || Map.has_key?(domain, :chain_id),
          do: {"chainId", "uint256"}
        ),
        if(
          Map.has_key?(domain, :verifyingContract) ||
            Map.has_key?(domain, :verifying_contract),
          do: {"verifyingContract", "address"}
        ),
        if(Map.has_key?(domain, :salt), do: {"salt", "bytes32"})
      ]
      |> Enum.reject(&is_nil/1)

    %{"EIP712Domain" => fields}
  end

  # EIP-712 primary type detection: the primary is the unique type that
  # is NOT referenced as a field type by any other type in the map.
  # For a single-struct types map, that's just the only key. For nested
  # structs (e.g. Permit2 PermitWitnessTransferFrom referencing
  # TokenPermissions and OriginPullWitness), this picks the outer type
  # deterministically regardless of Elixir map iteration order.
  defp primary_type(types) do
    all_names = MapSet.new(Map.keys(types))

    referenced =
      types
      |> Map.values()
      |> Enum.flat_map(fn fields ->
        Enum.map(fields, fn {_name, type} -> base_type(type) end)
      end)
      |> MapSet.new()

    candidates = MapSet.difference(all_names, referenced)

    case MapSet.to_list(candidates) do
      [primary] ->
        primary

      [] ->
        # Cycles or zero candidates: fall back to insertion-ish order so
        # single-type maps keep working.
        types |> Map.keys() |> List.first()

      multiple ->
        raise ArgumentError,
              "EIP-712 types map is ambiguous: multiple root types #{inspect(multiple)}. " <>
                "Every type should be referenced by exactly one other, except the primary."
    end
  end

  # EIP-712: hashStruct(s) = keccak256(typeHash || encodeData(s))
  # where typeHash = keccak256(encodeType(s)) and encodeType returns the string.
  defp hash_struct(type_name, data, types) do
    type_hash = encode_type(type_name, types)

    case encode_data(type_name, data, types) do
      {:error, _} = err ->
        err

      encoded_data ->
        {:ok, ExKeccak.hash_256(<<type_hash::binary, encoded_data::binary>>)}
    end
  end

  # EIP-712: encodeType(s) = enc(s) ++ enc(t_1) ++ ... ++ enc(t_n)
  # where t_i are struct types referenced (transitively) by s, sorted
  # alphabetically by name and deduplicated. Without the referenced types
  # appended, nested structs like Permit2 PermitWitnessTransferFrom produce
  # a typeHash ethers v5 won't match.
  defp encode_type(type_name, types) do
    primary = type_string(type_name, types)

    referenced =
      type_name
      |> collect_referenced_types(types, MapSet.new())
      |> MapSet.delete(type_name)
      |> Enum.sort()
      |> Enum.map_join("", &type_string(&1, types))

    ExKeccak.hash_256(primary <> referenced)
  end

  defp type_string(type_name, types) do
    fields = Map.get(types, type_name, [])

    type_name <>
      "(" <>
      Enum.map_join(fields, ",", fn {name, type} -> "#{type} #{name}" end) <>
      ")"
  end

  defp collect_referenced_types(type_name, types, seen) do
    if MapSet.member?(seen, type_name) do
      seen
    else
      seen = MapSet.put(seen, type_name)
      fields = Map.get(types, type_name, [])

      Enum.reduce(fields, seen, fn {_name, type}, acc ->
        base = base_type(type)

        if Map.has_key?(types, base) do
          collect_referenced_types(base, types, acc)
        else
          acc
        end
      end)
    end
  end

  defp base_type(type) when is_binary(type) do
    case String.split(type, "[", parts: 2) do
      [base, _] -> base
      [base] -> base
    end
  end

  defp encode_data(type_name, data, types) do
    fields = Map.get(types, type_name, [])

    fields
    |> Enum.reduce_while(<<>>, fn {name, type}, acc ->
      value = Map.get(data, name) || safe_atom_get(data, name)

      case encode_value(type, value, types) do
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

  # Nested struct field: hashStruct(value) becomes the 32-byte encoded
  # value at this slot. Required for Permit2 PermitWitnessTransferFrom
  # (`TokenPermissions permitted`, `OriginPullWitness witness`) and any
  # other EIP-712 type that references another struct.
  defp encode_value(type, value, types)
       when is_binary(type) and is_map(value) do
    if Map.has_key?(types, type) do
      hash_struct(type, value, types)
    else
      # A map value whose type is not a declared struct is a malformed type
      # definition. `encode_value/2` has no map clause, so surface a clean error
      # rather than crashing with FunctionClauseError.
      {:error, {:unknown_struct_type, type}}
    end
  end

  # Array of structs: each element is hashed via hash_struct/3, the
  # resulting 32-byte hashes are concatenated, and the concatenation is
  # hashed once more (EIP-712 dynamic array rule).
  defp encode_value(type, value, types)
       when is_binary(type) and is_list(value) do
    case array_element_type(type) do
      {:ok, element_type} ->
        cond do
          Map.has_key?(types, element_type) ->
            encode_struct_array(element_type, value, types)

          true ->
            encode_value(type, value)
        end

      :error ->
        encode_value(type, value)
    end
  end

  # Delegate everything else to the existing arity-2 implementation. The
  # arity-3 entry point exists only to thread `types` through for the
  # nested-struct cases above.
  defp encode_value(type, value, _types), do: encode_value(type, value)

  defp encode_struct_array(element_type, values, types) do
    Enum.reduce_while(values, {:ok, <<>>}, fn v, {:ok, acc} ->
      case hash_struct(element_type, v, types) do
        {:ok, h} -> {:cont, {:ok, <<acc::binary, h::binary>>}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, concatenated} -> {:ok, ExKeccak.hash_256(concatenated)}
      err -> err
    end
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
