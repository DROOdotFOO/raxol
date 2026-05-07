defmodule Raxol.ACP.Onchain.RPCTest do
  use ExUnit.Case, async: true

  alias Raxol.ACP.Onchain.RPC

  # -- Helpers --

  defp stub(handler) when is_function(handler, 1) do
    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      decoded = Jason.decode!(body)
      handler.(decoded) |> respond(conn)
    end

    RPC.client(url: "http://stub.invalid/rpc", plug: plug)
  end

  defp respond(payload, conn) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(200, Jason.encode!(payload))
  end

  defp ok_response(req, result) do
    %{"jsonrpc" => "2.0", "id" => req["id"], "result" => result}
  end

  defp err_response(req, code, message) do
    %{"jsonrpc" => "2.0", "id" => req["id"], "error" => %{"code" => code, "message" => message}}
  end

  # -- encode_quantity / decode_quantity --

  describe "encode_quantity/1" do
    test "encodes 0 as 0x0" do
      assert RPC.encode_quantity(0) == "0x0"
    end

    test "encodes integers as minimal lowercase hex" do
      assert RPC.encode_quantity(255) == "0xff"
      assert RPC.encode_quantity(1024) == "0x400"
      assert RPC.encode_quantity(20_000_000_000) == "0x4a817c800"
    end
  end

  describe "decode_quantity/1" do
    test "decodes the canonical empty quantity" do
      assert {:ok, 0} = RPC.decode_quantity("0x")
      assert {:ok, 0} = RPC.decode_quantity("0x0")
    end

    test "decodes integers" do
      assert {:ok, 255} = RPC.decode_quantity("0xff")
      assert {:ok, 1024} = RPC.decode_quantity("0x400")
    end

    test "errors on missing 0x prefix" do
      assert {:error, {:hex_decode, "ff", :missing_0x_prefix}} = RPC.decode_quantity("ff")
    end

    test "errors on non-hex content" do
      assert {:error, {:hex_decode, "0xzz", :not_integer}} = RPC.decode_quantity("0xzz")
    end
  end

  # -- Method tests through stubbed transport --

  describe "eth_chain_id/1" do
    test "decodes the chain id integer" do
      client =
        stub(fn req ->
          assert req["method"] == "eth_chainId"
          ok_response(req, "0x2105")
        end)

      assert {:ok, 8453} = RPC.eth_chain_id(client)
    end
  end

  describe "eth_block_number/1" do
    test "decodes the current block number" do
      client =
        stub(fn req ->
          assert req["method"] == "eth_blockNumber"
          ok_response(req, "0x10")
        end)

      assert {:ok, 16} = RPC.eth_block_number(client)
    end
  end

  describe "get_transaction_count/2" do
    test "returns the pending nonce as integer" do
      client =
        stub(fn req ->
          assert req["method"] == "eth_getTransactionCount"
          assert ["0x" <> _, "pending"] = req["params"]
          ok_response(req, "0x0")
        end)

      assert {:ok, 0} = RPC.get_transaction_count(client, "0x" <> String.duplicate("ab", 20))
    end
  end

  describe "estimate_gas/2" do
    test "encodes the call object and decodes the gas estimate" do
      client =
        stub(fn req ->
          assert req["method"] == "eth_estimateGas"
          [call_object] = req["params"]
          assert call_object["to"] == "0x" <> String.duplicate("ab", 20)
          assert call_object["data"] == "0xdeadbeef"
          ok_response(req, "0x5208")
        end)

      tx = %{
        to: "0x" <> String.duplicate("ab", 20),
        data: <<0xDE, 0xAD, 0xBE, 0xEF>>
      }

      assert {:ok, 21_000} = RPC.estimate_gas(client, tx)
    end

    test "skips empty/nil fields" do
      client =
        stub(fn req ->
          [call_object] = req["params"]
          # Only :to should be set; no :from, :value, or :data.
          refute Map.has_key?(call_object, "from")
          refute Map.has_key?(call_object, "value")
          ok_response(req, "0x5208")
        end)

      tx = %{to: "0x" <> String.duplicate("cd", 20)}
      assert {:ok, _} = RPC.estimate_gas(client, tx)
    end
  end

  describe "fee_history/4" do
    test "passes block_count and percentiles through" do
      client =
        stub(fn req ->
          assert req["method"] == "eth_feeHistory"
          [block_count, newest, percentiles] = req["params"]
          assert block_count == "0x4"
          assert newest == "latest"
          assert percentiles == [25, 50, 75]

          ok_response(req, %{
            "baseFeePerGas" => ["0x1", "0x2", "0x3", "0x4", "0x5"],
            "gasUsedRatio" => [0.5, 0.5, 0.5, 0.5],
            "oldestBlock" => "0x10",
            "reward" => [["0x1"], ["0x2"], ["0x3"], ["0x4"]]
          })
        end)

      assert {:ok, %{"baseFeePerGas" => _, "reward" => _}} =
               RPC.fee_history(client, 4, "latest", [25, 50, 75])
    end
  end

  describe "send_raw_transaction/2" do
    test "hex-encodes the binary payload and returns the tx hash" do
      raw = <<0x02, 0xDE, 0xAD, 0xBE, 0xEF>>

      client =
        stub(fn req ->
          assert req["method"] == "eth_sendRawTransaction"
          [hex] = req["params"]
          assert hex == "0x02deadbeef"

          ok_response(req, "0x" <> String.duplicate("ab", 32))
        end)

      assert {:ok, "0x" <> _} = RPC.send_raw_transaction(client, raw)
    end
  end

  describe "get_transaction_receipt/2" do
    test "returns nil for a pending tx (RPC returns null)" do
      client = stub(fn req -> ok_response(req, nil) end)

      assert {:ok, nil} =
               RPC.get_transaction_receipt(client, "0x" <> String.duplicate("ab", 32))
    end

    test "returns the receipt map once mined" do
      client =
        stub(fn req ->
          ok_response(req, %{
            "status" => "0x1",
            "transactionHash" => Enum.at(req["params"], 0),
            "logs" => []
          })
        end)

      assert {:ok, %{"status" => "0x1"}} =
               RPC.get_transaction_receipt(client, "0x" <> String.duplicate("ab", 32))
    end
  end

  describe "await_receipt/3" do
    test "returns the receipt as soon as the RPC stops returning nil" do
      counter = :counters.new(1, [])

      client =
        stub(fn req ->
          n = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          if n < 2 do
            ok_response(req, nil)
          else
            ok_response(req, %{"status" => "0x1"})
          end
        end)

      assert {:ok, %{"status" => "0x1"}} =
               RPC.await_receipt(client, "0x" <> String.duplicate("ab", 32),
                 timeout_ms: 1_000,
                 interval_ms: 5
               )
    end

    test "returns :timeout if no receipt arrives in time" do
      client = stub(fn req -> ok_response(req, nil) end)

      assert {:error, :timeout} =
               RPC.await_receipt(client, "0x" <> String.duplicate("ab", 32),
                 timeout_ms: 30,
                 interval_ms: 5
               )
    end
  end

  describe "JSON-RPC error envelope" do
    test "surfaces error responses" do
      client =
        stub(fn req -> err_response(req, -32_000, "execution reverted: reason string") end)

      assert {:error,
              {:rpc_error,
               %{code: -32_000, message: "execution reverted: reason string", data: nil}}} =
               RPC.eth_chain_id(client)
    end
  end

  describe "missing url" do
    test "raises a helpful error" do
      Application.delete_env(:raxol_acp, :rpc)

      assert_raise RuntimeError, ~r/no RPC URL configured/, fn ->
        RPC.client([])
      end
    end
  end
end
