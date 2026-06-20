defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntentTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}
  alias Raxol.Payments.{Failure, Ledger, SpendingPolicy}
  alias Raxol.Payments.Xochi.Stealth

  # Wallet that signals when it signs, so tests can assert the gate runs first.
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

  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  defp config do
    %{
      base_url: "https://xochi.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp policy(overrides \\ %{}) do
    Map.merge(
      %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("5.00"),
        lifetime_max: Decimal.new("10.00"),
        session_window_ms: 3_600_000,
        approved_domains: ["xochi.test"]
      },
      overrides
    )
  end

  # A valid ERC-6538 meta-address (compressed spending + viewing pub keys), so
  # the stealth path has keys to send to Xochi.
  defp recipient_meta do
    {:ok, %{spending: {_, spending_pub}, viewing: {_, viewing_pub}}} =
      Stealth.derive_keys("0x" <> String.duplicate("11", 65))

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end

  defp base_params(overrides) do
    Map.merge(
      %{
        amount: "0.50",
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: @usdc_base,
        to_token: @usdc_base,
        settlement: "stealth",
        recipient_meta_address: recipient_meta()
      },
      overrides
    )
  end

  defp stub_quote_and_execute do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/xochi/quote" ->
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

        "/xochi/execute" ->
          Req.Test.json(conn, %{
            "success" => true,
            "intentId" => "int_1",
            "status" => "executing",
            "stealthAddress" => "0xstealth"
          })

        "/xochi/status/int_1" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "status" => "completed",
            "settlementType" => "stealth",
            "txHash" => "0xabc",
            "terminal" => true
          })
      end
    end)
  end

  describe "ExecuteXochiIntent happy path" do
    test "quotes, gates on human amount, signs, executes, returns intent" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.intent_id == "int_1"
      assert result.status == "executing"
      # 0.50 USDC at 6 decimals -> 500000 atomic units
      assert result.from_amount == "500000"
      assert result.to_amount == "499000"
      assert result.stealth_address == "0xstealth"

      assert_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end
  end

  describe "ExecuteXochiIntent stealth keys" do
    test "sends the recipient's compressed pub keys on the quote request" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/xochi/quote" ->
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

          "/xochi/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing",
              "stealthAddress" => "0xstealth"
            })
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:ok, _result} = ExecuteXochiIntent.run(base_params(%{}), ctx)

      assert_received {:quote_body, body}
      assert body["settlement_preference"] == "stealth"
      assert Regex.match?(~r/^0x0[23][a-f0-9]{64}$/, body["stealth_spending_pub_key"])
      assert Regex.match?(~r/^0x0[23][a-f0-9]{64}$/, body["stealth_viewing_pub_key"])
    end

    test "errors when stealth settlement has no recipient meta-address" do
      ctx = %{wallet: SpyWallet, xochi_config: config()}

      assert {:error, %Failure{reason: :stealth_keys_required}} =
               ExecuteXochiIntent.run(base_params(%{recipient_meta_address: nil}), ctx)

      refute_received :wallet_signed
    end
  end

  describe "ExecuteXochiIntent quote-expired retry" do
    test "re-quotes and re-executes once when the first execute reports expiry" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/xochi/quote" ->
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

          "/xochi/execute" ->
            n = Process.get(:execute_calls, 0)
            Process.put(:execute_calls, n + 1)

            if n == 0 do
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(409, Jason.encode!(%{"error" => "quote_expired"}))
            else
              Req.Test.json(conn, %{
                "success" => true,
                "intentId" => "int_1",
                "status" => "executing",
                "stealthAddress" => "0xstealth"
              })
            end
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.status == "executing"
      assert Process.get(:execute_calls) == 2

      # The reservation is held once across the retry, not double-charged.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end

    test "releases the reservation when the retry also fails" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/xochi/quote" ->
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

          "/xochi/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(409, Jason.encode!(%{"error" => "quote_expired"}))
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:error, %Failure{}} = ExecuteXochiIntent.run(base_params(%{}), ctx)

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  describe "ExecuteXochiIntent spend gate" do
    test "denies over per_request and never signs" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(%{per_request_max: Decimal.new("0.10")}),
        agent_id: "a1"
      }

      assert {:error, %Failure{reason: :over_budget}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      refute_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end
  end

  describe "ExecuteXochiIntent routing" do
    test "rejects a same-chain public transfer that does not route to Xochi" do
      ctx = %{wallet: SpyWallet, xochi_config: config()}

      params =
        base_params(%{to_chain_id: 8453, settlement: "public"})

      assert {:error, %Failure{reason: :route_unsupported}} =
               ExecuteXochiIntent.run(params, ctx)
    end

    test "errors when wallet is missing" do
      assert {:error, %Failure{reason: :config_error}} =
               ExecuteXochiIntent.run(base_params(%{}), %{xochi_config: config()})
    end
  end

  describe "ExecuteXochiIntent method guard" do
    defp stub_quote_method(payment_method) do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/xochi/quote" ->
            Req.Test.json(conn, %{
              "intent_id" => "int_1",
              "quote_id" => "q_1",
              "can_solve" => true,
              "to_amount" => "499000",
              "payment_method" => payment_method,
              "eip712" => %{
                "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
                "types" => %{"Intent" => [%{"name" => "amount", "type" => "uint256"}]},
                "message" => %{"amount" => 500_000}
              }
            })

          "/xochi/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing",
              "stealthAddress" => "0xstealth"
            })
        end
      end)
    end

    defp method_ctx do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      }
    end

    test "rejects an ERC-3009 quote for a non-USDC token before signing" do
      stub_quote_method("erc3009")
      # WETH on Base, not USDC.
      params = base_params(%{from_token: "0x4200000000000000000000000000000000000006"})

      assert {:error, %Failure{reason: :method_mismatch}} =
               ExecuteXochiIntent.run(params, method_ctx())

      refute_received :wallet_signed
    end

    test "allows an ERC-3009 quote for USDC" do
      stub_quote_method("erc3009")

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), method_ctx())
      assert result.status == "executing"
      assert_received :wallet_signed
    end
  end

  describe "PollXochiStatus" do
    test "returns the terminal status" do
      stub_quote_and_execute()
      ctx = %{xochi_config: config()}

      assert {:ok, result} = PollXochiStatus.run(%{intent_id: "int_1"}, ctx)
      assert result.status == "completed"
      assert result.terminal == true
      assert result.settlement_type == "stealth"
      assert result.tx_hash == "0xabc"
      assert result.settlement_speed == "within_budget"
    end

    test "surfaces a failed intent as an error, not {:ok}" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intentId" => "int_2",
          "status" => "failed",
          "error" => "no liquidity for route",
          "terminal" => true
        })
      end)

      ctx = %{xochi_config: config()}

      assert {:error, %Failure{reason: :no_liquidity, retryable?: false} = failure} =
               PollXochiStatus.run(%{intent_id: "int_2"}, ctx)

      assert failure.message =~ "fill"
    end

    test "surfaces an expired intent as a retryable error" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intentId" => "int_3",
          "status" => "expired",
          "terminal" => true
        })
      end)

      ctx = %{xochi_config: config()}

      assert {:error, %Failure{reason: :expired, retryable?: true}} =
               PollXochiStatus.run(%{intent_id: "int_3"}, ctx)
    end
  end
end
