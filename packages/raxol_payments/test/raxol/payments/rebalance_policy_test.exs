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

    test "clearing half the pair clears the whole setting" do
      # The two knobs are one setting, so unsetting the multiplier is exactly the
      # "unset the multiplier to keep static floors" the pair error advises. It
      # cannot itself be an error.
      configured =
        RebalancePolicy.with_demand(RebalancePolicy.default(),
          demand_multiplier: "0.1",
          demand_floor_cap: "500"
        )

      cleared = RebalancePolicy.with_demand(configured, demand_multiplier: nil)

      refute RebalancePolicy.demand_aware?(cleared)
      assert is_nil(cleared.demand_floor_cap)
    end

    test "an empty value is unset, not a parse error" do
      # `FOO=` in a fly.toml, a docker-compose entry, or a cleared secret is the
      # ordinary shape of "no value", and the accounting reader hands
      # `System.get_env/1` through untouched.
      policy =
        RebalancePolicy.with_demand(RebalancePolicy.default(),
          demand_multiplier: "",
          demand_floor_cap: "  "
        )

      refute RebalancePolicy.demand_aware?(policy)
    end

    test "a malformed value names the knob and the shape it wanted" do
      assert_raise ArgumentError, ~r/RAXOL_REBALANCE_DEMAND_MULTIPLIER.*positive decimal/s, fn ->
        RebalancePolicy.with_demand(RebalancePolicy.default(),
          demand_multiplier: "1.5x",
          demand_floor_cap: "500"
        )
      end
    end

    test "a non-positive knob is refused like a malformed one" do
      # A multiplier of zero or less can only ever widen a floor DOWN to the
      # static one, which is the "my knob did nothing" outcome the loud failure
      # exists to prevent.
      for value <- ["0", "-1"] do
        assert_raise ArgumentError, ~r/positive/, fn ->
          RebalancePolicy.with_demand(RebalancePolicy.default(),
            demand_multiplier: value,
            demand_floor_cap: "500"
          )
        end

        assert_raise ArgumentError, ~r/positive/, fn ->
          RebalancePolicy.with_demand(RebalancePolicy.default(),
            demand_multiplier: "0.1",
            demand_floor_cap: value
          )
        end
      end
    end

    test "a hand-built policy is normalized, not passed through to fail later" do
      # Normalizing only what it WRITES is not enough: a struct built by hand and
      # handed back through here would otherwise carry a float straight into the
      # advisor's Decimal arithmetic.
      policy =
        RebalancePolicy.with_demand(
          struct(RebalancePolicy, demand_multiplier: 0.1, demand_floor_cap: 500),
          []
        )

      assert Decimal.equal?(policy.demand_multiplier, Decimal.from_float(0.1))
      assert Decimal.equal?(policy.demand_floor_cap, Decimal.new(500))
    end

    test "a value of a type that is not a number at all is refused by name" do
      assert_raise ArgumentError, ~r/RAXOL_REBALANCE_DEMAND_FLOOR_CAP/, fn ->
        RebalancePolicy.with_demand(RebalancePolicy.default(),
          demand_multiplier: "0.1",
          demand_floor_cap: :five_hundred
        )
      end
    end
  end

  describe "effective_inventory_floor/4" do
    defp floor_policy(fields) do
      struct(
        %RebalancePolicy{
          inventory_floor: %{8453 => %{"USDC" => Decimal.new("5")}},
          inventory_target: %{8453 => %{"USDC" => Decimal.new("25")}}
        },
        fields
      )
    end

    defp demand(peak),
      do: %{8453 => %{"USDC" => %{peak: Decimal.new(peak), total: Decimal.new(peak), count: 1}}}

    test "a multiplier with no cap refuses to widen, however the policy was built" do
      # `demand_floor_cap` is a public struct field, so the boot-time pair check
      # is not an invariant on its own: the widening site is where an unbounded
      # floor turns into funds the auto-rebalancer moves.
      policy = floor_policy(demand_multiplier: Decimal.new("10"))

      assert_raise ArgumentError, ~r/demand_floor_cap/, fn ->
        RebalancePolicy.effective_inventory_floor(policy, 8453, "USDC", demand("1000000"))
      end
    end

    test "the cap bounds the widened floor" do
      policy =
        floor_policy(demand_multiplier: Decimal.new("10"), demand_floor_cap: Decimal.new("900"))

      floor = RebalancePolicy.effective_inventory_floor(policy, 8453, "USDC", demand("1000000"))

      assert Decimal.equal?(floor, Decimal.new("900"))
    end
  end

  describe "effective_inventory_target/4" do
    test "a floor above its own target pulls the target up, demand off" do
      # A misconfigured band ($50 floor under a $10 target) would otherwise make
      # one balance both a deficit and a surplus, and the advisor would recommend
      # draining a chain into itself. The clamp covers that with demand off too.
      policy = %RebalancePolicy{
        inventory_floor: %{8453 => %{"USDC" => Decimal.new("50")}},
        inventory_target: %{8453 => %{"USDC" => Decimal.new("10")}}
      }

      assert Decimal.equal?(
               RebalancePolicy.effective_inventory_target(policy, 8453, "USDC"),
               Decimal.new("50")
             )
    end
  end
end
