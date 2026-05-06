defmodule Raxol.ACP.ABITest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.ABI

  describe "function_selector/1" do
    test "ERC-20 transfer(address,uint256) is 0xa9059cbb" do
      assert ABI.function_selector("transfer(address,uint256)") ==
               <<0xA9, 0x05, 0x9C, 0xBB>>
    end

    test "ERC-20 balanceOf(address) is 0x70a08231" do
      assert ABI.function_selector("balanceOf(address)") ==
               <<0x70, 0xA0, 0x82, 0x31>>
    end

    test "ERC-20 approve(address,uint256) is 0x095ea7b3" do
      assert ABI.function_selector("approve(address,uint256)") ==
               <<0x09, 0x5E, 0xA7, 0xB3>>
    end

    test "selector is always 4 bytes" do
      assert byte_size(ABI.function_selector("anything()")) == 4
    end
  end

  describe "encode_call/2 with static-only args" do
    test "transfer(address,uint256) lays out selector + 32-byte address + 32-byte amount" do
      addr = "0x" <> String.duplicate("ab", 20)

      encoded =
        ABI.encode_call("transfer(address,uint256)", [{"address", addr}, {"uint256", 1000}])

      # 4 (selector) + 32 (address word) + 32 (uint256 word) = 68 bytes
      assert byte_size(encoded) == 68

      # First 4 bytes: selector
      assert binary_part(encoded, 0, 4) == <<0xA9, 0x05, 0x9C, 0xBB>>

      # Next 32 bytes: address left-padded with 12 zero bytes
      addr_word = binary_part(encoded, 4, 32)
      assert binary_part(addr_word, 0, 12) == <<0::size(96)>>
      assert binary_part(addr_word, 12, 20) == :binary.copy(<<0xAB>>, 20)

      # Final 32 bytes: uint256 1000 big-endian
      assert binary_part(encoded, 36, 32) == <<1000::unsigned-big-256>>
    end

    test "uint256 zero encodes as 32 zero bytes" do
      encoded = ABI.encode_call("set(uint256)", [{"uint256", 0}])
      assert binary_part(encoded, 4, 32) == <<0::size(256)>>
    end

    test "bool true encodes as right-aligned 1; bool false as zeros" do
      true_call = ABI.encode_call("set(bool)", [{"bool", true}])
      false_call = ABI.encode_call("set(bool)", [{"bool", false}])

      assert binary_part(true_call, 4, 32) == <<1::unsigned-big-256>>
      assert binary_part(false_call, 4, 32) == <<0::unsigned-big-256>>
    end

    test "bytes32 right-pads short input" do
      encoded = ABI.encode_call("set(bytes32)", [{"bytes32", "0x" <> String.duplicate("ff", 4)}])
      word = binary_part(encoded, 4, 32)

      assert binary_part(word, 0, 4) == <<0xFF, 0xFF, 0xFF, 0xFF>>
      assert binary_part(word, 4, 28) == <<0::size(28 * 8)>>
    end

    test "address without 0x prefix is accepted" do
      addr = String.duplicate("cd", 20)
      encoded = ABI.encode_call("set(address)", [{"address", addr}])
      assert binary_part(encoded, 4 + 12, 20) == :binary.copy(<<0xCD>>, 20)
    end

    test "raises on wrong-length address" do
      assert_raise ArgumentError, ~r/address must be 20 bytes/, fn ->
        ABI.encode_call("set(address)", [{"address", "0x" <> String.duplicate("ab", 10)}])
      end
    end
  end

  describe "encode_call/2 with dynamic args" do
    test "single bytes arg uses head/tail layout" do
      payload = <<1, 2, 3>>
      encoded = ABI.encode_call("set(bytes)", [{"bytes", payload}])

      # Layout: 4 selector + 32 head (offset) + 32 length + 32 padded data
      assert byte_size(encoded) == 4 + 32 + 32 + 32

      # Head: offset to tail = 32 (one word, since only one arg)
      offset = binary_part(encoded, 4, 32)
      assert offset == <<32::unsigned-big-256>>

      # Tail word 1: length = 3
      length_word = binary_part(encoded, 4 + 32, 32)
      assert length_word == <<3::unsigned-big-256>>

      # Tail word 2: payload right-padded to 32 bytes
      data_word = binary_part(encoded, 4 + 32 + 32, 32)
      assert binary_part(data_word, 0, 3) == payload
      assert binary_part(data_word, 3, 29) == <<0::size(29 * 8)>>
    end

    test "string arg encodes UTF-8 bytes inline" do
      encoded = ABI.encode_call("greet(string)", [{"string", "hi"}])
      length_word = binary_part(encoded, 4 + 32, 32)
      data_word = binary_part(encoded, 4 + 32 + 32, 32)

      assert length_word == <<2::unsigned-big-256>>
      assert binary_part(data_word, 0, 2) == "hi"
    end

    test "empty bytes encodes length 0 and zero tail words" do
      encoded = ABI.encode_call("set(bytes)", [{"bytes", <<>>}])

      # 4 selector + 32 offset + 32 length + 0 data padding
      assert byte_size(encoded) == 4 + 32 + 32

      offset = binary_part(encoded, 4, 32)
      length_word = binary_part(encoded, 4 + 32, 32)

      assert offset == <<32::unsigned-big-256>>
      assert length_word == <<0::unsigned-big-256>>
    end

    test "exactly 32-byte payload pads to one word, not two" do
      payload = :binary.copy(<<0xAA>>, 32)
      encoded = ABI.encode_call("set(bytes)", [{"bytes", payload}])

      # 4 + 32 (offset) + 32 (length) + 32 (data, no overflow)
      assert byte_size(encoded) == 4 + 32 + 32 + 32

      data_word = binary_part(encoded, 4 + 32 + 32, 32)
      assert data_word == payload
    end

    test "33-byte payload pads to two words" do
      payload = :binary.copy(<<0xAA>>, 33)
      encoded = ABI.encode_call("set(bytes)", [{"bytes", payload}])

      # 4 + 32 + 32 + 64 (two words for 33 bytes)
      assert byte_size(encoded) == 4 + 32 + 32 + 64

      data = binary_part(encoded, 4 + 32 + 32, 64)
      assert binary_part(data, 0, 33) == payload
      assert binary_part(data, 33, 31) == <<0::size(31 * 8)>>
    end

    test "mixed static+dynamic args interleave heads and tails correctly" do
      addr = "0x" <> String.duplicate("ab", 20)
      payload = <<1, 2, 3>>

      encoded =
        ABI.encode_call("send(address,bytes,uint256)", [
          {"address", addr},
          {"bytes", payload},
          {"uint256", 999}
        ])

      # Head: 3 words (one per arg, dynamic gets offset)
      # head_size = 3 * 32 = 96
      # arg 0: address word (static, inline)
      # arg 1: offset = 96 (start of tail)
      # arg 2: uint256 word (static, inline)
      # Tail: length=3 + padded data

      # Selector + 96 head + 32 length + 32 padded data
      assert byte_size(encoded) == 4 + 96 + 32 + 32

      addr_word = binary_part(encoded, 4, 32)
      assert binary_part(addr_word, 12, 20) == :binary.copy(<<0xAB>>, 20)

      offset_word = binary_part(encoded, 4 + 32, 32)
      assert offset_word == <<96::unsigned-big-256>>

      uint_word = binary_part(encoded, 4 + 64, 32)
      assert uint_word == <<999::unsigned-big-256>>

      length_word = binary_part(encoded, 4 + 96, 32)
      assert length_word == <<3::unsigned-big-256>>
    end

    test "two dynamic args produce sequential tails with correct offsets" do
      encoded =
        ABI.encode_call("set(bytes,bytes)", [
          {"bytes", <<1, 2, 3>>},
          {"bytes", <<4, 5>>}
        ])

      # head_size = 64
      # tail 1: 32 length + 32 padded data = 64 bytes
      # tail 2: 32 length + 32 padded data = 64 bytes
      assert byte_size(encoded) == 4 + 64 + 64 + 64

      offset1 = binary_part(encoded, 4, 32)
      offset2 = binary_part(encoded, 4 + 32, 32)

      # First dynamic arg starts at offset 64 (right after both head slots)
      assert offset1 == <<64::unsigned-big-256>>
      # Second dynamic arg starts after the first tail (64 + 64 = 128)
      assert offset2 == <<128::unsigned-big-256>>
    end
  end
end
