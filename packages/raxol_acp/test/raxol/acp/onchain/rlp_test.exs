defmodule Raxol.ACP.Onchain.RlpTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Onchain.Rlp

  describe "integer encoding (canonical RLP test vectors)" do
    test "0 encodes as 0x80 (empty string)" do
      assert Rlp.encode(0) == <<0x80>>
    end

    test "1 encodes as 0x01" do
      assert Rlp.encode(1) == <<0x01>>
    end

    test "127 encodes as 0x7f (single byte, no prefix)" do
      assert Rlp.encode(127) == <<0x7F>>
    end

    test "128 encodes as 0x81 0x80 (single byte, prefixed because >= 0x80)" do
      assert Rlp.encode(128) == <<0x81, 0x80>>
    end

    test "256 encodes as 0x82 0x01 0x00" do
      assert Rlp.encode(256) == <<0x82, 0x01, 0x00>>
    end

    test "1024 encodes as 0x82 0x04 0x00" do
      assert Rlp.encode(1024) == <<0x82, 0x04, 0x00>>
    end
  end

  describe "binary encoding" do
    test "empty string encodes as 0x80" do
      assert Rlp.encode(<<>>) == <<0x80>>
    end

    test "single byte < 0x80 passes through" do
      assert Rlp.encode(<<0x00>>) == <<0x00>>
      assert Rlp.encode(<<0x7F>>) == <<0x7F>>
    end

    test "single byte >= 0x80 prefixed with 0x81" do
      assert Rlp.encode(<<0x80>>) == <<0x81, 0x80>>
      assert Rlp.encode(<<0xFF>>) == <<0x81, 0xFF>>
    end

    test "\"dog\" encodes as 0x83 d o g" do
      assert Rlp.encode("dog") == <<0x83, ?d, ?o, ?g>>
    end

    test "55-byte string uses single-byte 0x80 + len prefix" do
      bin = String.duplicate("a", 55)
      assert <<0xB7, ^bin::binary>> = Rlp.encode(bin)
    end

    test "56-byte string uses 0xb7 + 1 + length-byte" do
      bin = String.duplicate("a", 56)
      assert <<0xB8, 0x38, ^bin::binary>> = Rlp.encode(bin)
    end

    test "1024-byte string uses 0xb7 + 2 + length-bytes" do
      bin = String.duplicate("a", 1024)
      <<prefix, len_hi, len_lo, rest::binary>> = Rlp.encode(bin)

      assert prefix == 0xB9
      assert len_hi == 0x04
      assert len_lo == 0x00
      assert rest == bin
    end
  end

  describe "list encoding" do
    test "empty list encodes as 0xc0" do
      assert Rlp.encode([]) == <<0xC0>>
    end

    test "[\"cat\", \"dog\"] encodes per the Yellow Paper" do
      expected = <<0xC8, 0x83, ?c, ?a, ?t, 0x83, ?d, ?o, ?g>>
      assert Rlp.encode(["cat", "dog"]) == expected
    end

    test "nested lists encode recursively" do
      # set_3 from the Yellow Paper: [[], [[]], [[], [[]]]]
      assert Rlp.encode([[], [[]], [[], [[]]]]) ==
               <<0xC7, 0xC0, 0xC1, 0xC0, 0xC3, 0xC0, 0xC1, 0xC0>>
    end

    test "list with > 55 bytes payload uses 0xf7 + len-bytes" do
      # 56 strings of "a" -> 56 bytes payload
      payload = List.duplicate("a", 56)

      <<prefix, length_byte, rest::binary>> = Rlp.encode(payload)

      assert prefix == 0xF8
      assert length_byte == 56
      assert rest == String.duplicate(<<?a>>, 56)
    end
  end

  describe "to_minimal_be/1" do
    test "0 is the empty binary (RLP convention)" do
      assert Rlp.to_minimal_be(0) == <<>>
    end

    test "strips leading zero bytes" do
      assert Rlp.to_minimal_be(0xFF) == <<0xFF>>
      assert Rlp.to_minimal_be(0x0100) == <<0x01, 0x00>>
      assert Rlp.to_minimal_be(0xABCDEF) == <<0xAB, 0xCD, 0xEF>>
    end
  end

  describe "EIP-1559 transaction shape (mixed integers + bytes32 + list)" do
    test "a representative chain_id + nonce + small value list round-trips" do
      # Just smoke-test: encode succeeds and is non-empty.
      to = String.duplicate(<<0xAB>>, 20)

      tx_fields = [
        # chain_id
        8453,
        # nonce
        0,
        # max_priority_fee
        1_000_000_000,
        # max_fee
        20_000_000_000,
        # gas_limit
        21_000,
        # to
        to,
        # value (wei)
        0,
        # data
        <<>>,
        # access_list
        []
      ]

      encoded = Rlp.encode(tx_fields)

      assert is_binary(encoded)
      assert byte_size(encoded) > 30
      # First byte is a list prefix (>= 0xc0).
      <<first, _::binary>> = encoded
      assert first >= 0xC0
    end
  end
end
