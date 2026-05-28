defmodule Raxol.ACP.Wallet.SCA.BundlerTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Wallet.SCA.{Bundler, UserOp}

  @entry_point "0x0000000071727De22E5E9d8BAf0edAc6f37da032"

  describe "encode_quantity/1 and decode_quantity/1" do
    test "zero is 0x0" do
      assert Bundler.encode_quantity(0) == "0x0"
      assert Bundler.decode_quantity("0x0") == 0
    end

    test "round-trips positive integers without leading zeros" do
      assert Bundler.encode_quantity(255) == "0xff"
      assert Bundler.encode_quantity(4096) == "0x1000"
      assert Bundler.decode_quantity("0xff") == 255
      assert Bundler.decode_quantity(Bundler.encode_quantity(123_456_789)) == 123_456_789
    end
  end

  describe "pack_for_rpc/1" do
    test "serializes a no-paymaster userop with hex quantities" do
      op = %UserOp{
        sender: "0x" <> String.duplicate("11", 20),
        nonce: 5,
        call_data: <<0xDE, 0xAD>>,
        call_gas_limit: 100_000,
        verification_gas_limit: 200_000,
        pre_verification_gas: 21_000,
        max_fee_per_gas: 2_000_000_000,
        max_priority_fee_per_gas: 1_000_000_000,
        signature: <<0xAA, 0xBB>>
      }

      rpc = Bundler.pack_for_rpc(op)

      assert rpc["sender"] == op.sender
      assert rpc["nonce"] == "0x5"
      assert rpc["callData"] == "0xdead"
      assert rpc["callGasLimit"] == Bundler.encode_quantity(100_000)
      assert rpc["verificationGasLimit"] == Bundler.encode_quantity(200_000)
      assert rpc["preVerificationGas"] == "0x5208"
      assert rpc["maxFeePerGas"] == Bundler.encode_quantity(2_000_000_000)
      assert rpc["maxPriorityFeePerGas"] == Bundler.encode_quantity(1_000_000_000)
      assert rpc["signature"] == "0xaabb"

      # No paymaster / factory fields when absent.
      refute Map.has_key?(rpc, "paymaster")
      refute Map.has_key?(rpc, "factory")
    end

    test "includes paymaster fields when a paymaster is set" do
      op = %UserOp{
        sender: "0x" <> String.duplicate("11", 20),
        paymaster: "0x" <> String.duplicate("ab", 20),
        paymaster_verification_gas_limit: 50_000,
        paymaster_post_op_gas_limit: 20_000,
        paymaster_data: <<0x01>>
      }

      rpc = Bundler.pack_for_rpc(op)

      assert rpc["paymaster"] == op.paymaster
      assert rpc["paymasterVerificationGasLimit"] == Bundler.encode_quantity(50_000)
      assert rpc["paymasterPostOpGasLimit"] == Bundler.encode_quantity(20_000)
      assert rpc["paymasterData"] == "0x01"
    end

    test "splits initCode into factory + factoryData (v0.7)" do
      factory = :binary.copy(<<0xCC>>, 20)
      factory_data = <<0x12, 0x34>>

      op = %UserOp{
        sender: "0x" <> String.duplicate("11", 20),
        init_code: factory <> factory_data
      }

      rpc = Bundler.pack_for_rpc(op)
      assert rpc["factory"] == "0x" <> String.duplicate("cc", 20)
      assert rpc["factoryData"] == "0x1234"
    end

    test "empty bytes serialize to 0x" do
      op = %UserOp{sender: "0x" <> String.duplicate("11", 20)}
      rpc = Bundler.pack_for_rpc(op)
      assert rpc["callData"] == "0x"
      assert rpc["signature"] == "0x"
    end
  end

  describe "RPC methods (in-process Plug)" do
    # A real Plug that decodes the JSON-RPC request and replies. This is
    # a second real impl of the bundler wire contract, run in-process by
    # Req's :plug adapter -- not a mock of our client.
    defp bundler_plug(responses) do
      fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"method" => method, "id" => id} = Jason.decode!(body)
        result = Map.fetch!(responses, method)

        payload = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, payload)
      end
    end

    defp req_with(responses) do
      Req.new(plug: bundler_plug(responses))
    end

    test "send_user_operation returns the userOpHash" do
      op = %UserOp{sender: "0x" <> String.duplicate("11", 20), signature: <<0xAA>>}
      req = req_with(%{"eth_sendUserOperation" => "0xabc123"})

      assert {:ok, "0xabc123"} =
               Bundler.send_user_operation("http://bundler.test", op, @entry_point, req: req)
    end

    test "estimate_user_operation_gas decodes the gas map to integers" do
      op = %UserOp{sender: "0x" <> String.duplicate("11", 20)}

      req =
        req_with(%{
          "eth_estimateUserOperationGas" => %{
            "preVerificationGas" => "0x5208",
            "verificationGasLimit" => "0x186a0",
            "callGasLimit" => "0xc350"
          }
        })

      assert {:ok, gas} =
               Bundler.estimate_user_operation_gas("http://bundler.test", op, @entry_point,
                 req: req
               )

      assert gas.pre_verification_gas == 21_000
      assert gas.verification_gas_limit == 100_000
      assert gas.call_gas_limit == 50_000
    end

    test "get_user_operation_receipt returns nil when the bundler has no record" do
      req = req_with(%{"eth_getUserOperationReceipt" => nil})

      assert {:ok, nil} =
               Bundler.get_user_operation_receipt("http://bundler.test", "0xdead", req: req)
    end

    test "chain_id decodes the hex quantity" do
      req = req_with(%{"eth_chainId" => "0x2105"})
      assert {:ok, 8453} = Bundler.chain_id("http://bundler.test", req: req)
    end

    test "surfaces JSON-RPC errors" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        %{"id" => id} = Jason.decode!(body)

        payload =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => id,
            "error" => %{"code" => -32_500, "message" => "AA21 didn't pay prefund"}
          })

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, payload)
      end

      op = %UserOp{sender: "0x" <> String.duplicate("11", 20)}

      assert {:error, {:rpc_error, -32_500, "AA21 didn't pay prefund"}} =
               Bundler.send_user_operation("http://bundler.test", op, @entry_point,
                 req: Req.new(plug: plug)
               )
    end
  end
end
