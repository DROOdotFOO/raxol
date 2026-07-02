defmodule Raxol.Payments.Xochi.SettlementMatrixTest do
  @moduledoc """
  Deterministic verification that Raxol builds, signs, and routes a settlement
  correctly across every cross-chain (chain, token) pair we support, for both
  public and stealth recipients, with no live solver call (Req.Test mock).

  The matrix is the full cross-product of `Raxol.Payments.Assets` endpoints:
  every registered (chain, token) settling to every other-chain (chain, token).
  It is therefore cross-asset by construction (e.g. Base USDC -> Robinhood Chain
  USDG), and it auto-extends the moment a chain or token is added to `Assets`.
  Robinhood Chain (4663, USDG + WETH) is in the grid.

  This proves the client half: request construction, decimals-correct origin
  sizing, ERC-5564 stealth key derivation, EIP-712 signing, protocol/settlement
  routing, and the delivery-floor backstop (a same-asset corridor gets an
  automatic 80%-of-par floor; a cross-asset corridor is bound only by an explicit
  `min_to_amount`). The live run against Riddler is the separate `:live_xochi`
  harness; this matrix is its always-on regression net.
  """
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.{Assets, Failure, Ledger, Router, SpendingPolicy}
  alias Raxol.Payments.Xochi.Stealth

  # Wallet that signals when it signs, so we can assert the intent was signed.
  defmodule SpyWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453

    def sign_typed_data(_domain, _types, _message) do
      send(self(), :wallet_signed)
      {:ok, <<7::size(520)>>}
    end

    def sign_message(_), do: {:ok, <<7::size(520)>>}
    def sign_hash(_), do: {:ok, <<7::size(520)>>}
  end

  @base 8453
  @tron 728_126_428

  # The supported EVM chains and the token universe. Addresses come from the
  # registry, so only real (chain, token) pairs become endpoints and the grid
  # tracks `Assets` automatically.
  @chains [1, 10, 137, 8453, 42_161, 4663]
  @symbols Enum.sort(Assets.symbols())

  @endpoints (for chain <- @chains,
                  symbol <- @symbols,
                  {:ok, address} <- [Assets.address(chain, symbol)],
                  do: {chain, symbol, address})

  # Every cross-chain (chain, token) -> (chain, token) pair. Cross-asset when the
  # two symbols differ (the norm for any Robinhood corridor: USDG lives only on
  # 4663), same-asset when they match.
  @corridors (for {fc, fs, fa} <- @endpoints,
                  {tc, ts, ta} <- @endpoints,
                  fc != tc,
                  do: {fc, fs, fa, tc, ts, ta})

  @pubkey_re ~r/^0x0[23][a-f0-9]{64}$/

  # The atomic from_amount a 0.50 human amount must produce, pinned by symbol so a
  # decimals regression (an 18-decimal WETH resolving as 6, say) fails here.
  @atomic %{
    "USDC" => "500000",
    "USDT" => "500000",
    "USDG" => "500000",
    "WETH" => "500000000000000000"
  }

  defp config do
    %{
      base_url: "https://xochi.test",
      auth_token: "t",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  # Permissive caps: the matrix exercises build/sign/route, not spend limits
  # (those live in spending_policy_test). 0.50 per cell stays under per_request_max.
  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("100000.00"),
      lifetime_max: Decimal.new("100000.00"),
      session_window_ms: 3_600_000,
      approved_domains: ["xochi.test"]
    }
  end

  # A real ERC-6538 meta-address (compressed spending + viewing pub keys).
  defp recipient_meta do
    {:ok, %{spending: {_, spending_pub}, viewing: {_, viewing_pub}}} =
      Stealth.derive_keys("0x" <> String.duplicate("11", 65))

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end

  # Capture the outbound quote body, then return a canned quote, execute, and
  # terminal status so a full run/2 completes without a live solver. `to_amount`
  # overrides the delivered amount (defaults to par: echo from_amount) so the
  # delivery-floor tests can serve a punitive quote.
  defp stub_settlement(to_amount) do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/intent/quote" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          body = Jason.decode!(raw)
          send(self(), {:quote_body, body})

          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "quoteId" => "q_1",
            "canSolve" => true,
            # Par delivery: echo the atomic from_amount so a same-asset corridor
            # clears its 80% floor at any decimals. Overridable for floor tests.
            "toAmount" => to_amount || body["from_amount"],
            "xochiFee" => "1000",
            "eip712Data" => %{
              "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
              "types" => %{"Intent" => [%{"name" => "amount", "type" => "uint256"}]},
              "message" => %{"amount" => 500_000}
            }
          })

        "/api/intent/execute" ->
          Req.Test.json(conn, %{
            "success" => true,
            "intentId" => "int_1",
            "status" => "executing",
            "stealthAddress" => "0xstealth"
          })

        "/api/intent/int_1/status" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "status" => "completed",
            "terminal" => true
          })
      end
    end)
  end

  # One ledger per test, reused across every cell in the loop: start_supervised!
  # cannot start two children with the same spec id, and the permissive caps keep
  # the cumulative reservation well under session/lifetime limits.
  setup do
    %{ledger: start_supervised!({Ledger, [name: nil]})}
  end

  defp run(ledger, from_chain, from_token, to_chain, to_token, settlement, extra \\ %{}) do
    stub_settlement(Map.get(extra, :to_amount))

    params =
      %{
        amount: "0.50",
        from_chain_id: from_chain,
        to_chain_id: to_chain,
        from_token: from_token,
        to_token: to_token,
        settlement: settlement
      }
      |> Map.merge(Map.drop(extra, [:to_amount]))

    ctx = %{
      wallet: SpyWallet,
      xochi_config: config(),
      ledger: ledger,
      policy: policy(),
      agent_id: "a1"
    }

    ExecuteXochiIntent.run(params, ctx)
  end

  describe "the corridor grid" do
    test "is the full cross-chain cross-product of Assets endpoints, incl. Robinhood" do
      # 17 endpoints: USDC/USDT/WETH on 5 chains + USDG/WETH on Robinhood (4663).
      assert length(@endpoints) == 17
      # Every ordered cross-chain endpoint pair.
      assert length(@corridors) == 240

      # USDG lives only on Robinhood Chain, and shows up as both origin and dest.
      assert (for {c, "USDG", _} <- @endpoints, do: c) == [4663]

      assert Enum.any?(@corridors, fn {fc, fs, _, tc, _, _} ->
               {fc, fs} == {4663, "USDG"} and tc != 4663
             end)

      assert Enum.any?(@corridors, fn {_, _, _, tc, ts, _} -> {tc, ts} == {4663, "USDG"} end)

      # The grid is cross-asset (origin and destination symbols differ) somewhere.
      assert Enum.any?(@corridors, fn {_, fs, _, _, ts, _} -> fs != ts end)
    end
  end

  describe "public settlement across the full grid" do
    test "every corridor builds, signs, and routes a public intent, origin-sized by decimals",
         %{ledger: ledger} do
      for {fc, fs, fa, tc, ts, ta} <- @corridors do
        label = "#{fs}@#{fc} -> #{ts}@#{tc}"

        assert {:ok, result} = run(ledger, fc, fa, tc, ta, "public"), "#{label}: run failed"
        assert result.intent_id == "int_1", "#{label}: wrong intent"

        assert_received {:quote_body, body}
        assert_received :wallet_signed, "#{label}: wallet did not sign"

        assert body["from_chain_id"] == fc, "#{label}: from_chain"
        assert body["to_chain_id"] == tc, "#{label}: to_chain"
        assert body["from_token"] == fa, "#{label}: from_token"
        assert body["to_token"] == ta, "#{label}: to_token"
        assert body["from_amount"] == @atomic[fs], "#{label}: origin not scaled by #{fs} decimals"
        assert body["settlement_preference"] == "public"
        refute body["stealth_spending_pub_key"], "#{label}: public carried stealth keys"
      end

      assert Router.select(cross_chain: true, privacy: :public) == :xochi
    end
  end

  describe "stealth settlement across the full grid" do
    setup do: %{meta: recipient_meta()}

    test "every corridor derives ERC-5564 keys, signs, and routes a stealth intent",
         %{ledger: ledger, meta: meta} do
      for {fc, fs, fa, tc, ts, ta} <- @corridors do
        label = "#{fs}@#{fc} -> #{ts}@#{tc}"

        assert {:ok, result} =
                 run(ledger, fc, fa, tc, ta, "stealth", %{recipient_meta_address: meta}),
               "#{label}: run failed"

        assert result.intent_id == "int_1", "#{label}: wrong intent"

        assert_received {:quote_body, body}
        assert_received :wallet_signed, "#{label}: wallet did not sign"

        assert body["settlement_preference"] == "stealth"
        assert body["from_chain_id"] == fc
        assert body["to_chain_id"] == tc
        assert Regex.match?(@pubkey_re, body["stealth_spending_pub_key"]), "#{label}: spending key"
        assert Regex.match?(@pubkey_re, body["stealth_viewing_pub_key"]), "#{label}: viewing key"
      end

      assert Router.select(cross_chain: true, privacy: :stealth) == :xochi
    end
  end

  describe "delivery floor backstop" do
    test "a same-asset corridor rejects a quote below the 80% par floor", %{ledger: ledger} do
      {:ok, from} = Assets.address(8453, "USDC")
      {:ok, to} = Assets.address(42_161, "USDC")

      # par 500000, floor 400000; a 1-unit delivery is theft, rejected pre-signing.
      assert {:error, %Failure{reason: :delivery_below_floor}} =
               run(ledger, 8453, from, 42_161, to, "public", %{to_amount: "1"})

      refute_received :wallet_signed
    end

    test "the same-asset floor is denominated in the destination's decimals (WETH is 18)",
         %{ledger: ledger} do
      {:ok, from} = Assets.address(8453, "WETH")
      {:ok, to} = Assets.address(42_161, "WETH")

      # par 5e17, floor 4e17.
      assert {:error, %Failure{reason: :delivery_below_floor}} =
               run(ledger, 8453, from, 42_161, to, "public", %{to_amount: "300000000000000000"})

      assert {:ok, _} =
               run(ledger, 8453, from, 42_161, to, "public", %{to_amount: "450000000000000000"})
    end

    test "a cross-asset corridor (Base USDC -> Robinhood USDG) has no automatic floor",
         %{ledger: ledger} do
      {:ok, from} = Assets.address(8453, "USDC")
      {:ok, to} = Assets.address(4663, "USDG")

      # Different symbols means no on-client par; the worker enforces pricing, so a
      # low delivery is accepted unless the caller pins min_to_amount.
      assert {:ok, _} = run(ledger, 8453, from, 4663, to, "public", %{to_amount: "1"})
    end

    test "an explicit min_to_amount is authoritative for a cross-asset Robinhood corridor",
         %{ledger: ledger} do
      {:ok, from} = Assets.address(8453, "USDC")
      {:ok, to} = Assets.address(4663, "USDG")

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               run(ledger, 8453, from, 4663, to, "public", %{to_amount: "1", min_to_amount: "490000"})

      refute_received :wallet_signed

      assert {:ok, _} =
               run(ledger, 8453, from, 4663, to, "public", %{
                 to_amount: "500000",
                 min_to_amount: "490000"
               })
    end
  end

  describe "Tron corridor takes the relay rail" do
    test "Base <-> Tron routes to :relay, not xochi" do
      assert Router.select(from_chain_id: @base, to_chain_id: @tron, cross_chain: true) == :relay
      assert Router.select(from_chain_id: @tron, to_chain_id: @base, cross_chain: true) == :relay
    end

    test "a stealth request to Tron is downgraded to the public relay rail" do
      assert Router.select(from_chain_id: @base, to_chain_id: @tron, privacy: :stealth) == :relay
    end
  end

  describe "routing guardrails" do
    test "same-chain public stays on x402, not xochi" do
      assert Router.select(cross_chain: false, privacy: :public) == :x402
    end

    test "stealth always routes to xochi for EVM corridors" do
      assert Router.select(privacy: :stealth) == :xochi
    end
  end
end
