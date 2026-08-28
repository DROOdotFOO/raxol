defmodule Raxol.Payments.RebalanceAdvisorTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.{RebalanceAdvisor, RebalancePolicy}

  defp gas_policy(chain \\ 8453) do
    %RebalancePolicy{
      gas_floor: %{chain => Decimal.new("0.01")},
      gas_target: %{chain => Decimal.new("0.05")},
      inventory_floor: %{},
      inventory_target: %{}
    }
  end

  defp price(map) do
    fn symbol -> Map.get(map, symbol) end
  end

  defp inv(map), do: %{gas: %{}, inventory: map}
  defp gas_and_inv(gas, inventory), do: %{gas: gas, inventory: inventory}

  test "prefers unwrapping WETH to refuel native ETH (no swap)" do
    balances =
      gas_and_inv(%{8453 => 5_000_000_000_000_000}, %{8453 => %{"WETH" => Decimal.new("1")}})

    assert [{:refuel_gas, r}] = RebalanceAdvisor.recommend(gas_policy(), balances, %{})
    assert r.source == :unwrap_weth
    assert Decimal.equal?(r.weth_to_unwrap, Decimal.new("0.045"))
    assert r.funding == :ok
    assert r.usd_to_convert == nil
  end

  test "falls back to swapping a stable when WETH is insufficient" do
    balances =
      gas_and_inv(%{8453 => 0}, %{
        8453 => %{"WETH" => Decimal.new("0"), "USDC" => Decimal.new("100")}
      })

    assert [{:refuel_gas, r}] =
             RebalanceAdvisor.recommend(gas_policy(), balances, %{},
               price_fn: price(%{"ETH" => Decimal.new("2000")})
             )

    assert r.source == :swap_stable
    assert r.stable == "USDC"
    assert Decimal.equal?(r.usd_to_convert, Decimal.new("100"))
    assert r.funding == :ok
  end

  test "flags insufficient_stable when neither WETH nor a stable can fund the refuel" do
    balances = gas_and_inv(%{8453 => 0}, %{8453 => %{}})

    assert [{:refuel_gas, %{source: :swap_stable, funding: :insufficient_stable}}] =
             RebalanceAdvisor.recommend(gas_policy(), balances, %{},
               price_fn: price(%{"ETH" => Decimal.new("2000")})
             )
  end

  test "never unwraps WETH on a POL-native chain; swaps a stable instead" do
    policy = gas_policy(137)
    # WETH present, but native is POL -- unwrapping WETH yields ETH, not POL.
    balances =
      gas_and_inv(%{137 => 0}, %{
        137 => %{"WETH" => Decimal.new("5"), "USDC" => Decimal.new("100")}
      })

    assert [{:refuel_gas, r}] =
             RebalanceAdvisor.recommend(policy, balances, %{},
               price_fn: price(%{"POL" => Decimal.new("0.5")})
             )

    assert r.native_symbol == "POL"
    assert r.source == :swap_stable
    assert r.stable == "USDC"
  end

  test "rebalances a USDC surplus to a deficit chain via CCTP" do
    policy = %RebalancePolicy{
      gas_floor: %{},
      gas_target: %{},
      inventory_floor: %{1 => %{"USDC" => Decimal.new("10")}},
      inventory_target: %{8453 => %{"USDC" => Decimal.new("10")}}
    }

    balances = inv(%{1 => %{"USDC" => Decimal.new("2")}, 8453 => %{"USDC" => Decimal.new("30")}})

    assert [{:rebalance_inventory, r}] = RebalanceAdvisor.recommend(policy, balances, %{})
    assert r.symbol == "USDC"
    assert r.from_chain == 8453
    assert r.to_chain == 1
    assert Decimal.equal?(r.amount, Decimal.new("8"))
    assert r.rail == :cctp
  end

  test "USDT rebalances over a generic bridge, not CCTP" do
    policy = %RebalancePolicy{
      gas_floor: %{},
      gas_target: %{},
      inventory_floor: %{1 => %{"USDT" => Decimal.new("10")}},
      inventory_target: %{8453 => %{"USDT" => Decimal.new("10")}}
    }

    balances = inv(%{1 => %{"USDT" => Decimal.new("0")}, 8453 => %{"USDT" => Decimal.new("50")}})

    assert [{:rebalance_inventory, %{symbol: "USDT", rail: :bridge}}] =
             RebalanceAdvisor.recommend(policy, balances, %{})
  end

  test "a deficit with no surplus source becomes an underfunded alert" do
    policy = %RebalancePolicy{
      gas_floor: %{},
      gas_target: %{},
      inventory_floor: %{1 => %{"USDC" => Decimal.new("10")}},
      inventory_target: %{}
    }

    balances = inv(%{1 => %{"USDC" => Decimal.new("2")}})

    assert [{:alert, %{kind: :inventory_underfunded, symbol: "USDC", chain_id: 1}}] =
             RebalanceAdvisor.recommend(policy, balances, %{})
  end

  test "advise/4 emits a recommendation event and a summary" do
    test_pid = self()
    handler = "adv-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      [
        [:raxol, :payments, :rebalance, :recommendation],
        [:raxol, :payments, :rebalance, :advice]
      ],
      fn event, meas, meta, _cfg -> send(test_pid, {:tele, event, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    balances = gas_and_inv(%{8453 => 0}, %{8453 => %{"WETH" => Decimal.new("1")}})
    RebalanceAdvisor.advise(gas_policy(), balances, %{})

    assert_receive {:tele, [:raxol, :payments, :rebalance, :recommendation], _meas,
                    %{type: :refuel_gas, source: :unwrap_weth}}

    assert_receive {:tele, [:raxol, :payments, :rebalance, :advice], %{count: 1},
                    %{refuel_count: 1}}
  end

  describe "demand-aware inventory floors" do
    # $5 floor / $25 target on two chains, USDC only. Demand is configured through
    # `with_demand/2` -- the seam every caller uses -- so these exercise a policy
    # that can actually exist: a multiplier without a cap is one the advisor
    # refuses to widen a floor with. The default cap is set far above anything
    # here, since only one test is about the cap binding.
    defp demand_policy(opts \\ []) do
      base = %RebalancePolicy{
        gas_floor: %{},
        gas_target: %{},
        inventory_floor: %{
          8453 => %{"USDC" => Decimal.new("5")},
          42_161 => %{"USDC" => Decimal.new("5")}
        },
        inventory_target: %{
          8453 => %{"USDC" => Decimal.new("25")},
          42_161 => %{"USDC" => Decimal.new("25")}
        }
      }

      case Keyword.get(opts, :multiplier) do
        nil ->
          base

        multiplier ->
          RebalancePolicy.with_demand(base,
            demand_multiplier: multiplier,
            demand_floor_cap: Keyword.get(opts, :cap, Decimal.new("1000000"))
          )
      end
    end

    defp fills(chain, symbol, peak, total) do
      %{chain => %{symbol => %{peak: Decimal.new(peak), total: Decimal.new(total), count: 2}}}
    end

    test "a chain sitting above its static floor is not a deficit without demand" do
      balances =
        inv(%{8453 => %{"USDC" => Decimal.new("20")}, 42_161 => %{"USDC" => Decimal.new("60")}})

      assert [] =
               RebalanceAdvisor.recommend(demand_policy(), balances, %{},
                 demand: fills(8453, "USDC", "500", "900")
               )
               |> Enum.filter(&match?({:rebalance_inventory, _}, &1))
    end

    test "the same chain becomes a deficit once a large fill raises its floor" do
      # $20 on Base clears the static $5 floor, but a $500 order just landed
      # there. At 0.1x that chain should be carrying $50, so it is short $30 --
      # and Arbitrum's surplus over its $25 target can cover it.
      balances =
        inv(%{8453 => %{"USDC" => Decimal.new("20")}, 42_161 => %{"USDC" => Decimal.new("60")}})

      assert [{:rebalance_inventory, move}] =
               RebalanceAdvisor.recommend(
                 demand_policy(multiplier: Decimal.new("0.1")),
                 balances,
                 %{},
                 demand: fills(8453, "USDC", "500", "900")
               )
               |> Enum.filter(&match?({:rebalance_inventory, _}, &1))

      assert move.to_chain == 8453
      assert move.from_chain == 42_161
      assert move.rail == :cctp
      assert Decimal.equal?(move.amount, Decimal.new("30"))
    end

    test "the cap bounds what one whale order can demand" do
      balances =
        inv(%{8453 => %{"USDC" => Decimal.new("20")}, 42_161 => %{"USDC" => Decimal.new("60")}})

      policy = demand_policy(multiplier: Decimal.new("0.1"), cap: Decimal.new("25"))

      assert [{:rebalance_inventory, move}] =
               RebalanceAdvisor.recommend(policy, balances, %{},
                 demand: fills(8453, "USDC", "5000", "5000")
               )
               |> Enum.filter(&match?({:rebalance_inventory, _}, &1))

      # Uncapped the floor would be $500; capped it is $25, so the deficit is $5.
      assert Decimal.equal?(move.amount, Decimal.new("5"))
    end

    test "a demand-raised floor carries its target, so no chain is both deficit and surplus" do
      # The floor lands at $50, above the static $25 target. If the target did
      # not move with it, $30 would read as BOTH under floor and over target and
      # the advisor would recommend draining this chain into itself.
      balances = inv(%{8453 => %{"USDC" => Decimal.new("30")}})

      recs =
        RebalanceAdvisor.recommend(demand_policy(multiplier: Decimal.new("0.1")), balances, %{},
          demand: fills(8453, "USDC", "500", "500")
        )

      refute Enum.any?(recs, fn
               {:rebalance_inventory, m} -> m.from_chain == m.to_chain
               _ -> false
             end)

      # It is short, and with no surplus anywhere it is an alert rather than a move.
      assert [alert] =
               for({:alert, a} <- recs, a.chain_id == 8453, do: a)

      assert alert.kind == :inventory_underfunded
      assert Decimal.equal?(alert.deficit, Decimal.new("20"))
    end

    test "demand on a chain the policy has no floor for is ignored" do
      # Demand must not invent a floor: a chain absent from inventory_floor is
      # one the policy never said carries this asset.
      balances = inv(%{999 => %{"USDC" => Decimal.new("0")}})

      recs =
        RebalanceAdvisor.recommend(
          demand_policy(multiplier: Decimal.new("1")),
          balances,
          %{},
          demand: fills(999, "USDC", "500", "500")
        )

      # The configured chains still report their own shortfalls; chain 999 is
      # simply not one this policy stocks, so demand there says nothing.
      refute Enum.any?(recs, fn
               {:alert, a} -> a.chain_id == 999
               {:rebalance_inventory, m} -> 999 in [m.to_chain, m.from_chain]
               _ -> false
             end)
    end
  end
end
