defmodule Raxol.ApplicationSshCodeTest do
  # async: false — drives RAXOL_SSH_CODE_* env vars.
  use ExUnit.Case, async: false

  @env "RAXOL_SSH_CODE_BUDGET_USD"

  setup do
    previous = System.get_env(@env)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(@env)
        value -> System.put_env(@env, value)
      end
    end)

    :ok
  end

  # A hosted tenant runs turns on the HOST's provider credential. Without a
  # ledger and policy wired, `CostLedger.check/3` has nothing to ask and
  # passes every turn, so each tenant's spend is unbounded and unattributed.
  # Serving unmetered is the failure; refusing to serve is the fix.
  describe "spend budget is required to serve the hosted coding agent" do
    test "an unset budget refuses" do
      System.delete_env(@env)

      assert {:error, message} = Raxol.Application.ssh_code_budget()
      assert message =~ @env
    end

    test "a blank budget refuses" do
      System.put_env(@env, "")

      assert {:error, message} = Raxol.Application.ssh_code_budget()
      assert message =~ @env
    end

    test "an unparseable budget refuses rather than defaulting" do
      for bad <- ["lots", "5 dollars", "$5", "5.0.0", "--3"] do
        System.put_env(@env, bad)
        assert {:error, _message} = Raxol.Application.ssh_code_budget()
      end
    end

    test "a non-positive budget refuses" do
      for bad <- ["0", "0.0", "-1.50"] do
        System.put_env(@env, bad)
        assert {:error, _message} = Raxol.Application.ssh_code_budget()
      end
    end

    test "a positive budget is accepted only when payments can meter it" do
      System.put_env(@env, "5.00")

      case Raxol.Application.ssh_code_budget() do
        {:ok, policy} ->
          # raxol_payments is in this build: the cap becomes a real policy.
          assert Decimal.equal?(policy.lifetime_max, Decimal.new("5.00"))
          assert Decimal.equal?(policy.session_max, Decimal.new("5.00"))
          assert policy.currency == "USD"

        {:error, message} ->
          # It is not: refuse, and say why. Main raxol does not depend on
          # raxol_payments (the dependency runs the other way), so this is
          # the expected arm for the main suite.
          assert message =~ "raxol_payments"
      end
    end
  end
end
