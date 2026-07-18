defmodule Raxol.Payments.Eip191Test do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Eip191

  describe "digest/1" do
    test "hashes the EIP-191 personal_sign prefixed message" do
      msg = "raxol"

      expected =
        ExKeccak.hash_256("\x19Ethereum Signed Message:\n5" <> msg)

      assert Eip191.digest(msg) == expected
      assert byte_size(Eip191.digest(msg)) == 32
    end

    test "uses byte length, not codepoint length, for multibyte messages" do
      # "é" is 2 bytes in UTF-8, so the length prefix is "2".
      msg = "é"
      assert byte_size(msg) == 2

      assert Eip191.digest(msg) ==
               ExKeccak.hash_256("\x19Ethereum Signed Message:\n2" <> msg)
    end
  end

  describe "normalize_recovery_id/1" do
    test "maps Ethereum 27/28 to secp256k1 0/1 and passes 0/1 through" do
      assert Eip191.normalize_recovery_id(27) == 0
      assert Eip191.normalize_recovery_id(28) == 1
      assert Eip191.normalize_recovery_id(0) == 0
      assert Eip191.normalize_recovery_id(1) == 1
    end
  end
end
