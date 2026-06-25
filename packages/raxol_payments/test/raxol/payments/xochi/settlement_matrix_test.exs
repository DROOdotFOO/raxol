defmodule Raxol.Payments.Xochi.SettlementMatrixTest do
  @moduledoc """
  Deterministic verification that Raxol builds, signs, and routes a settlement
  correctly across each chain corridor for both public and stealth recipients,
  with no live solver call (Req.Test mock).

  This proves the client half end-to-end -- request construction, ERC-5564
  stealth key derivation, EIP-712 signing, and protocol/settlement routing --
  for the corridors we support. The live run against Riddler is the separate
  `:live_xochi` harness; this matrix is its always-on regression net.
  """
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.ExecuteXochiIntent
  alias Raxol.Payments.{Ledger, Router, SpendingPolicy}
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

  # Canonical USDC per chain (from Raxol.Payments.Assets).
  @usdc %{
    8453 => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
    10 => "0x0b2c639c533813f4aa9d7837caf62653d097ff85",
    42_161 => "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
  }

  @base 8453
  @optimism 10
  @arbitrum 42_161
  @tron 728_126_428

  # The EVM corridors Xochi settles (Base <-> Optimism <-> Arbitrum).
  @evm_corridors [
    {@base, @optimism},
    {@optimism, @arbitrum},
    {@arbitrum, @base},
    {@base, @arbitrum}
  ]

  @pubkey_re ~r/^0x0[23][a-f0-9]{64}$/

  defp config do
    %{
      base_url: "https://xochi.test",
      auth_token: "t",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("5.00"),
      lifetime_max: Decimal.new("100.00"),
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

  # Capture the outbound quote request body, then return a canned quote, execute,
  # and terminal status -- so a full run/2 completes without a live solver.
  defp stub_settlement do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/intent/quote" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(self(), {:quote_body, Jason.decode!(raw)})

          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "quoteId" => "q_1",
            "canSolve" => true,
            "toAmount" => "499000",
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

  defp run(from, to, settlement, extra \\ %{}) do
    stub_settlement()
    ledger = start_supervised!({Ledger, [name: nil]})

    params =
      Map.merge(
        %{
          amount: "0.50",
          from_chain_id: from,
          to_chain_id: to,
          from_token: @usdc[from],
          to_token: @usdc[to],
          settlement: settlement
        },
        extra
      )

    ctx = %{
      wallet: SpyWallet,
      xochi_config: config(),
      ledger: ledger,
      policy: policy(),
      agent_id: "a1"
    }

    ExecuteXochiIntent.run(params, ctx)
  end

  describe "public settlement across EVM corridors" do
    for {from, to} <- @evm_corridors do
      @from from
      @to to

      test "#{from} -> #{to}: builds + signs a public intent routed to xochi" do
        assert {:ok, result} = run(@from, @to, "public")
        assert result.intent_id == "int_1"

        assert_received :wallet_signed
        assert_received {:quote_body, body}

        assert body["settlement_preference"] == "public"
        assert body["from_chain_id"] == @from
        assert body["to_chain_id"] == @to
        # public settlement carries no stealth keys
        refute body["stealth_spending_pub_key"]
        refute body["stealth_viewing_pub_key"]

        assert Router.select(cross_chain: true, privacy: :public) == :xochi
      end
    end
  end

  describe "stealth settlement across EVM corridors" do
    for {from, to} <- @evm_corridors do
      @from from
      @to to

      test "#{from} -> #{to}: derives ERC-5564 keys, signs, routed to xochi" do
        assert {:ok, result} =
                 run(@from, @to, "stealth", %{recipient_meta_address: recipient_meta()})

        assert result.intent_id == "int_1"

        assert_received :wallet_signed
        assert_received {:quote_body, body}

        assert body["settlement_preference"] == "stealth"
        assert body["from_chain_id"] == @from
        assert body["to_chain_id"] == @to
        # compressed spending + viewing pub keys derived from the meta-address
        assert Regex.match?(@pubkey_re, body["stealth_spending_pub_key"])
        assert Regex.match?(@pubkey_re, body["stealth_viewing_pub_key"])

        assert Router.select(cross_chain: true, privacy: :stealth) == :xochi
      end
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
