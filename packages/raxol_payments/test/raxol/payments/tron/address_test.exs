defmodule Raxol.Payments.Tron.AddressTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Tron.Address

  # Known ground-truth vector: the USDT TRC-20 contract address.
  @usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @usdt_hex "0x41a614f803b6fd780986a42c78ec9c7f77e6ded13c"
  @usdc "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"

  describe "valid?/1" do
    test "accepts a well-formed Tron address" do
      assert Address.valid?(@usdt)
      assert Address.valid?(@usdc)
    end

    test "rejects an address with a corrupted checksum" do
      <<head::binary-size(33), last::binary>> = @usdt
      flipped = if last == "t", do: "u", else: "t"
      refute Address.valid?(head <> flipped)
    end

    test "rejects EVM addresses, garbage, and non-strings" do
      refute Address.valid?("0x" <> String.duplicate("ab", 20))
      refute Address.valid?("not an address")
      refute Address.valid?("")
      refute Address.valid?(nil)
      refute Address.valid?(123)
    end
  end

  describe "to_hex/1 and from_hex/1" do
    test "to_hex matches the known hex form" do
      assert Address.to_hex(@usdt) == {:ok, @usdt_hex}
    end

    test "from_hex matches the known Base58 form" do
      assert Address.from_hex(@usdt_hex) == {:ok, @usdt}
    end

    test "from_hex accepts hex without the 0x prefix" do
      "0x" <> bare = @usdt_hex
      assert Address.from_hex(bare) == {:ok, @usdt}
    end

    test "round-trips Base58 -> hex -> Base58" do
      assert {:ok, hex} = Address.to_hex(@usdc)
      assert Address.from_hex(hex) == {:ok, @usdc}
    end

    test "to_hex rejects a malformed address" do
      assert Address.to_hex("not valid") == {:error, :invalid_address}
    end

    test "from_hex rejects hex without the 0x41 prefix" do
      assert Address.from_hex("0x" <> String.duplicate("ab", 21)) == {:error, :invalid_address}
    end
  end
end
