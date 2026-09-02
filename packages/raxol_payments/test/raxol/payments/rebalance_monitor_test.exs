defmodule Raxol.Payments.RebalanceMonitorTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.{RebalanceMonitor, RebalancePolicy, SettlementLedger}
  alias Raxol.Payments.ChainReader.Stub

  defp policy do
    %RebalancePolicy{
      gas_floor: %{8453 => Decimal.new("0.01")},
      gas_target: %{8453 => Decimal.new("0.05")},
      inventory_floor: %{},
      inventory_target: %{}
    }
  end

  defp eth_price do
    fn
      "ETH" -> Decimal.new("2000")
      _ -> nil
    end
  end

  setup do
    ledger =
      start_supervised!(
        {SettlementLedger, table_name: :"rm_#{System.unique_integer([:positive])}"}
      )

    %{ledger: ledger}
  end

  test "advise_once recommends a gas refuel from a below-floor native balance", %{ledger: ledger} do
    # 0.005 ETH on Base, floor 0.01.
    reader = Stub.new(balances: %{{8453, "0xsolver"} => 5_000_000_000_000_000})

    recs =
      RebalanceMonitor.advise_once(
        ledger: ledger,
        reader: reader,
        solver_address: "0xsolver",
        policy: policy(),
        chains: [8453],
        price_fn: eth_price()
      )

    # The monitor gathers native balances only, so USDC funding is unknown
    # (:insufficient_usdc). The refuel is still recommended and correctly sized.
    assert [{:refuel_gas, r}] = recs
    assert r.chain_id == 8453
    assert Decimal.equal?(r.native_to_buy, Decimal.new("0.045"))
  end

  test "sweep_now runs a cycle and returns recommendations without auto-firing", %{ledger: ledger} do
    reader = Stub.new(balances: %{{8453, "0xsolver"} => 0})

    monitor =
      start_supervised!({
        RebalanceMonitor,
        # Push the periodic sweep far out so only sweep_now runs during the test.
        name: :"mon_#{System.unique_integer([:positive])}",
        ledger: ledger,
        reader: reader,
        solver_address: "0xsolver",
        policy: policy(),
        chains: [8453],
        price_fn: eth_price(),
        initial_delay_ms: 3_600_000
      })

    assert [{:refuel_gas, %{chain_id: 8453}}] = RebalanceMonitor.sweep_now(monitor)
  end

  describe "demand-aware floors reach the sweep" do
    # $5 floor / $25 target for USDC on Base, and the solver holds $20 there --
    # comfortably above the static floor, so only demand can make this a deficit.
    defp inventory_policy(opts) do
      %RebalancePolicy{
        gas_floor: %{},
        gas_target: %{},
        inventory_floor: %{8453 => %{"USDC" => Decimal.new("5")}},
        inventory_target: %{8453 => %{"USDC" => Decimal.new("25")}},
        asset_tiers: %{"USDC" => :stable}
      }
      |> RebalancePolicy.with_demand(opts)
    end

    defp usdc_reader do
      {:ok, token} = Raxol.Payments.Assets.address(8453, "USDC")
      Stub.new(erc20: %{{8453, token, "0xsolver"} => 20_000_000})
    end

    defp record_fill(ledger, dollars, extra \\ %{}) do
      entry =
        Map.merge(
          %{
            intent_id: "rm_#{System.unique_integer([:positive])}",
            from_chain_id: 42_161,
            to_chain_id: 8453,
            token_symbol: "USDC",
            fee_collected: "100",
            fee_currency: "USDC",
            fee_decimals: 6,
            to_amount: Raxol.Payments.Assets.to_atomic(dollars, 6),
            to_symbol: "USDC",
            to_decimals: 6,
            gas_status: :confirmed
          },
          extra
        )

      assert {:ok, :recorded} = SettlementLedger.record_settlement(ledger, entry)
    end

    defp sweep(ledger, policy) do
      RebalanceMonitor.advise_once(
        ledger: ledger,
        reader: usdc_reader(),
        solver_address: "0xsolver",
        policy: policy,
        chains: [8453],
        price_fn: eth_price()
      )
    end

    test "a large recent fill raises the floor through the real sweep", %{ledger: ledger} do
      # The end-to-end path the feature exists for: a $500 order landed on Base,
      # so at 0.1x that chain should be carrying $50 and its $20 is short $30.
      # Nothing here hands the advisor a hand-built demand map -- `advise_once/1`
      # reads it off the ledger, which is what makes this a test of the wiring.
      record_fill(ledger, "500")

      # The cap is mandatory but set well clear of $50 so it is not what is
      # under test here.
      policy = inventory_policy(demand_multiplier: "0.1", demand_floor_cap: "1000")

      assert [{:alert, alert}] = sweep(ledger, policy)
      assert alert.kind == :inventory_underfunded
      assert Decimal.equal?(alert.deficit, Decimal.new("30"))
    end

    test "the same ledger with no multiplier configured changes nothing", %{ledger: ledger} do
      record_fill(ledger, "500")

      assert [] = sweep(ledger, inventory_policy([]))
    end

    test "the cap bounds what one whale order can demand", %{ledger: ledger} do
      record_fill(ledger, "5000")

      policy = inventory_policy(demand_multiplier: "0.1", demand_floor_cap: "25")

      assert [{:alert, alert}] = sweep(ledger, policy)
      # Uncapped the floor would be $500; capped it is $25, so $20 is short $5.
      assert Decimal.equal?(alert.deficit, Decimal.new("5"))
    end

    test "a fill older than the window no longer sizes the floor", %{ledger: ledger} do
      # `peak` never decays, so an unwindowed read would let this one historic
      # order pin the floor for the life of the ledger. Stamped at the epoch
      # rather than sized against a tight window, so the assertion is about the
      # window existing at all and not about a millisecond boundary.
      record_fill(ledger, "500", %{timestamp_ms: 1_000})

      policy = inventory_policy(demand_multiplier: "0.1", demand_floor_cap: "1000")

      assert [] = sweep(ledger, policy)

      # The same fill, inside a window wide enough to reach 1970, is evidence
      # again -- so the emptiness above is the window and not a lost entry.
      assert [{:alert, %{deficit: deficit}}] =
               RebalanceMonitor.advise_once(
                 ledger: ledger,
                 reader: usdc_reader(),
                 solver_address: "0xsolver",
                 policy: policy,
                 chains: [8453],
                 price_fn: eth_price(),
                 demand_window_ms: System.system_time(:millisecond)
               )

      assert Decimal.equal?(deficit, Decimal.new("30"))
    end
  end

  # `cap_at/2` raises on a multiplier with no cap, and it lives at the widening
  # site on purpose -- `demand_floor_cap` is a public struct field, so a policy
  # built by hand reaches the advisor without ever passing through
  # `with_demand/2`. But the widening site is inside the periodic sweep, where a
  # raise is not a refusal: it is a crash, a supervisor restart, and the same
  # crash on the next tick, forever, over a value that was wrong before the
  # process started. So the invariant is ALSO asserted once at init.
  describe "a policy that cannot widen a floor is refused at start" do
    defp half_configured do
      struct(RebalancePolicy,
        inventory_floor: %{8453 => %{"USDC" => Decimal.new("5")}},
        inventory_target: %{8453 => %{"USDC" => Decimal.new("25")}},
        demand_multiplier: Decimal.new("0.1")
      )
    end

    test "init refuses a multiplier with no cap", %{ledger: ledger} do
      assert_raise ArgumentError, ~r/demand_floor_cap/, fn ->
        RebalanceMonitor.init(
          ledger: ledger,
          reader: Stub.new([]),
          solver_address: "0xsolver",
          policy: half_configured()
        )
      end
    end

    test "a well-formed demand policy starts", %{ledger: ledger} do
      policy =
        RebalancePolicy.with_demand(half_configured(),
          demand_multiplier: "0.1",
          demand_floor_cap: "1000"
        )

      assert {:ok, _state} =
               RebalanceMonitor.init(
                 ledger: ledger,
                 reader: Stub.new([]),
                 solver_address: "0xsolver",
                 policy: policy
               )
    end

    test "init stores the normalized demand policy", %{ledger: ledger} do
      policy = %{half_configured() | demand_multiplier: 0.1, demand_floor_cap: 1_000}

      assert {:ok, %{opts: opts}} =
               RebalanceMonitor.init(
                 ledger: ledger,
                 reader: Stub.new([]),
                 solver_address: "0xsolver",
                 policy: policy
               )

      assert %Decimal{} = opts[:policy].demand_multiplier
      assert %Decimal{} = opts[:policy].demand_floor_cap
    end

    test "a policy with no demand config starts, unchanged", %{ledger: ledger} do
      assert {:ok, _state} =
               RebalanceMonitor.init(
                 ledger: ledger,
                 reader: Stub.new([]),
                 solver_address: "0xsolver",
                 policy: RebalancePolicy.default()
               )
    end
  end
end
