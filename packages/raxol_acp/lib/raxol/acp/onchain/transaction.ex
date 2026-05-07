defmodule Raxol.ACP.Onchain.Transaction do
  @moduledoc """
  EIP-1559 typed transaction (`TransactionType = 0x02`).

  Holds the canonical fields, computes the signing hash, and serializes
  the signed payload for `eth_sendRawTransaction`.

  ## Field order (per EIP-1559)

      [chain_id, nonce, max_priority_fee_per_gas, max_fee_per_gas,
       gas_limit, to, value, data, access_list,
       y_parity, r, s]

  The unsigned hash is `keccak256(0x02 || rlp(first 9 fields))`.

  The signed serialization is `0x02 || rlp(all 12 fields)`.

  ## Why `0x02 ||` -- not concatenated as the first list element

  Per EIP-2718 typed transactions, the type byte sits **outside** the
  RLP list. Decoders dispatch on the leading byte and parse the
  remainder accordingly.

  ## Address representation

  `to` is a 20-byte binary internally; the encoders accept either raw
  bytes or a 0x-prefixed hex string. Addresses round-trip through
  `address_bytes/1` to canonicalize.
  """

  alias Raxol.ACP.Onchain.Rlp

  @type address :: <<_::160>>
  @type signature :: <<_::520>>

  defstruct [
    :chain_id,
    :nonce,
    :max_priority_fee_per_gas,
    :max_fee_per_gas,
    :gas_limit,
    :to,
    :value,
    :data,
    :access_list
  ]

  @type t :: %__MODULE__{
          chain_id: pos_integer(),
          nonce: non_neg_integer(),
          max_priority_fee_per_gas: non_neg_integer(),
          max_fee_per_gas: non_neg_integer(),
          gas_limit: non_neg_integer(),
          to: address(),
          value: non_neg_integer(),
          data: binary(),
          access_list: list()
        }

  @type_byte 0x02

  @doc """
  Build a transaction struct from a keyword/map of fields.

  `to` may be a raw 20-byte binary or a 0x-prefixed hex string. All
  other integer fields default to zero, `data` defaults to `<<>>`, and
  `access_list` defaults to `[]`.
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) when is_list(attrs), do: new(Map.new(attrs))

  def new(attrs) when is_map(attrs) do
    %__MODULE__{
      chain_id: Map.fetch!(attrs, :chain_id),
      nonce: Map.get(attrs, :nonce, 0),
      max_priority_fee_per_gas: Map.get(attrs, :max_priority_fee_per_gas, 0),
      max_fee_per_gas: Map.get(attrs, :max_fee_per_gas, 0),
      gas_limit: Map.get(attrs, :gas_limit, 0),
      to: address_bytes(Map.fetch!(attrs, :to)),
      value: Map.get(attrs, :value, 0),
      data: Map.get(attrs, :data, <<>>),
      access_list: Map.get(attrs, :access_list, [])
    }
  end

  @doc """
  Compute the keccak256 hash that the wallet signs.

  Returns a 32-byte binary.
  """
  @spec signing_hash(t()) :: <<_::256>>
  def signing_hash(%__MODULE__{} = tx) do
    payload = <<@type_byte>> <> Rlp.encode(unsigned_fields(tx))
    ExKeccak.hash_256(payload)
  end

  @doc """
  Serialize the signed transaction to its `eth_sendRawTransaction`
  payload.

  `signature` must be a 65-byte binary in `<<r::32, s::32, v::8>>` form.
  `v` is the y-parity (0 or 1) returned by ExSecp256k1.sign/2.
  """
  @spec serialize(t(), signature()) :: binary()
  def serialize(%__MODULE__{} = tx, <<r::binary-size(32), s::binary-size(32), v::8>>) do
    fields = unsigned_fields(tx) ++ [v, strip_leading_zero_bytes(r), strip_leading_zero_bytes(s)]
    <<@type_byte>> <> Rlp.encode(fields)
  end

  @doc """
  Convert a 0x-prefixed (or unprefixed) hex address to a 20-byte
  binary, or pass through a 20-byte binary unchanged.
  """
  @spec address_bytes(binary()) :: address()
  def address_bytes(<<bin::binary-size(20)>>), do: bin

  def address_bytes("0x" <> hex) when byte_size(hex) == 40 do
    Base.decode16!(hex, case: :mixed)
  end

  def address_bytes(hex) when is_binary(hex) and byte_size(hex) == 40 do
    Base.decode16!(hex, case: :mixed)
  end

  @doc "Convert a 20-byte address binary to its `0x`-prefixed lowercase hex form."
  @spec address_hex(address()) :: String.t()
  def address_hex(<<addr::binary-size(20)>>) do
    "0x" <> Base.encode16(addr, case: :lower)
  end

  # -- Private --

  # The 9 fields signed over (no signature components).
  defp unsigned_fields(tx) do
    [
      tx.chain_id,
      tx.nonce,
      tx.max_priority_fee_per_gas,
      tx.max_fee_per_gas,
      tx.gas_limit,
      tx.to,
      tx.value,
      tx.data,
      tx.access_list
    ]
  end

  # r and s are 32-byte big-endian. RLP encodes integers minimally,
  # which means leading zero bytes get stripped. We keep r and s as
  # binaries (they happen to be the right size) but strip leading zeros
  # so the RLP encoder treats them as the integer they represent. (RLP
  # of a 32-byte binary with leading zeros would encode all 32 bytes,
  # which is non-canonical for the signature.)
  defp strip_leading_zero_bytes(<<0, rest::binary>>) when rest != <<>>,
    do: strip_leading_zero_bytes(rest)

  defp strip_leading_zero_bytes(bin), do: bin
end
