defmodule Raxol.Payments.Protocols.XochiPullPinEnvTest do
  # async: false -- reads/writes process-global OS env vars.
  use ExUnit.Case, async: false

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.PullContracts

  @env_vars ~w(
    XOCHI_SOLVER_ETH XOCHI_SOLVER_BASE XOCHI_SOLVER_ARBITRUM
    XOCHI_SOLVER_OPTIMISM XOCHI_SOLVER_POLYGON XOCHI_PULL_REQUIRE_SOLVER_PIN
  )

  @solver "0x00000000000000000000000000000000000000a1"
  @other "0x00000000000000000000000000000000000000b2"

  setup do
    for var <- @env_vars, saved = System.get_env(var) do
      on_exit(fn -> System.put_env(var, saved) end)
    end

    Enum.each(@env_vars, &System.delete_env/1)
    on_exit(fn -> Enum.each(@env_vars, &System.delete_env/1) end)
  end

  describe "origin_pull_pin_env_config!/0" do
    test "refuses a fail-open environment: no solver address, pin not required" do
      assert_raise ArgumentError, ~r/solver pin is not configured \(fail-open\)/, fn ->
        Xochi.origin_pull_pin_env_config!()
      end

      System.put_env("XOCHI_SOLVER_BASE", "")
      System.put_env("XOCHI_PULL_REQUIRE_SOLVER_PIN", "false")

      assert_raise ArgumentError, ~r/fail-open/, fn ->
        Xochi.origin_pull_pin_env_config!()
      end
    end

    test "trusts each configured solver address and the verified pull contracts" do
      System.put_env("XOCHI_SOLVER_BASE", @solver)
      System.put_env("XOCHI_SOLVER_POLYGON", @other)
      System.put_env("XOCHI_SOLVER_ETH", @solver)

      config = Xochi.origin_pull_pin_env_config!()

      assert config[:pull_require_solver_pin] == false

      assert config[:pull_solver_allowlist] ==
               Enum.uniq([@solver, @other] ++ PullContracts.pull_recipients())
    end

    test "a required pin boots with no solver address set" do
      System.put_env("XOCHI_PULL_REQUIRE_SOLVER_PIN", "true")

      assert Xochi.origin_pull_pin_env_config!() == [
               pull_solver_allowlist: PullContracts.pull_recipients(),
               pull_require_solver_pin: true
             ]
    end
  end
end
