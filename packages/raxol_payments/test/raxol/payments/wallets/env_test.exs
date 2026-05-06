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
end
