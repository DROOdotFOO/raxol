defmodule Raxol.Payments.Wallets.EnvProductionGuardTest do
  # async: false -- toggles the process-global production flag.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Wallets.Env

  @test_env_var "TEST_WALLET_KEY_PROD_GUARD"
  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @digest String.duplicate(<<0xAB>>, 32)

  setup do
    System.put_env(@test_env_var, @test_privkey)
    Application.put_env(:raxol_payments, :deployment, :production)

    on_exit(fn ->
      System.delete_env(@test_env_var)
      System.delete_env("RAXOL_ALLOW_ENV_WALLET")
      Application.delete_env(:raxol_payments, :deployment)
      Application.delete_env(:raxol_payments, :allow_env_wallet)
    end)

    :ok
  end

  test "refuses to sign in production without an explicit opt-in" do
    assert {:error, :env_wallet_forbidden_in_production} =
             Env.sign_hash(@digest, @test_env_var)
  end

  test "refuses to derive an address in production" do
    assert_raise RuntimeError, ~r/env_wallet_forbidden_in_production/, fn ->
      Env.address(@test_env_var)
    end
  end

  test "the RAXOL_ALLOW_ENV_WALLET env opt-in re-enables it in production" do
    System.put_env("RAXOL_ALLOW_ENV_WALLET", "true")
    assert {:ok, sig} = Env.sign_hash(@digest, @test_env_var)
    assert byte_size(sig) == 65
  end

  test "the config opt-in re-enables it in production" do
    Application.put_env(:raxol_payments, :allow_env_wallet, true)
    assert {:ok, _sig} = Env.sign_hash(@digest, @test_env_var)
  end

  test "development is unaffected (signs freely)" do
    Application.put_env(:raxol_payments, :deployment, :development)
    assert {:ok, _sig} = Env.sign_hash(@digest, @test_env_var)
  end
end
