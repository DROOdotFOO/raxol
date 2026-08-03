defmodule Raxol.Earn.Xochi.JourneyInvariantsTest do
  @moduledoc """
  Invariants of the Xochi settlement journey, driven through the real
  `ExecuteXochiIntent` Action + `Ledger` + `Checkpoint` against `FakeXochi`. No
  network, no funds.

  - **Crash-resume idempotency:** a re-run of the same payment reuses the in-flight
    intent instead of quoting/signing again, and does not charge the ledger twice.
  - **Fillable-subset:** only corridors the solver can fill settle; destination
    inventory is conserved (settled x amount drawn down, never more).
  - **Ledger parity:** the ledger is charged exactly for the settled fills and
    never for an unfillable attempt -- Sum(charges) == Sum(settled).
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Earn.TestSupport.FakeXochi
  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.{Checkpoint, Ledger, SpendingPolicy}
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  @buyer_key "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @amount "1.10"
  @amount_int 1_100_000
  @poll [budget_ms: 0, fast_interval_ms: 1, timeout_ms: 2_000]

  defmodule BuyerWallet do
    @moduledoc false
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_FAKE_XOCHI_INVARIANT_KEY"
  end

  setup do
    System.put_env("RAXOL_FAKE_XOCHI_INVARIANT_KEY", @buyer_key)
    on_exit(fn -> System.delete_env("RAXOL_FAKE_XOCHI_INVARIANT_KEY") end)

    {:ok, usdc_src} = Assets.address(8453, "USDC")
    {:ok, usdc_dst} = Assets.address(10, "USDC")
    {:ok, src: usdc_src, dst: usdc_dst}
  end

  describe "crash-resume idempotency" do
    test "a resumed run reuses the in-flight intent without a second charge", ctx do
      {:ok, fake} = FakeXochi.start_link()

      context =
        exec_context(fake, agent_id: :resume)
        |> Map.merge(%{checkpoint: Checkpoint.ETS.new(), idempotency_key: "resume-1"})

      params = params(ctx)

      assert {:ok, intent} = ExecuteXochiIntent.call(params, context)
      charged = lifetime(context)

      # The process "restarts" and runs the same payment; recovery resumes it
      # from the checkpoint instead of quoting + signing a second intent.
      assert {:ok, resumed} = ExecuteXochiIntent.call(params, context)

      assert resumed.intent_id == intent.intent_id,
             "resume signed a new intent instead of reusing the in-flight one"

      assert Decimal.equal?(lifetime(context), charged),
             "resume charged the ledger a second time"

      Agent.stop(fake)
    end
  end

  describe "invariants" do
    property "only fillable corridors settle; destination inventory is conserved", ctx do
      check all(
              fills <- StreamData.integer(0..4),
              attempts <- StreamData.integer(1..5),
              max_runs: 25
            ) do
        cap = fills * @amount_int
        {:ok, fake} = FakeXochi.start_link(inventory: %{{10, ctx.dst} => cap})
        cfg = FakeXochi.config(fake)
        request = request(ctx)

        results =
          for _ <- 1..attempts, do: Xochi.transfer(cfg, request, BuyerWallet, @poll)

        settled = Enum.count(results, &match?({:ok, %{status: :completed}}, &1))

        assert settled == min(attempts, fills),
               "settled #{settled} of #{attempts} against #{fills} fills of inventory"

        assert FakeXochi.inventory(fake, 10, ctx.dst) == cap - settled * @amount_int,
               "inventory not conserved after #{settled} fills"

        Agent.stop(fake)
      end
    end

    property "the ledger is charged exactly for the settled fills, never for the unfillable",
             ctx do
      check all(
              fills <- StreamData.integer(0..3),
              attempts <- StreamData.integer(1..4),
              max_runs: 20
            ) do
        cap = fills * @amount_int
        {:ok, fake} = FakeXochi.start_link(inventory: %{{10, ctx.dst} => cap})
        {:ok, ledger} = Ledger.start_link(name: nil)
        context = exec_context(fake, agent_id: :invariant, ledger: ledger)
        params = params(ctx)

        results = for _ <- 1..attempts, do: ExecuteXochiIntent.call(params, context)
        settled = Enum.count(results, &match?({:ok, _}, &1))

        assert settled == min(attempts, fills)

        assert Decimal.equal?(lifetime(context), Decimal.mult(Decimal.new(@amount), settled)),
               "ledger charged #{lifetime(context)} for #{settled} settled fills"

        Agent.stop(fake)
        GenServer.stop(ledger)
      end
    end
  end

  # -- Helpers --

  defp exec_context(fake, opts) do
    ledger = Keyword.get_lazy(opts, :ledger, fn -> start_supervised!({Ledger, [name: nil]}) end)

    %{
      wallet: BuyerWallet,
      xochi_config: FakeXochi.config(fake),
      policy: policy(),
      ledger: ledger,
      agent_id: Keyword.fetch!(opts, :agent_id)
    }
  end

  defp params(ctx) do
    %{
      amount: @amount,
      from_chain_id: 8453,
      to_chain_id: 10,
      from_token: ctx.src,
      to_token: ctx.dst,
      settlement: "public"
    }
  end

  defp request(ctx) do
    %QuoteRequest{
      wallet: BuyerWallet.address(),
      from_chain_id: 8453,
      to_chain_id: 10,
      from_token: ctx.src,
      to_token: ctx.dst,
      from_amount: Integer.to_string(@amount_int),
      settlement_preference: "public"
    }
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("5.00"),
      session_max: Decimal.new("100.00"),
      lifetime_max: Decimal.new("100.00"),
      session_window_ms: 3_600_000,
      approved_domains: ["fake.xochi.test"]
    }
  end

  defp lifetime(context) do
    Ledger.get_totals(context.ledger, context.agent_id, context.policy).lifetime
  end
end
