defmodule Raxol.Payments.Wallets.EnvTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Wallets.Env

  # Hardhat account #0
  @test_env_var "TEST_WALLET_KEY"
  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

  @domain %{
    name: "Test",
    version: "1",
    chainId: 1,
    verifyingContract: "0x" <> String.duplicate("ab", 20)
  }

  @types %{"Transfer" => [{"to", "address"}, {"amount", "uint256"}]}

  setup do
    System.put_env(@test_env_var, @test_privkey)

    on_exit(fn ->
      System.delete_env(@test_env_var)
    end)

    :ok
  end

  describe "address/1" do
    test "returns checksummed 0x-prefixed 40-hex address" do
      address = Env.address(@test_env_var)
      assert String.starts_with?(address, "0x")
      hex = String.trim_leading(address, "0x")
      assert byte_size(hex) == 40
      assert match?({:ok, _}, Base.decode16(hex, case: :mixed))
    end

    test "raises when env var is not set" do
      System.delete_env(@test_env_var)

      assert_raise RuntimeError, ~r/Failed to derive address/, fn ->
        Env.address(@test_env_var)
      end
    end

    test "raises when hex is invalid" do
      System.put_env(@test_env_var, "not_hex_at_all")

      assert_raise RuntimeError, ~r/Failed to derive address/, fn ->
        Env.address(@test_env_var)
      end
    end
  end

  describe "sign_typed_data/4" do
    test "returns {:ok, signature} for valid data" do
      message = %{to: "0x" <> String.duplicate("cd", 20), amount: 1000}

      assert {:ok, sig} = Env.sign_typed_data(@domain, @types, message, @test_env_var)
      # r (32) + s (32) + v (1) = 65 bytes
      assert byte_size(sig) == 65
    end

    test "propagates EIP-712 hash errors for invalid address" do
      message = %{to: "0xZZZZ", amount: 1000}

      assert {:error, {:invalid_hex, "address"}} =
               Env.sign_typed_data(@domain, @types, message, @test_env_var)
    end

    test "returns error when env var not set" do
      System.delete_env(@test_env_var)
      message = %{to: "0x" <> String.duplicate("cd", 20), amount: 1000}

      assert {:error, {:env_not_set, @test_env_var}} =
               Env.sign_typed_data(@domain, @types, message, @test_env_var)
    end
  end

  describe "sign_hash/2" do
    @digest String.duplicate(<<0xAB>>, 32)

    test "returns a 65-byte signature for a valid 32-byte digest" do
      assert {:ok, sig} = Env.sign_hash(@digest, @test_env_var)
      assert byte_size(sig) == 65
    end

    test "is deterministic for the same digest" do
      {:ok, sig1} = Env.sign_hash(@digest, @test_env_var)
      {:ok, sig2} = Env.sign_hash(@digest, @test_env_var)

      assert sig1 == sig2
    end

    test "different digests yield different signatures" do
      {:ok, sig1} = Env.sign_hash(@digest, @test_env_var)
      other = String.duplicate(<<0xCD>>, 32)
      {:ok, sig2} = Env.sign_hash(other, @test_env_var)

      refute sig1 == sig2
    end

    test "signature is r(32) || s(32) || y_parity(0 or 1)" do
      {:ok, <<_r::binary-size(32), _s::binary-size(32), v::8>>} =
        Env.sign_hash(@digest, @test_env_var)

      assert v in [0, 1]
    end

    test "returns error when env var not set" do
      System.delete_env(@test_env_var)

      assert {:error, {:env_not_set, @test_env_var}} =
               Env.sign_hash(@digest, @test_env_var)
    end

    test "does NOT pre-hash (input must already be a digest)" do
      # If sign_hash mistakenly keccak'd its input, signing the digest of
      # "hello" would equal signing keccak256(keccak256("hello")). Verify
      # by signing the actual digest of "hello" and comparing.
      message = "hello"
      pre_hashed = ExKeccak.hash_256(message)

      {:ok, via_hash} = Env.sign_hash(pre_hashed, @test_env_var)
      {:ok, via_message} = Env.sign_message(message, @test_env_var)

      # Both should arrive at the same signature: sign_message hashes
      # internally, sign_hash takes the digest. Equivalent end-state.
      assert via_hash == via_message
    end
  end
end
