defmodule Raxol.Payments.RebalancePolicyTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.RebalancePolicy

  test "min_notional_for tiers chain 1 as L1 and every other chain as L2" do
    p = RebalancePolicy.default()
    assert Decimal.equal?(RebalancePolicy.min_notional_for(p, 1), Decimal.new("50.00"))
    assert Decimal.equal?(RebalancePolicy.min_notional_for(p, 8453), Decimal.new("1.00"))
    assert Decimal.equal?(RebalancePolicy.min_notional_for(p, 42_161), Decimal.new("1.00"))
  end

  test "economic? gates a $1 L1 fill but allows it at the floor and for L2" do
    p = RebalancePolicy.default()
    refute RebalancePolicy.economic?(p, 1, Decimal.new("1.00"))
    assert RebalancePolicy.economic?(p, 1, Decimal.new("50.00"))
    assert RebalancePolicy.economic?(p, 8453, Decimal.new("1.00"))
  end

  test "a tier with no floor is always economic" do
    p = %RebalancePolicy{min_notional: %{l1: nil, l2: nil}}
    assert RebalancePolicy.economic?(p, 1, Decimal.new("0.01"))
    assert RebalancePolicy.economic?(p, 8453, Decimal.new("0.01"))
  end

  test "default policy sizes gas floors below targets on every chain" do
    %{gas_floor: floor, gas_target: target} = RebalancePolicy.default()

    for chain <- [1, 10, 137, 8453, 42_161] do
      assert Decimal.compare(floor[chain], target[chain]) == :lt
    end
  end

  describe "with_demand/2" do
    test "a multiplier without a cap refuses to build the policy" do
      # `peak` is sized off settled fills, so it is an input an attacker can move
      # by placing an order. Uncapped, that sizes a floor the auto-rebalancer then
      # moves funds to meet -- so this is a boot failure, not a default.
      assert_raise ArgumentError, ~r/without :demand_floor_cap/, fn ->
        RebalancePolicy.with_demand(RebalancePolicy.default(), demand_multiplier: "0.1")
      end
    end

    test "a cap without a multiplier refuses too, rather than being ignored" do
      # `demand_aware?/1` is false without a multiplier, so the cap would never be
      # read and the operator would silently get static floors.
      assert_raise ArgumentError, ~r/without :demand_multiplier/, fn ->
        RebalancePolicy.with_demand(RebalancePolicy.default(), demand_floor_cap: "500")
      end
    end

    test "both together are accepted and converted to Decimal" do
      policy =
        RebalancePolicy.with_demand(RebalancePolicy.default(),
          demand_multiplier: "0.1",
          demand_floor_cap: "500"
        )

      assert RebalancePolicy.demand_aware?(policy)
      assert Decimal.equal?(policy.demand_multiplier, Decimal.new("0.1"))
      assert Decimal.equal?(policy.demand_floor_cap, Decimal.new("500"))
    end

    test "neither leaves the feature off" do
      policy = RebalancePolicy.with_demand(RebalancePolicy.default(), [])
      refute RebalancePolicy.demand_aware?(policy)
    end

    test "an absent key does not clear an already-configured policy" do
      # `Raxol.Payments.Accounting` supplies both keys explicitly (as nil when
      # unset), so today every call starts from `default/0` and cannot notice. The
      # doc promises absent keys are left alone; a caller layering config would
      # otherwise have the first call silently undone by the second.
      configured =
        RebalancePolicy.with_demand(RebalancePolicy.default(),
          demand_multiplier: "0.1",
          demand_floor_cap: "500"
        )

      assert RebalancePolicy.with_demand(configured, []) == configured
    end

    test "an explicit nil clears the pair" do
      # The accounting path passes `System.get_env/1` results straight through, so
      # unset env vars arrive as present-but-nil and must turn the feature off.
      configured =
        RebalancePolicy.with_demand(RebalancePolicy.default(),
          demand_multiplier: "0.1",
          demand_floor_cap: "500"
        )

      cleared =
        RebalancePolicy.with_demand(configured, demand_multiplier: nil, demand_floor_cap: nil)

      refute RebalancePolicy.demand_aware?(cleared)
      assert is_nil(cleared.demand_floor_cap)
    end
  end
end
