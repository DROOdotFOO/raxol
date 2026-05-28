defmodule Raxol.ACP.Wallet.SCA.PaymasterTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Wallet.SCA.{ModularAccount, Paymaster, UserOp}

  @policy_id "186aaa4a-5f57-4156-83fb-e456365a8820"
  @entry_point "0x0000000071727De22E5E9d8BAf0edAc6f37da032"
  @account "0x9a96e767bfcce8e80370be00821ed5ba283d4a17"

  # A real Plug that asserts the request shape and returns a canned
  # alchemy_requestGasAndPaymasterAndData result. Run in-process by
  # Req's :plug adapter -- a second real impl of the wire contract.
  defp gas_manager_plug(result, test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      send(test_pid, {:gm_request, decoded})

      payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => decoded["id"], "result" => result})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, payload)
    end
  end

  @canned_result %{
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

  describe "sponsor/5" do
    test "calls alchemy_requestGasAndPaymasterAndData with policy, entrypoint, userOp, dummy sig" do
      op = %UserOp{sender: @account, nonce: 0, call_data: <<0x12, 0x34>>}
      req = Req.new(plug: gas_manager_plug(@canned_result, self()))

      assert {:ok, _sponsored} =
               Paymaster.sponsor("http://alchemy.test", @policy_id, @entry_point, op, req: req)

      assert_received {:gm_request,
                       %{
                         "method" => "alchemy_requestGasAndPaymasterAndData",
                         "params" => [params]
                       }}

      assert params["policyId"] == @policy_id
      assert params["entryPoint"] == @entry_point
      assert params["userOperation"]["sender"] == @account
      assert params["userOperation"]["callData"] == "0x1234"

      # The dummy signature is the packed MA-v2 dummy.
      expected_dummy = "0x" <> Base.encode16(ModularAccount.dummy_uo_signature(), case: :lower)
      assert params["dummySignature"] == expected_dummy

      # Gas fields are NOT sent -- the manager fills them.
      refute Map.has_key?(params["userOperation"], "callGasLimit")
      refute Map.has_key?(params["userOperation"], "maxFeePerGas")
    end

    test "folds the response gas + paymaster fields into the UserOp" do
      op = %UserOp{sender: @account, nonce: 0, call_data: <<0x12, 0x34>>}
      req = Req.new(plug: gas_manager_plug(@canned_result, self()))

      assert {:ok, sponsored} =
               Paymaster.sponsor("http://alchemy.test", @policy_id, @entry_point, op, req: req)

      assert sponsored.paymaster == "0xabababababababababababababababababababab"
      assert sponsored.paymaster_data == <<0xCA, 0xFE>>
      assert sponsored.paymaster_verification_gas_limit == 30_000
      assert sponsored.paymaster_post_op_gas_limit == 10_000
      assert sponsored.call_gas_limit == 50_000
      assert sponsored.verification_gas_limit == 100_000
      assert sponsored.pre_verification_gas == 21_000
      assert sponsored.max_fee_per_gas == 1_000_000_000
      assert sponsored.max_priority_fee_per_gas == 1_000_000_000

      # Identity fields are preserved.
      assert sponsored.sender == @account
      assert sponsored.call_data == <<0x12, 0x34>>
    end

    test "passes overrides through when provided" do
      op = %UserOp{sender: @account}
      req = Req.new(plug: gas_manager_plug(@canned_result, self()))

      Paymaster.sponsor("http://alchemy.test", @policy_id, @entry_point, op,
        req: req,
        overrides: %{"maxFeePerGas" => %{"multiplier" => 1.5}}
      )

      assert_received {:gm_request, %{"params" => [params]}}
      assert params["overrides"] == %{"maxFeePerGas" => %{"multiplier" => 1.5}}
    end

    test "surfaces a gas manager rejection as an rpc_error" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"id" => id} = Jason.decode!(body)

        payload =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{"code" => -32_500, "message" => "policy denied"}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, payload)
      end

      op = %UserOp{sender: @account}

      assert {:error, {:rpc_error, -32_500, "policy denied"}} =
               Paymaster.sponsor("http://alchemy.test", @policy_id, @entry_point, op,
                 req: Req.new(plug: plug)
               )
    end
  end
end
