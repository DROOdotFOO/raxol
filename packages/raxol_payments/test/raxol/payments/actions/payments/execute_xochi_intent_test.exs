defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntentTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments.{ExecuteXochiIntent, PollXochiStatus}
  alias Raxol.Payments.{Checkpoint, Failure, Ledger, SpendingPolicy}
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
        "/api/intent/quote" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "quoteId" => "q_1",
            "canSolve" => true,
            "toAmount" => "499000",
            "xochiFee" => "1000",
            "eip712Data" => %{
              "domain" => %{
                "name" => "Xochi",
                "version" => "1",
                "chainId" => 8453
              },
              "types" => %{
                "Intent" => [%{"name" => "amount", "type" => "uint256"}]
              },
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
                "domain" => %{
                  "name" => "Xochi",
                  "version" => "1",
                  "chainId" => 8453
                },
                "types" => %{
                  "Intent" => [%{"name" => "amount", "type" => "uint256"}]
                },
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

      assert Regex.match?(
               ~r/^0x0[23][a-f0-9]{64}$/,
               body["stealth_spending_pub_key"]
             )

      assert Regex.match?(
               ~r/^0x0[23][a-f0-9]{64}$/,
               body["stealth_viewing_pub_key"]
             )
    end

    test "errors when stealth settlement has no recipient meta-address" do
      ctx = %{wallet: SpyWallet, xochi_config: config()}

      assert {:error, %Failure{reason: :stealth_keys_required}} =
               ExecuteXochiIntent.run(
                 base_params(%{recipient_meta_address: nil}),
                 ctx
               )

      refute_received :wallet_signed
    end
  end

  describe "ExecuteXochiIntent recipient_address" do
    test "sends recipient_address on the quote request for a public transfer" do
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
              "status" => "executing"
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

      recipient = "0x2222222222222222222222222222222222222222"

      params =
        base_params(%{
          settlement: "public",
          recipient_meta_address: nil,
          recipient_address: recipient
        })

      assert {:ok, _result} = ExecuteXochiIntent.run(params, ctx)

      assert_received {:quote_body, body}
      assert body["recipient_address"] == recipient
      assert body["settlement_preference"] == "public"
    end

    test "two public transfers differing only by recipient are distinct payments" do
      # A payment to recipient B must never resume recipient A's checkpoint --
      # otherwise B's funds would follow A's already-signed intent. The recipient
      # is part of the derived idempotency key, so each signs independently.
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store
      }

      pub = fn recipient ->
        base_params(%{
          settlement: "public",
          recipient_meta_address: nil,
          recipient_address: recipient
        })
      end

      assert {:ok, _} =
               ExecuteXochiIntent.run(pub.("0x2222222222222222222222222222222222222222"), ctx)

      assert_received :wallet_signed

      assert {:ok, _} =
               ExecuteXochiIntent.run(pub.("0x3333333333333333333333333333333333333333"), ctx)

      # Signed a SECOND time -- recipient B was not resumed as recipient A's payment.
      assert_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("1.00"))
    end
  end

  describe "ExecuteXochiIntent quote-expired retry" do
    test "re-quotes and re-executes once when the first execute reports expiry" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            Req.Test.json(conn, %{
              "intentId" => "int_1",
              "quoteId" => "q_1",
              "canSolve" => true,
              "toAmount" => "499000",
              "xochiFee" => "1000",
              "eip712Data" => %{
                "domain" => %{
                  "name" => "Xochi",
                  "version" => "1",
                  "chainId" => 8453
                },
                "types" => %{
                  "Intent" => [%{"name" => "amount", "type" => "uint256"}]
                },
                "message" => %{"amount" => 500_000}
              }
            })

          "/api/intent/execute" ->
            n = Process.get(:execute_calls, 0)
            Process.put(:execute_calls, n + 1)

            if n == 0 do
              conn
              |> Plug.Conn.put_resp_content_type("application/json")
              |> Plug.Conn.send_resp(
                409,
                Jason.encode!(%{"error" => "quote_expired"})
              )
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
          "/api/intent/quote" ->
            Req.Test.json(conn, %{
              "intentId" => "int_1",
              "quoteId" => "q_1",
              "canSolve" => true,
              "toAmount" => "499000",
              "xochiFee" => "1000",
              "eip712Data" => %{
                "domain" => %{
                  "name" => "Xochi",
                  "version" => "1",
                  "chainId" => 8453
                },
                "types" => %{
                  "Intent" => [%{"name" => "amount", "type" => "uint256"}]
                },
                "message" => %{"amount" => 500_000}
              }
            })

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              409,
              Jason.encode!(%{"error" => "quote_expired"})
            )
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

      assert {:error, %Failure{}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

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
               ExecuteXochiIntent.run(base_params(%{}), %{
                 xochi_config: config()
               })
    end
  end

  describe "ExecuteXochiIntent method guard" do
    defp stub_quote_method(payment_method) do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            Req.Test.json(conn, %{
              "intent_id" => "int_1",
              "quote_id" => "q_1",
              "can_solve" => true,
              "to_amount" => "499000",
              "payment_method" => payment_method,
              "eip712" => %{
                "domain" => %{
                  "name" => "Xochi",
                  "version" => "1",
                  "chainId" => 8453
                },
                "types" => %{
                  "Intent" => [%{"name" => "amount", "type" => "uint256"}]
                },
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
      params =
        base_params(%{from_token: "0x4200000000000000000000000000000000000006"})

      assert {:error, %Failure{reason: :method_mismatch}} =
               ExecuteXochiIntent.run(params, method_ctx())

      refute_received :wallet_signed
    end

    test "allows an ERC-3009 quote for USDC" do
      stub_quote_method("erc3009")

      assert {:ok, result} =
               ExecuteXochiIntent.run(base_params(%{}), method_ctx())

      assert result.status == "executing"
      assert_received :wallet_signed
    end
  end

  describe "ExecuteXochiIntent idempotent recovery" do
    test "a repeated call resumes the in-flight intent instead of signing again" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, first} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert first.intent_id == "int_1"
      assert_received :wallet_signed

      # The process "restarts" and runs the same payment again.
      assert {:ok, second} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert second.intent_id == "int_1"
      refute_received :wallet_signed

      # Signed once, charged once.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0.50"))
    end

    test "resumes a dispatched checkpoint without signing or charging (the crash window)" do
      # No stub: a resume must not touch the network at all.
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      # The first run dispatched the intent and checkpointed it, then the process
      # was killed before it could confirm -- this is that surviving record.
      Checkpoint.put(store, "pay-1", %{
        intent_id: "int_1",
        quote_id: "q_1",
        status: :dispatched
      })

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.intent_id == "int_1"
      assert result.status == "dispatched"
      refute_received :wallet_signed

      # Resume skips the spend gate: budget was already reserved on the first run.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "without a checkpoint store a repeat call signs again (the failure prevented)" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert_received :wallet_signed
      assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert_received :wallet_signed

      # No checkpoint, no memory of the first payment: signed twice, charged twice.
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("1.00"))
    end

    test "require_checkpoint with no store fails closed before signing or charging" do
      # No stub: the guard must trip before any network or signature.
      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        require_checkpoint: true
      }

      assert {:error, %Failure{reason: :checkpoint_required, retryable?: false}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      # A missing durable checkpoint must stop the payment before it signs or
      # reserves budget -- the whole point is to prevent a crash-retry double-pay.
      refute_received :wallet_signed
      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "settling without a checkpoint emits unchecked_settlement telemetry" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})

      handler_id = "unchecked-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :payments, :xochi, :unchecked_settlement],
        fn _e, _m, meta, _ -> send(test_pid, {:unchecked, meta}) end,
        nil
      )

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1"
      }

      try do
        assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)

        # The unchecked settlement is observable, never silent.
        assert_received {:unchecked, %{wallet: "0x1111111111111111111111111111111111111111"}}
      after
        :telemetry.detach(handler_id)
      end
    end

    test "records the in-flight intent in the checkpoint after submitting" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, _} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert {:ok, record} = Checkpoint.fetch(store, "pay-1")
      assert record.intent_id == "int_1"
    end

    test "distinct payments derive distinct keys and each signs" do
      stub_quote_and_execute()
      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store
      }

      assert {:ok, _} =
               ExecuteXochiIntent.run(base_params(%{amount: "0.50"}), ctx)

      assert_received :wallet_signed

      assert {:ok, _} =
               ExecuteXochiIntent.run(base_params(%{amount: "0.40"}), ctx)

      assert_received :wallet_signed
    end

    test "resumes via a ContextStore-backed checkpoint (the deployed-agent store)" do
      # Same resume, but through the store a real agent uses: the in-flight intent
      # rides the agent's durable context, not a throwaway ETS table.
      Raxol.Agent.ContextStore.init()
      store_id = :xochi_intent_recovery_test
      on_exit(fn -> Raxol.Agent.ContextStore.delete(store_id) end)
      store = Checkpoint.ContextStore.new(store_id)

      Checkpoint.put(store, "pay-1", %{intent_id: "int_1", status: :dispatched})

      ledger = start_supervised!({Ledger, [name: nil]})

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:ok, result} = ExecuteXochiIntent.run(base_params(%{}), ctx)
      assert result.intent_id == "int_1"
      assert result.status == "dispatched"
      refute_received :wallet_signed

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
    end

    test "drops the checkpoint when execution fails so a retry starts clean" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            Req.Test.json(conn, %{
              "intentId" => "int_1",
              "quoteId" => "q_1",
              "canSolve" => true,
              "toAmount" => "499000",
              "xochiFee" => "1000",
              "eip712Data" => %{
                "domain" => %{
                  "name" => "Xochi",
                  "version" => "1",
                  "chainId" => 8453
                },
                "types" => %{
                  "Intent" => [%{"name" => "amount", "type" => "uint256"}]
                },
                "message" => %{"amount" => 500_000}
              }
            })

          "/api/intent/execute" ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              500,
              Jason.encode!(%{"error" => "server_error"})
            )
        end
      end)

      ledger = start_supervised!({Ledger, [name: nil]})
      store = Checkpoint.ETS.new()

      ctx = %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: ledger,
        policy: policy(),
        agent_id: "a1",
        checkpoint: store,
        idempotency_key: "pay-1"
      }

      assert {:error, %Failure{}} =
               ExecuteXochiIntent.run(base_params(%{}), ctx)

      assert :error = Checkpoint.fetch(store, "pay-1")

      totals = Ledger.get_totals(ledger, "a1", policy())
      assert Decimal.equal?(totals.lifetime, Decimal.new("0"))
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

    # Mirrors riddler-client test-xochi.js "shielded status RESULT_JSON carries
    # note_commitment + l2_tx_hash". A shielded (Aztec) settlement is note-based:
    # at terminal status it announces a note commitment / nullifier / L2 tx in
    # place of a stealth address, and an agent polling must be able to read them.
    test "surfaces shielded note fields at terminal status" do
      note = "0x" <> String.duplicate("ab", 32)
      nullifier = "0x" <> String.duplicate("cd", 32)
      l2_tx = "0x" <> String.duplicate("ef", 32)

      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intentId" => "int_sh",
          "status" => "completed",
          "settlementType" => "shielded",
          "noteCommitment" => note,
          "nullifierHash" => nullifier,
          "l2TxHash" => l2_tx,
          "terminal" => true
        })
      end)

      # call/2 (not run/2) so the new note fields pass the output schema.
      assert {:ok, result} =
               PollXochiStatus.call(%{intent_id: "int_sh"}, %{xochi_config: config()})

      assert result.settlement_type == "shielded"
      assert result.note_commitment == note
      assert result.nullifier_hash == nullifier
      assert result.l2_tx_hash == l2_tx
    end

    test "surfaces solver substatus / substatus_message on a completed status" do
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intentId" => "int_1",
          "status" => "completed",
          "substatus" => "settled",
          "substatus_message" => "filled from solver inventory",
          "terminal" => true
        })
      end)

      assert {:ok, result} =
               PollXochiStatus.call(%{intent_id: "int_1"}, %{xochi_config: config()})

      assert result.substatus == "settled"
      assert result.substatus_message == "filled from solver inventory"
    end

    test "carries substatus_message into the error when a failed status has no explicit error" do
      # An in-doubt settlement the reconcile sweep ultimately couldn't confirm
      # ends `failed` with the reason in substatus_message rather than `error`.
      # That reason must reach the caller, not be dropped.
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intentId" => "int_4",
          "status" => "failed",
          "substatus_message" => "reconcile: solver did not confirm execution",
          "terminal" => true
        })
      end)

      assert {:error, %Failure{reason: :not_filled} = failure} =
               PollXochiStatus.run(%{intent_id: "int_4"}, %{xochi_config: config()})

      assert failure.message =~ "reconcile: solver did not confirm execution"
    end
  end

  # The Action behaviour's `call/2` validates the output against the output
  # schema; `run/2` does not. The live Xochi gate goes through `call/2`, so these
  # exercise the same path. Regression guard for both settlement modes: a public
  # settlement has no stealth address (`stealth_address: nil`) and an unsettled
  # poll has no tx hash (`tx_hash: nil`); neither nil may trip its own optional
  # output field. The gate failed with `[stealth_address: "must be of type
  # :string"]` because the public summary carried a nil stealth address.
  describe "output schema via call/2 (public and stealth settlements)" do
    defp call_ctx do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      }
    end

    defp stub_quote(execute_json) do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            Req.Test.json(conn, %{
              "intentId" => "int_1",
              "quoteId" => "q_1",
              "canSolve" => true,
              "toAmount" => "499000",
              "xochiFee" => "1000",
              "eip712Data" => %{
                "domain" => %{
                  "name" => "Xochi",
                  "version" => "1",
                  "chainId" => 8453
                },
                "types" => %{
                  "Intent" => [%{"name" => "amount", "type" => "uint256"}]
                },
                "message" => %{"amount" => 500_000}
              }
            })

          "/api/intent/execute" ->
            Req.Test.json(conn, execute_json)
        end
      end)
    end

    test "a public cross-chain settlement passes output validation with a nil stealth address" do
      # No stealthAddress in the execute response -> exec.stealth_address is nil,
      # exactly the public path the live gate runs.
      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing"
      })

      params =
        base_params(%{settlement: "public", recipient_meta_address: nil})

      assert {:ok, result} = ExecuteXochiIntent.call(params, call_ctx())
      assert result.intent_id == "int_1"
      assert result.status == "executing"
      assert is_nil(result.stealth_address)
      assert_received :wallet_signed
    end

    test "a stealth settlement passes output validation with a real stealth address" do
      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing",
        "stealthAddress" => "0xstealth"
      })

      assert {:ok, result} =
               ExecuteXochiIntent.call(base_params(%{}), call_ctx())

      assert result.intent_id == "int_1"
      assert result.stealth_address == "0xstealth"
      assert_received :wallet_signed
    end

    test "a stealth settlement that returns no stealth address fails closed" do
      # The worker accepted a stealth request but returned no stealth address, so
      # the funds may not be private. Reporting {:ok} here would silently defeat
      # the privacy the caller asked for; the Action must surface an error.
      stub_quote(%{"success" => true, "intentId" => "int_1", "status" => "executing"})

      assert {:error, %Failure{reason: :stealth_address_missing, retryable?: false}} =
               ExecuteXochiIntent.call(base_params(%{}), call_ctx())
    end

    test "a shielded settlement succeeds without a stealth address (note-based)" do
      # Shielded (Aztec) settlements are note-based: they carry no stealth address
      # (note_commitment / nullifier_hash surface at terminal status), so the
      # stealth-address guard must not apply to them.
      stub_quote(%{"success" => true, "intentId" => "int_1", "status" => "executing"})

      params = base_params(%{settlement: "shielded", recipient_meta_address: nil})

      assert {:ok, result} = ExecuteXochiIntent.call(params, call_ctx())
      assert result.intent_id == "int_1"
      assert is_nil(result.stealth_address)
    end

    test "a clean execute reports reconciling: false" do
      stub_quote(%{
        "success" => true,
        "intentId" => "int_1",
        "status" => "executing",
        "stealthAddress" => "0xstealth"
      })

      assert {:ok, result} = ExecuteXochiIntent.call(base_params(%{}), call_ctx())
      assert result.reconciling == false
    end

    test "an in-doubt (reconciling) execute surfaces reconciling, not a clean success" do
      # The worker could not confirm the solver executed (a Riddler 5xx/timeout
      # wrapped as a 200) and kept the intent non-terminal: success=true,
      # status=executing, reconciling=true, no tx hash. raxol must surface the
      # in-doubt state, not report a settled payment.
      stub_quote(%{
        "success" => true,
        "intent_id" => "int_1",
        "status" => "executing",
        "reconciling" => true
      })

      params = base_params(%{settlement: "public", recipient_meta_address: nil})

      assert {:ok, result} = ExecuteXochiIntent.call(params, call_ctx())
      assert result.status == "executing"
      assert result.reconciling == true
    end

    test "an in-doubt stealth execute is not misreported as a missing stealth address" do
      # A reconciling stealth execute has no stealth address yet (it appears once
      # the intent resolves to completed via polling). That is the in-doubt state,
      # not a privacy downgrade, so the stealth-address guard must not fail closed
      # here -- the in-doubt is surfaced via `reconciling` instead.
      stub_quote(%{
        "success" => true,
        "intent_id" => "int_1",
        "status" => "executing",
        "reconciling" => true
      })

      assert {:ok, result} = ExecuteXochiIntent.call(base_params(%{}), call_ctx())
      assert result.reconciling == true
      assert is_nil(result.stealth_address)
    end

    test "an explicit nil slippage falls back to the 50 bps default, never null" do
      # A present nil must not defeat the documented default and reach the worker
      # as null (an unbounded-slippage downgrade).
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
        end
      end)

      assert {:ok, _} =
               ExecuteXochiIntent.call(base_params(%{slippage_bps: nil}), call_ctx())

      assert_received {:quote_body, body}
      assert body["slippage_bps"] == 50
    end

    test "a completed poll with no tx hash passes output validation" do
      # A terminal-completed status that reports neither txHash nor settlementType:
      # both optional output fields are nil and must not trip validation.
      Req.Test.stub(__MODULE__, fn conn ->
        Req.Test.json(conn, %{
          "intentId" => "int_1",
          "status" => "completed",
          "terminal" => true
        })
      end)

      assert {:ok, result} =
               PollXochiStatus.call(%{intent_id: "int_1"}, %{
                 xochi_config: config()
               })

      assert result.status == "completed"
      assert result.terminal == true
      assert is_nil(result.tx_hash)
      assert is_nil(result.settlement_type)
      # A public/stealth settlement carries no note fields; present-nil must pass.
      assert is_nil(result.note_commitment)
      assert is_nil(result.nullifier_hash)
      assert is_nil(result.l2_tx_hash)
    end
  end

  # A hostile or compromised quote endpoint can serve a punitive toAmount
  # (deliver ~0 while pulling the full origin amount); the spend gate sees only
  # the human amount leaving the wallet, not what arrives. The Action floors the
  # delivery before signing: an explicit min_to_amount for any corridor, plus an
  # automatic 80%-of-par floor for same-asset corridors.
  describe "ExecuteXochiIntent delivery floor" do
    @usdc_arb "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
    @weth_arb "0x82af49447d8a07e3bd95bd0d56f35241523fbab1"

    defp floor_ctx do
      %{
        wallet: SpyWallet,
        xochi_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      }
    end

    # Base USDC -> Arbitrum USDC: a same-asset corridor, so the automatic floor
    # applies. toAmount is configurable to model a punitive quote.
    defp stub_floor_quote(to_amount) do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.request_path do
          "/api/intent/quote" ->
            Req.Test.json(conn, %{
              "intentId" => "int_1",
              "quoteId" => "q_1",
              "canSolve" => true,
              "toAmount" => to_amount,
              "xochiFee" => "1000",
              "eip712Data" => %{
                "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
                "types" => %{"Intent" => [%{"name" => "amount", "type" => "uint256"}]},
                "message" => %{"amount" => 1_000_000}
              }
            })

          "/api/intent/execute" ->
            Req.Test.json(conn, %{
              "success" => true,
              "intentId" => "int_1",
              "status" => "executing"
            })
        end
      end)
    end

    defp floor_params(overrides \\ %{}) do
      Map.merge(
        %{
          amount: "1.00",
          from_chain_id: 8453,
          to_chain_id: 42_161,
          from_token: @usdc_base,
          to_token: @usdc_arb,
          settlement: "public"
        },
        overrides
      )
    end

    test "rejects a punitive quote that delivers below the 80% floor, before signing" do
      # 1.00 USDC sent -> par 1_000_000, floor 800_000. Delivering 0.10 USDC
      # (100_000) is a near-total skim and must be refused before signing.
      stub_floor_quote("100000")

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteXochiIntent.run(floor_params(), floor_ctx())

      refute_received :wallet_signed
    end

    test "allows a quote that delivers within the floor" do
      # 0.995 USDC delivered on a 1.00 send: a normal fee, well above the floor.
      stub_floor_quote("995000")

      assert {:ok, result} = ExecuteXochiIntent.run(floor_params(), floor_ctx())
      assert result.status == "executing"
      assert_received :wallet_signed
    end

    test "an unparseable toAmount on a same-asset corridor fails closed" do
      stub_floor_quote("not-a-number")

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteXochiIntent.run(floor_params(), floor_ctx())

      refute_received :wallet_signed
    end

    test "an explicit min_to_amount is enforced and rejects a quote below it" do
      # 0.90 USDC clears the auto floor (>= 0.80) but is below the caller's
      # explicit 0.95 minimum.
      stub_floor_quote("900000")

      assert {:error, %Failure{reason: :delivery_below_floor}} =
               ExecuteXochiIntent.run(floor_params(%{min_to_amount: "950000"}), floor_ctx())

      refute_received :wallet_signed
    end

    test "an explicit min_to_amount allows a quote at or above it" do
      stub_floor_quote("960000")

      assert {:ok, _} =
               ExecuteXochiIntent.run(floor_params(%{min_to_amount: "950000"}), floor_ctx())

      assert_received :wallet_signed
    end

    test "a cross-asset corridor with no min_to_amount skips the auto floor" do
      # USDC -> WETH is not a same-asset corridor and has no on-client price, so
      # the auto floor does not apply; a tiny toAmount is trusted unless
      # min_to_amount is given. (It would be rejected if a floor applied.)
      stub_floor_quote("1")

      assert {:ok, _} =
               ExecuteXochiIntent.run(floor_params(%{to_token: @weth_arb}), floor_ctx())

      assert_received :wallet_signed
    end
  end
end
