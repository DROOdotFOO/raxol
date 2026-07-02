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
end
