defmodule Raxol.ACP.Xochi.JourneyTest do
  @moduledoc """
  Deterministic user-journey tests for ordering Riddler/Xochi cross-chain
  settlement through the Virtuals ACP -- the offline counterpart of the
  `:live_xochi_order` gate. Everything runs against `FakeXochi` (a stateful
  in-memory Xochi worker + Riddler solver), through the REAL client, protocol,
  offering, JobSession and Settler code. No network, no funds.

  The happy and rejection journeys read as `Raxol.ACP.Test.Scenario` pipes; the
  inventory sweep drops to the payments protocol directly. Together they cover the
  emergent behaviors a per-test canned stub cannot, and that the launch mesh
  preflight surfaced live:

  1. the full happy journey (buyer quotes+signs, seller settles, deliverable);
  2. destination-inventory exhaustion -> the fillable subset settles, the rest
     quote `can_solve: false` (the L1-heavy USDC finding);
  3. an unavailable origin (Robinhood/USDG) 503s while EVM corridors still quote
     (axol-io/Riddler#419), as a red test rather than a live surprise.
  """

  use ExUnit.Case, async: false

  import Raxol.ACP.Test.Scenario

  alias Raxol.ACP.Xochi.CapacityLedger
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  # A well-known Anvil dev key: the buyer's real signer for the EIP-712 intent +
  # origin-pull authorization. Signs locally; never touches a chain.
  @buyer_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @amount "1100000"
  @amount_int 1_100_000

  # The canonical Riddler solver the live gate pins as the origin-pull recipient,
  # and an attacker address a forged/MITM quote might retarget the pull to.
  @canonical_solver "0x97D447561fDe10E959E782a29411D8F89586d80b"
  @attacker "0x000000000000000000000000000000000000dEaD"

  defmodule BuyerWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_FAKE_XOCHI_JOURNEY_KEY"
  end

  setup do
    System.put_env("RAXOL_FAKE_XOCHI_JOURNEY_KEY", @buyer_key)
    on_exit(fn -> System.delete_env("RAXOL_FAKE_XOCHI_JOURNEY_KEY") end)
    :ok
  end

  describe "happy journey" do
    test "a buyer orders the offering and the seller settles it end-to-end" do
      new(wallet: BuyerWallet)
      |> order("USDC", from: 8453, to: 10, amount: @amount)
      |> settle()
      |> assert_delivered()
    end

    test "settling draws down the destination inventory" do
      {:ok, dst} = Assets.address(10, "USDC")

      new(wallet: BuyerWallet, inventory: %{{10, dst} => @amount_int})
      |> order("USDC", from: 8453, to: 10, amount: @amount)
      |> settle()
      |> assert_delivered()
      |> assert_inventory(10, "USDC", 0)
    end
  end

  describe "destination inventory exhaustion" do
    test "settles the fillable subset, then quotes can_solve:false once inventory is gone" do
      from = 8453
      to = 10
      {:ok, src} = Assets.address(from, "USDC")
      {:ok, dst} = Assets.address(to, "USDC")

      # Exactly two fills of inventory on the destination leg.
      {:ok, fake} =
        Raxol.ACP.TestSupport.FakeXochi.start_link(inventory: %{{to, dst} => @amount_int * 2})

      cfg = Raxol.ACP.TestSupport.FakeXochi.config(fake)

      results =
        for _ <- 1..3 do
          Xochi.transfer(cfg, request(from, to, src, dst), BuyerWallet,
            budget_ms: 0,
            fast_interval_ms: 1,
            timeout_ms: 2_000
          )
        end

      settled = Enum.count(results, &match?({:ok, %{status: :completed}}, &1))
      unfillable = Enum.count(results, &match?({:error, {:cannot_solve, _}}, &1))

      assert settled == 2, "expected the fillable subset (2) to settle, got #{inspect(results)}"

      assert unfillable == 1,
             "expected the exhausted cell to be unfillable, got #{inspect(results)}"

      assert Raxol.ACP.TestSupport.FakeXochi.inventory(fake, to, dst) == 0
    end
  end

  describe "unavailable origin (Robinhood / USDG)" do
    test "a Robinhood-origin order is rejected while an EVM corridor still quotes and signs" do
      # Out of Robinhood: the solver is temporarily unavailable, so the buyer
      # cannot even sign an intent -- the order is rejected before any funds move.
      scenario =
        new(wallet: BuyerWallet, unavailable_origins: [4663])
        |> order("USDC", from: 4663, to: 8453, amount: @amount)
        |> assert_order_rejected()

      # Same solver, an EVM corridor is unaffected: quotes and signs, ready to order.
      {:ok, src} = Assets.address(8453, "USDC")
      {:ok, dst} = Assets.address(10, "USDC")

      assert {:ok, bundle} =
               Xochi.quote_and_sign(cfg(scenario), request(8453, 10, src, dst), BuyerWallet)

      assert is_binary(bundle.signature)
    end
  end

  describe "origin-pull solver pin" do
    test "a canonical-solver quote settles when the solver is pinned" do
      new(wallet: BuyerWallet, solver_allowlist: [@canonical_solver])
      |> order("USDC", from: 8453, to: 10, amount: @amount)
      |> settle()
      |> assert_delivered()
    end

    test "a quote that retargets the origin pull off the pinned solver is rejected before signing" do
      # The drain vector: a hostile/MITM quote serves an origin pull whose `to` is
      # the attacker, not the pinned solver. It must abort before any signature.
      scenario =
        new(wallet: BuyerWallet, solver: @attacker, solver_allowlist: [@canonical_solver])
        |> order("USDC", from: 8453, to: 10, amount: @amount)
        |> assert_order_rejected()

      assert {:quote_failed, {:authorization_mismatch, :pull_to}} = error(scenario)
    end
  end

  describe "liquidity caps" do
    test "an order within the destination cap settles" do
      {:ok, dst} = Assets.address(10, "USDC")

      new(wallet: BuyerWallet, destination_caps: %{{10, dst} => 10_000_000_000})
      |> order("USDC", from: 8453, to: 10, amount: @amount)
      |> settle()
      |> assert_delivered()
    end

    test "an order above the destination cap is rejected before escrow" do
      {:ok, dst} = Assets.address(10, "USDC")

      scenario =
        new(wallet: BuyerWallet, destination_caps: %{{10, dst} => 1_000_000})
        |> order("USDC", from: 8453, to: 10, amount: @amount)
        |> assert_order_rejected()

      assert {:accept_failed, {:rejected, {:over_capacity, 10, ^dst}}} = error(scenario)
    end

    test "a closed-origin order (Robinhood until the USDG exit is fixed) is rejected" do
      scenario =
        new(wallet: BuyerWallet, closed_origins: [4663])
        |> order("USDC", from: 4663, to: 8453, amount: @amount)
        |> assert_order_rejected()

      assert {:accept_failed, {:rejected, {:origin_closed, 4663}}} = error(scenario)
    end
  end

  describe "aggregate (rolling) capacity" do
    test "concurrent orders cannot over-commit destination inventory" do
      {:ok, dst} = Assets.address(10, "USDC")
      # Capacity for exactly two 1.10 fills on the destination leg.
      start_supervised!({CapacityLedger, capacity: %{{10, dst} => 2 * @amount_int}})

      for _ <- 1..2 do
        new(wallet: BuyerWallet)
        |> order("USDC", from: 8453, to: 10, amount: @amount)
        |> settle()
        |> assert_delivered()
      end

      # The third order would push the running total past capacity, even though the
      # solver's own inventory is unlimited -- rejected before escrow.
      third =
        new(wallet: BuyerWallet)
        |> order("USDC", from: 8453, to: 10, amount: @amount)
        |> assert_order_rejected()

      assert {:accept_failed, {:rejected, {:over_capacity, 10, ^dst}}} = error(third)
    end
  end

  defp request(from, to, src, dst) do
    %QuoteRequest{
      wallet: BuyerWallet.address(),
      from_chain_id: from,
      to_chain_id: to,
      from_token: src,
      to_token: dst,
      from_amount: @amount,
      settlement_preference: "public"
    }
  end
end
