defmodule Raxol.ACP.ContractClient.OnchainSCATest do
  @moduledoc """
  Verifies that `Raxol.ACP.ContractClient.Onchain` routes through the
  ERC-4337 UserOperation path when the configured `:onchain_wallet` is
  a `Raxol.ACP.Wallet.SCA` (rather than an EOA).

  A single in-process Plug stub serves every leg -- the node
  `eth_call` (getNonce), the Alchemy gas manager, the bundler submit,
  and the bundler receipt -- so the whole gasless pipeline runs without
  a real endpoint.
  """
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient.Onchain

  @session_env "RAXOL_ACP_ONCHAIN_SCA_KEY"
  @session_privkey "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
  @contract "0x" <> String.duplicate("11", 20)
  @sca_account "0x9a96e767bfcce8e80370be00821ed5ba283d4a17"
  @tx_hash "0x" <> String.duplicate("ab", 32)

  defmodule SessionKey do
    use Raxol.Payments.Wallets.Env, env_var: "RAXOL_ACP_ONCHAIN_SCA_KEY", chain_id: 8453
  end

  defmodule SCAWallet do
    use Raxol.ACP.Wallet.SCA,
      account_address: "0x9a96e767bfcce8e80370be00821ed5ba283d4a17",
      chain_id: 8453,
      signer: Raxol.ACP.ContractClient.OnchainSCATest.SessionKey,
      signer_entity_id: 1,
      bundler_url: "http://stub.invalid/bundler",
      paymaster_policy_id: "186aaa4a-5f57-4156-83fb-e456365a8820"
  end

  @gm_result %{
    "paymaster" => "0xabababababababababababababababababababab",
    "paymasterData" => "0xcafe",
    "paymasterVerificationGasLimit" => "0x7530",
    "paymasterPostOpGasLimit" => "0x2710",
    "callGasLimit" => "0xc350",
    "verificationGasLimit" => "0x186a0",
    "preVerificationGas" => "0x5208",
    "maxFeePerGas" => "0x3b9aca00",
    "maxPriorityFeePerGas" => "0x3b9aca00"
  }

  setup do
    System.put_env(@session_env, @session_privkey)

    Application.put_env(:raxol_acp, :chain_overrides, %{
      mainnet: %{acp_contract_address: @contract}
    })

    Application.put_env(:raxol_acp, :chain, :mainnet)
    Application.put_env(:raxol_acp, :onchain_wallet, SCAWallet)

    on_exit(fn ->
      System.delete_env(@session_env)
      Application.delete_env(:raxol_acp, :chain_overrides)
      Application.delete_env(:raxol_acp, :chain)
      Application.delete_env(:raxol_acp, :onchain_wallet)
      Application.delete_env(:raxol_acp, :rpc)
      Application.delete_env(:raxol_acp, :sca_rpc)
    end)

    :ok
  end

  # One plug for the node RPC + bundler + paymaster, keyed on method.
  # `:deployed` controls what eth_getCode reports for the SCA.
  defp install_stub(events, opts \\ []) do
    deployed = Keyword.get(opts, :deployed, true)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)
      send(events, {:rpc_call, req["method"], req["params"]})

      result =
        case req["method"] do
          # EntryPoint.getNonce -> uint256 (key 0x101 in high bits, seq 0)
          "eth_call" ->
            "0x" <> (0x101 |> Integer.to_string(16) |> String.pad_leading(64, "0"))

          "eth_getCode" ->
            if deployed, do: "0x60806040", else: "0x"

          "alchemy_requestGasAndPaymasterAndData" ->
            @gm_result

          "eth_sendUserOperation" ->
            "0x" <> String.duplicate("cd", 32)

          "eth_getUserOperationReceipt" ->
            %{
              "userOpHash" => Enum.at(req["params"], 0),
              "success" => true,
              "logs" => [],
              "receipt" => %{
                "transactionHash" => @tx_hash,
                "status" => "0x1",
                "blockNumber" => "0x100",
                "logs" => []
              }
            }

          _ ->
            nil
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
      )
    end

    # Node RPC (eth_call) reads its plug from :rpc; the wallet's
    # bundler/paymaster calls take :sca_rpc as their Req.
    Application.put_env(:raxol_acp, :rpc, url: "http://stub.invalid/rpc", plug: plug)
    Application.put_env(:raxol_acp, :sca_rpc, plug: plug, url: "http://stub.invalid/bundler")
  end

  describe "SCA routing" do
    test "create_memo wraps the call in execute() and runs the gasless UserOp pipeline" do
      events = self()
      install_stub(events)

      assert {:ok, @tx_hash} =
               Onchain.create_memo("42", "hello", :message, false, :negotiation)

      # getNonce was queried against the EntryPoint.
      assert_received {:rpc_call, "eth_call",
                       [%{"to" => entry_point, "data" => nonce_call}, _block]}

      assert entry_point == SCAWallet.entry_point()
      assert String.starts_with?(nonce_call, "0x")

      # The gas manager sponsored the op.
      assert_received {:rpc_call, "alchemy_requestGasAndPaymasterAndData", [params]}
      assert params["policyId"] == "186aaa4a-5f57-4156-83fb-e456365a8820"
      assert params["userOperation"]["sender"] == @sca_account

      # The bundler received a UserOp whose callData is execute(...).
      assert_received {:rpc_call, "eth_sendUserOperation", [user_op, _ep]}
      assert user_op["sender"] == @sca_account
      assert execute_wrapped?(user_op["callData"])
      assert String.starts_with?(user_op["signature"], "0xff00")

      # Account already deployed -> no factory/initCode on the UserOp.
      refute Map.has_key?(user_op, "factory")

      # And we polled for the UserOp receipt.
      assert_received {:rpc_call, "eth_getUserOperationReceipt", _}
    end

    test "attaches factory initCode when the account is not yet deployed" do
      events = self()
      install_stub(events, deployed: false)

      assert {:ok, @tx_hash} =
               Onchain.create_memo("42", "hello", :message, false, :negotiation)

      assert_received {:rpc_call, "eth_getCode", _}
      assert_received {:rpc_call, "eth_sendUserOperation", [user_op, _ep]}

      # v0.7 splits initCode into factory + factoryData; the factory is
      # the MAv2 factory and factoryData is createSemiModularAccount(...).
      assert user_op["factory"] ==
               String.downcase(Raxol.ACP.Wallet.SCA.ModularAccount.factory_address())

      assert String.starts_with?(user_op["factoryData"], "0x")
    end

    test "create_job routes through SCA and returns the inner tx hash" do
      events = self()
      install_stub(events)

      assert {:ok, @tx_hash} = Onchain.create_job(@sca_account, @sca_account, 9_999_999_999)

      assert_received {:rpc_call, "eth_sendUserOperation", [user_op, _ep]}
      assert execute_wrapped?(user_op["callData"])
    end

    test "emits :user_op_sent and :tx_mined telemetry" do
      install_stub(self())
      test_pid = self()
      handler_id = "onchain-sca-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:raxol, :acp, :onchain, :user_op_sent],
          [:raxol, :acp, :onchain, :tx_mined]
        ],
        fn event, _m, meta, _ -> send(test_pid, {:telemetry, event, meta}) end,
        nil
      )

      try do
        assert {:ok, _} = Onchain.create_memo("42", "hi", :message, false, :negotiation)

        assert_receive {:telemetry, [:raxol, :acp, :onchain, :user_op_sent],
                        %{method: :create_memo, tx_hash: @tx_hash}},
                       500

        assert_receive {:telemetry, [:raxol, :acp, :onchain, :tx_mined],
                        %{method: :create_memo, status: :success}},
                       500
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  # callData should be execute(address,uint256,bytes) wrapping the ACP call.
  defp execute_wrapped?("0x" <> hex) do
    selector = binary_part(Base.decode16!(hex, case: :mixed), 0, 4)
    expected = binary_part(ExKeccak.hash_256("execute(address,uint256,bytes)"), 0, 4)
    selector == expected
  end
end
