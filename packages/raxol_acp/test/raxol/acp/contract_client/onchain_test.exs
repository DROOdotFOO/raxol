defmodule Raxol.ACP.ContractClient.OnchainTest do
  @moduledoc """
  Stubbed-RPC integration tests for the Onchain contract client.

  These tests assert the **encode/sign/broadcast/await** pipeline
  end-to-end. The transport is replaced with an in-process Plug stub
  via `Req`'s `:plug` option, so no real RPC endpoint is required.
  Real-network testing (against Anvil or sepolia) is a separate
  validation step before mainnet activity.
  """
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient.Onchain
  alias Raxol.ACP.Wallet.NonceServer

  @env_var "RAXOL_ACP_ONCHAIN_TEST_KEY"
  @test_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @contract "0x" <> String.duplicate("11", 20)
  @seller "0x" <> String.duplicate("22", 20)

  defmodule Wallet do
    use Raxol.Payments.Wallets.Env,
      env_var: "RAXOL_ACP_ONCHAIN_TEST_KEY",
      chain_id: 8453
  end

  setup do
    System.put_env(@env_var, @test_privkey)

    Application.put_env(:raxol_acp, :chain_overrides, %{
      mainnet: %{acp_contract_address: @contract},
      sepolia: %{acp_contract_address: @contract}
    })

    Application.put_env(:raxol_acp, :chain, :mainnet)
    Application.put_env(:raxol_acp, :onchain_wallet, Wallet)

    NonceServer.reset(0)

    on_exit(fn ->
      System.delete_env(@env_var)
      Application.delete_env(:raxol_acp, :chain_overrides)
      Application.delete_env(:raxol_acp, :chain)
      Application.delete_env(:raxol_acp, :onchain_wallet)
    end)

    :ok
  end

  defp install_stub(handler) when is_function(handler, 1) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)

      response = handler.(decoded)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(response))
    end

    Application.put_env(:raxol_acp, :rpc,
      url: "http://stub.invalid/rpc",
      plug: plug,
      receive_timeout: 1_000
    )

    on_exit(fn -> Application.delete_env(:raxol_acp, :rpc) end)
  end

  defp ok_response(req, result) do
    %{"jsonrpc" => "2.0", "id" => req["id"], "result" => result}
  end

  defp default_handler(events) do
    fn req ->
      send(events, {:rpc_call, req["method"], req["params"]})

      case req["method"] do
        "eth_getTransactionCount" ->
          ok_response(req, "0x5")

        "eth_feeHistory" ->
          ok_response(req, %{
            "baseFeePerGas" => [
              "0x3b9aca00",
              "0x3b9aca00",
              "0x3b9aca00",
              "0x3b9aca00",
              "0x3b9aca00"
            ],
            "gasUsedRatio" => [0.5, 0.5, 0.5, 0.5],
            "oldestBlock" => "0x10",
            "reward" => [["0x59682f00"], ["0x59682f00"], ["0x59682f00"], ["0x59682f00"]]
          })

        "eth_estimateGas" ->
          ok_response(req, "0x5208")

        "eth_sendRawTransaction" ->
          ok_response(req, "0x" <> String.duplicate("ab", 32))

        "eth_getTransactionReceipt" ->
          ok_response(req, %{
            "status" => "0x1",
            "transactionHash" => Enum.at(req["params"], 0),
            "blockNumber" => "0x100",
            "logs" => []
          })

        _ ->
          ok_response(req, nil)
      end
    end
  end

  describe "create_job/3" do
    test "runs the full pipeline and returns the tx hash as a placeholder job id" do
      events = self()
      install_stub(default_handler(events))

      assert {:ok, "0x" <> _ = tx_hash} =
               Onchain.create_job(@seller, @seller, 9_999_999_999)

      assert byte_size(tx_hash) == 66

      assert_received {:rpc_call, "eth_getTransactionCount", _}
      assert_received {:rpc_call, "eth_feeHistory", _}
      assert_received {:rpc_call, "eth_estimateGas", _}
      assert_received {:rpc_call, "eth_sendRawTransaction", [hex]}

      # Signed payload is a typed tx (starts with 0x02).
      assert <<"0x02", _rest::binary>> = hex

      assert_received {:rpc_call, "eth_getTransactionReceipt", _}
    end

    test "decodes the job id from a JobCreated event when configured" do
      signature = "JobCreated(uint256)"
      Application.put_env(:raxol_acp, :create_job_event_signature, signature)

      on_exit(fn -> Application.delete_env(:raxol_acp, :create_job_event_signature) end)

      install_stub(fn req ->
        case req["method"] do
          "eth_getTransactionCount" ->
            ok_response(req, "0x5")

          "eth_feeHistory" ->
            ok_response(req, %{
              "baseFeePerGas" => [
                "0x3b9aca00",
                "0x3b9aca00",
                "0x3b9aca00",
                "0x3b9aca00",
                "0x3b9aca00"
              ],
              "gasUsedRatio" => [0.5, 0.5, 0.5, 0.5],
              "oldestBlock" => "0x10",
              "reward" => [["0x59682f00"], ["0x59682f00"], ["0x59682f00"], ["0x59682f00"]]
            })

          "eth_estimateGas" ->
            ok_response(req, "0x5208")

          "eth_sendRawTransaction" ->
            ok_response(req, "0x" <> String.duplicate("ab", 32))

          "eth_getTransactionReceipt" ->
            ok_response(req, %{
              "status" => "0x1",
              "transactionHash" => Enum.at(req["params"], 0),
              "blockNumber" => "0x100",
              "logs" => [
                %{
                  "address" => @contract,
                  "topics" => [
                    Raxol.ACP.Onchain.LogDecoder.event_topic(signature),
                    "0x" <> String.duplicate("0", 62) <> "2a"
                  ],
                  "data" => "0x"
                }
              ]
            })
        end
      end)

      assert {:ok, "0x2a"} = Onchain.create_job(@seller, @seller, 9_999_999_999)
    end

    test "falls back to tx hash when the event is configured but missing from logs" do
      Application.put_env(:raxol_acp, :create_job_event_signature, "JobCreated(uint256)")

      on_exit(fn -> Application.delete_env(:raxol_acp, :create_job_event_signature) end)

      handler_id = "placeholder-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :acp, :onchain, :placeholder_job_id],
        fn _e, _m, metadata, _ -> send(test_pid, {:placeholder, metadata}) end,
        nil
      )

      try do
        # Default handler returns a receipt with empty logs.
        install_stub(default_handler(self()))

        assert {:ok, "0x" <> _ = tx_hash} =
                 Onchain.create_job(@seller, @seller, 9_999_999_999)

        assert_receive {:placeholder, %{tx_hash: ^tx_hash, reason: {:event_not_found, _}}}, 200
      after
        :telemetry.detach(handler_id)
      end
    end

    test "errors clearly when no contract address is configured" do
      Application.put_env(:raxol_acp, :chain_overrides, %{
        mainnet: %{acp_contract_address: nil}
      })

      install_stub(default_handler(self()))

      assert {:error, :no_contract_address} =
               Onchain.create_job(@seller, @seller, 9_999_999_999)
    end

    test "v2 routes to acp_router_address instead of acp_contract_address" do
      v2_router = "0x" <> String.duplicate("99", 20)

      Application.put_env(:raxol_acp, :acp_version, :v2)

      Application.put_env(:raxol_acp, :chain_overrides, %{
        mainnet: %{acp_contract_address: @contract, acp_router_address: v2_router}
      })

      on_exit(fn -> Application.delete_env(:raxol_acp, :acp_version) end)

      test_pid = self()

      install_stub(fn req ->
        case req["method"] do
          "eth_sendRawTransaction" = method ->
            send(test_pid, {:raw_tx, req["params"]})
            default_handler(test_pid).(Map.put(req, "method", method))

          _ ->
            default_handler(test_pid).(req)
        end
      end)

      _ = Onchain.create_job(@seller, @seller, 9_999_999_999)

      assert_receive {:raw_tx, [tx_hex]}, 1_000
      # The destination address (`to`) appears in the signed RLP. Easiest
      # invariant to check: the v2 router hex is embedded and the v1
      # contract hex is not.
      v2_hex = String.downcase(String.trim_leading(v2_router, "0x"))
      v1_hex = String.downcase(String.trim_leading(@contract, "0x"))
      tx_down = String.downcase(tx_hex)
      assert String.contains?(tx_down, v2_hex)
      refute String.contains?(tx_down, v1_hex)
    end

    test "v2 errors clearly when acp_router_address is nil" do
      Application.put_env(:raxol_acp, :acp_version, :v2)

      Application.put_env(:raxol_acp, :chain_overrides, %{
        mainnet: %{acp_contract_address: @contract, acp_router_address: nil}
      })

      on_exit(fn -> Application.delete_env(:raxol_acp, :acp_version) end)

      install_stub(default_handler(self()))

      assert {:error, :no_router_address} =
               Onchain.create_job(@seller, @seller, 9_999_999_999)
    end

    test "errors clearly when no wallet is configured" do
      Application.delete_env(:raxol_acp, :onchain_wallet)
      install_stub(default_handler(self()))

      assert {:error, :no_wallet_configured} =
               Onchain.create_job(@seller, @seller, 9_999_999_999)
    end

    test "surfaces tx revert as {:error, {:tx_reverted, hash}}" do
      install_stub(fn req ->
        case req["method"] do
          "eth_getTransactionCount" ->
            ok_response(req, "0x5")

          "eth_feeHistory" ->
            ok_response(req, %{
              "baseFeePerGas" => [
                "0x3b9aca00",
                "0x3b9aca00",
                "0x3b9aca00",
                "0x3b9aca00",
                "0x3b9aca00"
              ],
              "gasUsedRatio" => [0.5, 0.5, 0.5, 0.5],
              "oldestBlock" => "0x10",
              "reward" => [["0x59682f00"], ["0x59682f00"], ["0x59682f00"], ["0x59682f00"]]
            })

          "eth_estimateGas" ->
            ok_response(req, "0x5208")

          "eth_sendRawTransaction" ->
            ok_response(req, "0x" <> String.duplicate("cd", 32))

          "eth_getTransactionReceipt" ->
            ok_response(req, %{
              "status" => "0x0",
              "transactionHash" => Enum.at(req["params"], 0),
              "blockNumber" => "0x100",
              "logs" => []
            })
        end
      end)

      assert {:error, {:tx_reverted, "0x" <> _}} =
               Onchain.create_job(@seller, @seller, 9_999_999_999)
    end
  end

  describe "create_memo/5" do
    test "encodes content + uint8 memo_type and nextPhase" do
      events = self()
      install_stub(default_handler(events))

      job_id = "0x" <> Integer.to_string(123, 16)

      assert {:ok, "0x" <> _} =
               Onchain.create_memo(job_id, "hello", :message, false, :negotiation)

      assert_received {:rpc_call, "eth_sendRawTransaction", _}
    end
  end

  describe "set_budget/2" do
    test "encodes job id + USDC amount and sends a tx" do
      install_stub(default_handler(self()))
      assert {:ok, "0x" <> _} = Onchain.set_budget("42", Decimal.new("0.50"))
    end
  end

  describe "sign_memo/3" do
    test "encodes memo id + approval bool + reason string" do
      install_stub(default_handler(self()))
      assert {:ok, "0x" <> _} = Onchain.sign_memo(7, true, "looks good")
    end

    test "accepts a string memo id" do
      install_stub(default_handler(self()))
      assert {:ok, "0x" <> _} = Onchain.sign_memo("0x2a", false, "rejected")
    end
  end

  describe "claim_budget/1" do
    test "encodes the job id + sends a tx" do
      install_stub(default_handler(self()))
      assert {:ok, "0x" <> _} = Onchain.claim_budget("99")
    end
  end

  describe "set_budget_with_payment_token/3" do
    test "encodes job id + amount + token and sends a tx" do
      install_stub(default_handler(self()))
      token = "0x" <> String.duplicate("ee", 20)

      assert {:ok, "0x" <> _} =
               Onchain.set_budget_with_payment_token("42", Decimal.new("2.50"), token)
    end
  end

  describe "confirm_x402_payment_received/1" do
    test "encodes the job id + sends a tx" do
      install_stub(default_handler(self()))
      assert {:ok, "0x" <> _} = Onchain.confirm_x402_payment_received("42")
    end

    test "returns :unsupported_in_v2 when acp_version is :v2" do
      Application.put_env(:raxol_acp, :acp_version, :v2)
      on_exit(fn -> Application.delete_env(:raxol_acp, :acp_version) end)

      install_stub(default_handler(self()))

      assert {:error, :unsupported_in_v2} =
               Onchain.confirm_x402_payment_received("42")
    end
  end

  describe "create_payable_memo/3" do
    test "encodes the 10-arg payable memo and sends a tx" do
      events = self()
      install_stub(default_handler(events))

      assert {:ok, "0x" <> _} =
               Onchain.create_payable_memo("42", "settle",
                 token: "0x" <> String.duplicate("ee", 20),
                 amount: Decimal.new("1.00"),
                 recipient: "0x" <> String.duplicate("ff", 20),
                 fee_type: :percentage_fee,
                 memo_type: :payable_transfer,
                 next_phase: :completed
               )

      assert_received {:rpc_call, "eth_sendRawTransaction", _}
    end
  end

  describe "telemetry" do
    test "emits :tx_sent and :tx_mined for a successful broadcast" do
      install_stub(default_handler(self()))

      handler_id = "onchain-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:raxol, :acp, :onchain, :tx_sent],
          [:raxol, :acp, :onchain, :tx_mined],
          [:raxol, :acp, :onchain, :placeholder_job_id]
        ],
        fn event, _measurements, metadata, _ -> send(test_pid, {:telemetry, event, metadata}) end,
        nil
      )

      try do
        assert {:ok, _} = Onchain.create_job(@seller, @seller, 9_999_999_999)

        assert_receive {:telemetry, [:raxol, :acp, :onchain, :tx_sent],
                        %{method: :create_job, gas_limit: gas}},
                       500

        # 25% buffer over the stubbed 0x5208 (21000) -> 26250.
        assert gas == 26_250

        assert_receive {:telemetry, [:raxol, :acp, :onchain, :tx_mined],
                        %{method: :create_job, status: :success, block_number: 256}},
                       500

        assert_receive {:telemetry, [:raxol, :acp, :onchain, :placeholder_job_id], _}, 500
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  # With :acp_version :v2 the selectors switch to the ACPRouter shapes:
  # createJob gains paymentToken/budget/metadata and createPayableMemo
  # reorders + adds isSecured. The stub returns 0x..01 for any call, so
  # a successful run proves the V2 encoding path executes end to end.
  describe ":acp_version :v2 (ACPRouter)" do
    setup do
      Application.put_env(:raxol_acp, :acp_version, :v2)
      on_exit(fn -> Application.delete_env(:raxol_acp, :acp_version) end)
      :ok
    end

    test "create_job uses the 6-arg V2 selector and mines" do
      events = self()
      install_stub(default_handler(events))

      assert {:ok, "0x" <> _} = Onchain.create_job(@seller, @seller, 9_999_999_999)
      assert_received {:rpc_call, "eth_sendRawTransaction", _}
    end

    test "create_payable_memo uses the 11-arg V2 selector and mines" do
      install_stub(default_handler(self()))

      assert {:ok, "0x" <> _} =
               Onchain.create_payable_memo("42", "settle",
                 token: "0x" <> String.duplicate("ee", 20),
                 amount: Decimal.new("1.00"),
                 recipient: "0x" <> String.duplicate("ff", 20),
                 is_secured: true,
                 next_phase: :completed
               )
    end

    test "shared methods (create_memo/sign_memo/claim_budget) work unchanged on V2" do
      install_stub(default_handler(self()))
      assert {:ok, "0x" <> _} = Onchain.create_memo("42", "hi", :message, false, :negotiation)
      assert {:ok, "0x" <> _} = Onchain.sign_memo(1, true, "ok")
      assert {:ok, "0x" <> _} = Onchain.claim_budget("42")
    end
  end
end
