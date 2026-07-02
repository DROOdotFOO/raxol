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
end
