defmodule Raxol.ACP.Wallet.SCA.ModularAccountTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Wallet.SCA.ModularAccount

  describe "canonical addresses" do
    test "match the @account-kit/smart-contracts 4.88.x deterministic deployments" do
      assert ModularAccount.factory_address() == "0x00000000000017c61b5bEe81050EC8eFc9c6fecd"

      assert ModularAccount.implementation_address() ==
               "0x00000000000002377B26b1EdA7b0BC371C60DD4f"

      assert ModularAccount.single_signer_validation_address() ==
               "0x00000000000099DE0BF6fA90dEB851E2A2df7d83"
    end
  end

  describe "execute_calldata/3" do
    test "starts with the execute(address,uint256,bytes) selector" do
      data = ModularAccount.execute_calldata("0x" <> String.duplicate("11", 20), 0, <<>>)
      # selector = first 4 bytes of keccak256("execute(address,uint256,bytes)")
      selector = binary_part(data, 0, 4)
      expected = binary_part(ExKeccak.hash_256("execute(address,uint256,bytes)"), 0, 4)
      assert selector == expected
    end

    test "encodes target, value, and dynamic bytes" do
      target = "0x" <> String.duplicate("ab", 20)
      data = ModularAccount.execute_calldata(target, 1000, <<0xDE, 0xAD>>)

      # 4 (selector) + 32 (address) + 32 (value) + 32 (offset) + 32 (len) + 32 (padded data)
      assert byte_size(data) == 4 + 32 * 5

      <<_selector::binary-size(4), addr_word::binary-size(32), value_word::binary-size(32),
        _rest::binary>> = data

      assert <<0::96, addr::binary-size(20)>> = addr_word
      assert Base.encode16(addr, case: :lower) == String.duplicate("ab", 20)
      assert <<value::unsigned-big-256>> = value_word
      assert value == 1000
    end
  end

  describe "nonce_key/3" do
    test "packs (parallelKey << 40) | (entityId << 8) | globalFlag" do
      # entity 1, global true, parallel 0 -> (1 << 8) | 1 = 0x101
      assert ModularAccount.nonce_key(1, true, 0) == 0x101
      # entity 1, global false -> (1 << 8) | 0 = 0x100
      assert ModularAccount.nonce_key(1, false, 0) == 0x100
      # entity 0, global true -> 1
      assert ModularAccount.nonce_key(0, true, 0) == 1
    end

    test "incorporates the parallel key in bits 40+" do
      assert ModularAccount.nonce_key(0, false, 1) == Bitwise.bsl(1, 40)
      assert ModularAccount.nonce_key(2, true, 1) == Bitwise.bor(Bitwise.bsl(1, 40), 0x201)
    end

    test "defaults parallel key to 0" do
      assert ModularAccount.nonce_key(5, true) == ModularAccount.nonce_key(5, true, 0)
    end

    test "rejects an entity id larger than uint32" do
      assert_raise FunctionClauseError, fn -> ModularAccount.nonce_key(0x1_0000_0000, true, 0) end
    end
  end

  describe "pack_uo_signature/1" do
    test "prepends 0xFF 0x00 (global validation, no hook data)" do
      sig = :binary.copy(<<0xAB>>, 65)
      assert ModularAccount.pack_uo_signature(sig) == <<0xFF, 0x00>> <> sig
    end
  end

  describe "pack_1271_eoa_signature/2" do
    test "frames as 0x00 || entityId(4) || 0xFF || 0x00 || sig" do
      sig = :binary.copy(<<0xCD>>, 65)
      packed = ModularAccount.pack_1271_eoa_signature(sig, 7)

      assert <<0x00, entity::unsigned-big-32, 0xFF, 0x00, rest::binary>> = packed
      assert entity == 7
      assert rest == sig
    end

    test "rejects entity ids over uint32" do
      assert_raise FunctionClauseError, fn ->
        ModularAccount.pack_1271_eoa_signature(<<0>>, 0x1_0000_0000)
      end
    end
  end

  describe "eip191_digest/1" do
    test "matches keccak256 of the personal-sign prefix over a 32-byte hash" do
      hash = :binary.copy(<<0x11>>, 32)
      expected = ExKeccak.hash_256("\x19Ethereum Signed Message:\n32" <> hash)
      assert ModularAccount.eip191_digest(hash) == expected
    end

    test "is 32 bytes and deterministic" do
      hash = :crypto.hash(:sha256, "x")
      d1 = ModularAccount.eip191_digest(hash)
      assert byte_size(d1) == 32
      assert d1 == ModularAccount.eip191_digest(hash)
    end
  end

  describe "replay_safe_digest/3" do
    test "is 32 bytes and depends on chain id, account, and inner hash" do
      inner = :binary.copy(<<0x22>>, 32)
      account = "0x" <> String.duplicate("11", 20)

      base = ModularAccount.replay_safe_digest(inner, 8453, account)
      assert byte_size(base) == 32

      # Different chain id -> different digest
      assert base != ModularAccount.replay_safe_digest(inner, 1, account)
      # Different account -> different digest (enters via the salt)
      assert base !=
               ModularAccount.replay_safe_digest(inner, 8453, "0x" <> String.duplicate("22", 20))

      # Different inner hash -> different digest
      assert base != ModularAccount.replay_safe_digest(:binary.copy(<<0x33>>, 32), 8453, account)
    end
  end
end
