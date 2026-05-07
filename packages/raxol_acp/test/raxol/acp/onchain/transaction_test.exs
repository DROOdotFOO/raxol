defmodule Raxol.ACP.Onchain.TransactionTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Onchain.Transaction

  @to_hex "0x" <> String.duplicate("ab", 20)
  @to_bytes String.duplicate(<<0xAB>>, 20)

  describe "new/1" do
    test "builds from a keyword list" do
      tx =
        Transaction.new(
          chain_id: 8453,
          nonce: 5,
          max_priority_fee_per_gas: 1_000_000_000,
          max_fee_per_gas: 20_000_000_000,
          gas_limit: 21_000,
          to: @to_hex,
          value: 100,
          data: <<0xDE, 0xAD>>
        )

      assert tx.chain_id == 8453
      assert tx.nonce == 5
      assert tx.to == @to_bytes
      assert tx.value == 100
      assert tx.data == <<0xDE, 0xAD>>
      assert tx.access_list == []
    end

    test "applies defaults for omitted fields" do
      tx = Transaction.new(chain_id: 1, to: @to_hex)

      assert tx.nonce == 0
      assert tx.max_priority_fee_per_gas == 0
      assert tx.max_fee_per_gas == 0
      assert tx.gas_limit == 0
      assert tx.value == 0
      assert tx.data == <<>>
      assert tx.access_list == []
    end

    test "accepts a 20-byte raw binary for `to`" do
      tx = Transaction.new(chain_id: 1, to: @to_bytes)
      assert tx.to == @to_bytes
    end
  end

  describe "address_bytes/1 + address_hex/1" do
    test "round-trip 0x-prefixed hex" do
      assert Transaction.address_hex(Transaction.address_bytes(@to_hex)) == @to_hex
    end

    test "accepts unprefixed hex" do
      assert Transaction.address_bytes(String.duplicate("ab", 20)) == @to_bytes
    end

    test "passes 20-byte binary through unchanged" do
      assert Transaction.address_bytes(@to_bytes) == @to_bytes
    end
  end

  describe "signing_hash/1" do
    test "produces a 32-byte binary" do
      tx = base_tx()
      hash = Transaction.signing_hash(tx)

      assert is_binary(hash)
      assert byte_size(hash) == 32
    end

    test "is deterministic for the same transaction" do
      tx = base_tx()
      assert Transaction.signing_hash(tx) == Transaction.signing_hash(tx)
    end

    test "differs across distinct transactions" do
      tx1 = base_tx()
      tx2 = %{tx1 | nonce: tx1.nonce + 1}

      refute Transaction.signing_hash(tx1) == Transaction.signing_hash(tx2)
    end

    test "differs across chain_id (replay protection)" do
      tx1 = base_tx()
      tx2 = %{tx1 | chain_id: 1}

      refute Transaction.signing_hash(tx1) == Transaction.signing_hash(tx2)
    end
  end

  describe "serialize/2" do
    test "starts with the 0x02 transaction type byte" do
      sig = synthetic_signature()
      bytes = Transaction.serialize(base_tx(), sig)

      assert <<0x02, _rest::binary>> = bytes
    end

    test "includes signature components in the encoded list" do
      tx = base_tx()
      sig = synthetic_signature()
      bytes = Transaction.serialize(tx, sig)
      unsigned = ExKeccak.hash_256(<<0x02>> <> Raxol.ACP.Onchain.Rlp.encode(unsigned_fields(tx)))

      # The signed serialization is strictly larger than the unsigned hash:
      # it contains the entire unsigned RLP plus the three signature
      # fields, all RLP-prefixed.
      assert byte_size(bytes) > byte_size(unsigned)
    end

    test "signing_hash matches keccak of (0x02 || rlp(unsigned_fields))" do
      tx = base_tx()
      manual = ExKeccak.hash_256(<<0x02>> <> Raxol.ACP.Onchain.Rlp.encode(unsigned_fields(tx)))

      assert Transaction.signing_hash(tx) == manual
    end

    test "v=0 and v=1 produce different serializations" do
      tx = base_tx()
      r = String.duplicate(<<0xAA>>, 32)
      s = String.duplicate(<<0xBB>>, 32)

      sig0 = r <> s <> <<0>>
      sig1 = r <> s <> <<1>>

      refute Transaction.serialize(tx, sig0) == Transaction.serialize(tx, sig1)
    end

    test "leading-zero r and s are stripped (canonical RLP)" do
      tx = base_tx()
      # An r/s value padded to 32 bytes with 31 leading zero bytes and
      # only the trailing byte set. RLP must NOT include the leading
      # zeros in the encoding (canonical).
      r = String.duplicate(<<0>>, 31) <> <<0xFF>>
      s = String.duplicate(<<0>>, 31) <> <<0xFF>>
      v = 1

      bytes = Transaction.serialize(tx, r <> s <> <<v>>)

      # If r and s were RLP-encoded as 32-byte binaries, each would
      # contribute 33 bytes (1 prefix + 32 body) for a total of 66
      # signature bytes. With leading zeros stripped, each is a single
      # byte (no prefix needed because 0xFF >= 0x80 -> 2 bytes), so the
      # signature contributes ~6 bytes total. The whole serialized tx
      # should fit comfortably under 100 bytes.
      assert byte_size(bytes) < 100
    end
  end

  # -- Helpers --

  defp base_tx do
    Transaction.new(
      chain_id: 8453,
      nonce: 7,
      max_priority_fee_per_gas: 1_000_000_000,
      max_fee_per_gas: 20_000_000_000,
      gas_limit: 21_000,
      to: @to_hex,
      value: 0,
      data: <<>>,
      access_list: []
    )
  end

  defp synthetic_signature do
    String.duplicate(<<0xAA>>, 32) <> String.duplicate(<<0xBB>>, 32) <> <<1>>
  end

  # Mirrors the private function in Transaction so we can spot-check
  # signing_hash without exposing internals.
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
end
