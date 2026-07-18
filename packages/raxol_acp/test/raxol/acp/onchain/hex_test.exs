defmodule Raxol.ACP.Onchain.HexTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Onchain.Hex

  describe "encode/1" do
    test "encodes a byte string as 0x-prefixed lower-case hex" do
      assert Hex.encode(<<0xDE, 0xAD>>) == "0xdead"
    end

    test "encodes the empty binary as 0x" do
      assert Hex.encode(<<>>) == "0x"
    end
  end

  describe "encode_quantity/1" do
    test "encodes zero as 0x0" do
      assert Hex.encode_quantity(0) == "0x0"
    end

    test "encodes a non-zero integer as minimal hex" do
      assert Hex.encode_quantity(30_000) == "0x7530"
    end

    test "emits lower-case hex" do
      encoded = Hex.encode_quantity(0xABCDEF)
      assert encoded == String.downcase(encoded)
      assert encoded == "0xabcdef"
    end
  end

  describe "decode_quantity/1" do
    test "decodes 0x as zero" do
      assert {:ok, 0} = Hex.decode_quantity("0x")
    end

    test "decodes lower-case hex" do
      assert {:ok, 255} = Hex.decode_quantity("0xff")
    end

    test "accepts upper-case hex" do
      assert {:ok, 255} = Hex.decode_quantity("0xFF")
    end

    test "rejects input without a 0x prefix" do
      assert {:error, _} = Hex.decode_quantity("zz")
    end

    test "rejects non-integer hex bodies" do
      assert {:error, _} = Hex.decode_quantity("0xzz")
    end
  end

  describe "decode_quantity!/1" do
    test "decodes 0x as zero" do
      assert Hex.decode_quantity!("0x") == 0
    end

    test "decodes a non-zero quantity" do
      assert Hex.decode_quantity!("0x7530") == 30_000
    end
  end
end
