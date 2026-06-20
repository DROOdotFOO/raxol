# Crosschain Stealth Payment: agent walkthrough
#
# Drives the launch path an agent takes to pay privately across chains:
# issue a delegation mandate -> execute a cross-chain stealth Xochi intent
# (spending authorized before signing) -> poll to settlement. Each step goes
# through the same Action.call/2 entry point the agent ReAct loop dispatches to.
#
# Runs fully offline against an in-process Xochi sim (a Req plug), so it spends
# no real funds. For a real run, drop the sim and point :xochi_config at a live
# endpoint, and swap the wallet for Raxol.Payments.Wallets.Op. With a real LLM
# backend (FREE_AI=true on the agent), the model chooses these tool calls
# itself; here they are scripted so the path is deterministic.
#
# Usage (from packages/raxol_payments/):
#
#   MIX_ENV=test mix run examples/crosschain_stealth_payment.exs

Logger.configure(level: :warning)

defmodule CrosschainStealthPayment do
  alias Raxol.Payments.Actions.Payments.{
    CreateMandate,
    ExecuteRelayTransfer,
    ExecuteXochiIntent,
    PollRelayStatus,
    PollXochiStatus
  }

  alias Raxol.Payments.{Ledger, SpendingPolicy}
  alias Raxol.Payments.Relay.Broadcaster
  alias Raxol.Payments.Xochi.Stealth

  @usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @base 8453
  @arbitrum 42_161
  @tron 728_126_428
  # USDT TRC-20, and a valid Tron recipient address.
  @usdt_trc20 "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  @tron_recipient "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  def run do
    wallet = ephemeral_wallet()
    {:ok, ledger} = Ledger.start_link(table_name: :stealth_demo_ledger)
    ensure_mandate_store()

    context = %{
      wallet: wallet,
      xochi_config: %{
        base_url: "https://xochi.sim",
        auth_token: "sim",
        req_options: [plug: sim()]
      },
      ledger: ledger,
      policy: policy(),
      agent_id: :stealth_demo
    }

    IO.puts("\n== crosschain stealth payment ==")
    IO.puts("wallet:   #{wallet.address()}")

    IO.puts(
      "route:    Base(#{@base}) -> Arbitrum(#{@arbitrum})  settlement=stealth\n"
    )

    meta = recipient_meta_address()

    step("1. issue delegation mandate", fn ->
      CreateMandate.call(
        %{
          agent_wallet: "0x" <> String.duplicate("a1", 20),
          scopes: ["quote", "execute", "stealth_claim"],
          max_amount_usd: 100,
          max_calls: 10,
          expires_at: System.system_time(:second) + 3600
        },
        context
      )
    end)

    intent =
      step(
        "2. execute cross-chain stealth intent (gate runs before signing)",
        fn ->
          ExecuteXochiIntent.call(
            %{
              amount: "0.50",
              from_chain_id: @base,
              to_chain_id: @arbitrum,
              from_token: @usdc,
              to_token: @usdc,
              settlement: "stealth",
              recipient_meta_address: meta
            },
            context
          )
        end
      )

    step("3. poll to settlement", fn ->
      PollXochiStatus.call(%{intent_id: intent.intent_id}, context)
    end)

    totals = Ledger.get_totals(ledger, :stealth_demo, policy())

    IO.puts(
      "\nledger:   session=#{totals.session}  lifetime=#{totals.lifetime} USDC"
    )

    IO.puts("\n4. spend gate blocks an over-limit intent:")

    case ExecuteXochiIntent.call(
           %{
             amount: "999.00",
             from_chain_id: @base,
             to_chain_id: @arbitrum,
             from_token: @usdc,
             to_token: @usdc,
             settlement: "stealth",
             recipient_meta_address: meta
           },
           context
         ) do
      {:error, failure} ->
        IO.puts(
          "   denied [#{failure.reason}]: #{failure.message} (no signature released)"
        )

      {:ok, _} ->
        IO.puts("   ERROR: over-limit intent was not blocked")
    end

    tron_leg(context)

    Process.sleep(20)
    :ok
  end

  # The Tron rail: public-only, deposit-address based. A stealth request to a
  # Tron destination is downgraded to public with a surfaced warning, and the
  # deposit is funded by the injected broadcaster (the InMemory one here; the
  # assembled build wires Raxol.ACP.Relay.OnchainBroadcaster).
  defp tron_leg(context) do
    IO.puts("\n== tron leg: relay rail (public-only) ==")
    IO.puts("route:    Base(#{@base}) -> Tron(#{@tron})  USDC -> USDT\n")

    relay_context =
      context
      |> Map.put(:relay_config, %{
        base_url: "https://relay.sim",
        auth_token: "sim",
        req_options: [plug: relay_sim()]
      })
      |> Map.put(:broadcaster, Broadcaster.InMemory)

    transfer =
      step(
        "5. stealth->Tron downgrades to public; broadcaster funds the deposit",
        fn ->
          ExecuteRelayTransfer.call(
            %{
              amount: "0.25",
              from_chain_id: @base,
              to_chain_id: @tron,
              from_token: @usdc,
              to_token: @usdt_trc20,
              to_address: @tron_recipient,
              settlement: "stealth"
            },
            relay_context
          )
        end
      )

    Enum.each(transfer.warnings, fn w ->
      IO.puts("   warn [#{w.code}]: #{w.message}")
    end)

    IO.puts(
      "   funding: #{transfer.funding}   deposit_tx: #{transfer.deposit_tx_hash}"
    )

    step("6. poll the Tron transfer to settlement", fn ->
      PollRelayStatus.call(%{transfer_id: transfer.transfer_id}, relay_context)
    end)
  end

  defp step(label, fun) do
    IO.puts(label)

    case fun.() do
      {:ok, result} ->
        IO.inspect(result, label: "   ->")
        result

      {:error, reason} ->
        IO.puts("   failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp policy do
    %SpendingPolicy{
      per_request_max: Decimal.new("1.00"),
      session_max: Decimal.new("10.00"),
      lifetime_max: Decimal.new("100.00"),
      session_window_ms: 3_600_000,
      currency: "USDC",
      approved_domains: ["xochi.sim", "relay.sim"]
    }
  end

  defp recipient_meta_address do
    {:ok, keys} =
      Stealth.derive_keys("0x" <> Base.encode16(:crypto.strong_rand_bytes(32)))

    {_, spending_pub} = keys.spending
    {_, viewing_pub} = keys.viewing

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end

  defp ensure_mandate_store do
    case Raxol.Payments.Mandate.Store.start_link([]) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp ephemeral_wallet do
    key = "0x" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    System.put_env("STEALTH_DEMO_KEY", key)

    defmodule DemoWallet do
      use Raxol.Payments.Wallets.Env, env_var: "STEALTH_DEMO_KEY"
    end

    DemoWallet
  end

  # In-process Xochi sim: canned quote / execute / status responses.
  defp sim do
    fn conn ->
      body =
        case conn.request_path do
          "/xochi/quote" ->
            %{
              "intentId" => "demo_intent",
              "quoteId" => "demo_quote",
              "canSolve" => true,
              "toAmount" => "499000",
              "xochiFee" => "1000",
              "eip712Data" => %{
                "domain" => %{
                  "name" => "Xochi",
                  "version" => "1",
                  "chainId" => @base
                },
                "types" => %{
                  "Intent" => [%{"name" => "amount", "type" => "uint256"}]
                },
                "message" => %{"amount" => 500_000}
              }
            }

          "/xochi/execute" ->
            %{
              "success" => true,
              "intentId" => "demo_intent",
              "status" => "executing",
              "stealthAddress" => "0xstealthdemo"
            }

          "/xochi/status/demo_intent" ->
            %{
              "intentId" => "demo_intent",
              "status" => "completed",
              "settlementType" => "stealth",
              "txHash" => "0xsettled",
              "terminal" => true
            }
        end

      Req.Test.json(conn, body)
    end
  end

  # In-process Relay sim: quote returns a deposit address, status settles.
  defp relay_sim do
    fn conn ->
      body =
        case conn.request_path do
          "/relay/quote" ->
            %{
              "transfer_id" => "demo_transfer",
              "quote_id" => "demo_rquote",
              "can_fill" => true,
              "to_amount" => "249000",
              "deposit_address" => "0x" <> String.duplicate("de", 20)
            }

          "/relay/execute" ->
            %{"transfer_id" => "demo_transfer", "status" => "pending"}

          "/relay/status/demo_transfer" ->
            %{
              "transfer_id" => "demo_transfer",
              "status" => "completed",
              "tx_hash" => "0xrelaysettled",
              "actual_to_amount" => "249000"
            }
        end

      Req.Test.json(conn, body)
    end
  end
end

CrosschainStealthPayment.run()
