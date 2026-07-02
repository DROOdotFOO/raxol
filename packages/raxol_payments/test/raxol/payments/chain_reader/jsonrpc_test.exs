defmodule Raxol.Payments.ChainReader.JSONRPCTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.ChainReader
  alias Raxol.Payments.ChainReader.JSONRPC

  defp reader do
    JSONRPC.new(chains: %{1 => "https://rpc.test"}, req_options: [plug: {Req.Test, __MODULE__}])
  end

  defp stub(result) do
    Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, %{"result" => result}) end)
  end

  test "get_receipt normalizes gasUsed + effectiveGasPrice + status" do
    stub(%{"gasUsed" => "0xb05c", "effectiveGasPrice" => "0x8e1bc9bf04", "status" => "0x1"})

    assert {:ok, receipt} = ChainReader.get_receipt(reader(), 1, "0xabc")
    assert receipt.gas_used == 0xB05C
    assert receipt.effective_gas_price == 0x8E1BC9BF04
    assert receipt.status == :success
  end

  test "get_receipt returns :pending when the node has no receipt yet" do
    stub(nil)
    assert {:ok, :pending} = ChainReader.get_receipt(reader(), 1, "0xabc")
  end

  test "get_receipt falls back to gasPrice and reads a reverted status" do
    stub(%{"gasUsed" => "0x5208", "gasPrice" => "0x1", "status" => "0x0"})

    assert {:ok, receipt} = ChainReader.get_receipt(reader(), 1, "0xabc")
    assert receipt.gas_used == 0x5208
    assert receipt.effective_gas_price == 1
    assert receipt.status == :reverted
  end

  test "get_balance decodes a hex wei quantity" do
    stub("0x2386f26fc10000")
    assert {:ok, 10_000_000_000_000_000} = ChainReader.get_balance(reader(), 1, "0xowner")
  end

  test "a chain with no configured RPC is an error" do
    r = JSONRPC.new(chains: %{})
    assert {:error, {:no_rpc_for_chain, 1}} = ChainReader.get_receipt(r, 1, "0xabc")
  end
end
