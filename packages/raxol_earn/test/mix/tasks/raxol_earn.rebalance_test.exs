defmodule Mix.Tasks.RaxolEarn.RebalanceTest do
  # async: false -- Mix.shell/1 is process-global.
  use ExUnit.Case, async: false

  alias Mix.Tasks.RaxolEarn.Rebalance
  alias Raxol.Payments.RebalancePolicy

  @demand [demand_multiplier: "0.1", demand_floor_cap: "500"]

  describe "resolve_policy/2" do
    test "a deployment with no demand config sweeps with static floors" do
      assert {:ok, policy} = Rebalance.resolve_policy([], [])
      refute RebalancePolicy.demand_aware?(policy)
    end

    test "demand-aware config is refused, because this sweep cannot honour it" do
      # The task runs in its own VM against a throwaway empty ledger, so every
      # corridor reports zero demand and each floor silently falls back to the
      # static one. Printing "no recommendations" from that is worse than
      # printing nothing: it reads as a clean sweep.
      assert {:error, message} = Rebalance.resolve_policy(@demand, [])

      assert message =~ "RAXOL_REBALANCE_DEMAND_MULTIPLIER"
      assert message =~ "--static-floors"
    end

    test "--static-floors accepts static floors explicitly, and says so" do
      assert {:static, policy} = Rebalance.resolve_policy(@demand, static_floors: true)
      refute RebalancePolicy.demand_aware?(policy)
    end

    test "half the pair is returned as an operator-facing error" do
      # The second shape is the one `Accounting.env_config/0` actually produces:
      # it reads both vars unconditionally, so the unset half arrives PRESENT as
      # nil. Only the first shape was covered here, which is how a dead pair
      # guard shipped twice.
      for acc <- [[demand_multiplier: "0.1"], [demand_multiplier: "0.1", demand_floor_cap: nil]] do
        assert {:error, message} = Rebalance.resolve_policy(acc, [])
        assert message =~ "without :demand_floor_cap"
      end
    end
  end

  describe "parse_argv/1" do
    test "recognizes --static-floors and ignores the rest" do
      assert Rebalance.parse_argv(["--static-floors"]) == [static_floors: true]
      assert Rebalance.parse_argv([]) == []
    end
  end
end
