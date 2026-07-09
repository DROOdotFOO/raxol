defmodule Raxol.ACP.ProviderAdapter.JsonrpcReceiptTest do
  @moduledoc """
  Hermetic proof that `Raxol.ACP.ProviderAdapter.JSONRPC.send_calls/3`
  confirms a transaction on-chain before reporting success. A mined-but-
  reverted tx (`status: 0x0`) surfaces as `{:error, {:tx_reverted, hash}}`
  rather than a false `{:ok, hash}`, so the Provider never mirrors a
  rolled-back write. This is the EOA-path parity for the SCA adapter's
  UserOp `success` check.

  RPC is stubbed via a `:plug` (picked up from the `:raxol_acp, :rpc` app
  config that the adapter's `RPC.client/1` reads); no real chain.
  """
  use ExUnit.Case, async: false

  alias Raxol.ACP.ProviderAdapter
  alias Raxol.ACP.ProviderAdapter.JSONRPC
  alias Raxol.ACP.Wallet.NonceServer

  @chain 8453
  # Anvil/Foundry test account #0. A public test value, never a real key.
  @privkey Base.decode16!(
             "ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
             case: :lower
           )

  setup do
    table = :ets.new(:jsonrpc_receipt_stub, [:set, :public])
    :ets.insert(table, {:tx_counter, 0})
    :ets.insert(table, {:receipt_status, "0x1"})
    :ets.insert(table, {:receipt_ready, true})

    Application.put_env(:raxol_acp, :rpc, plug: plug(table))
    on_exit(fn -> Application.delete_env(:raxol_acp, :rpc) end)

    %{table: table}
  end

  # -- Helpers --

  defp start_nonce_server do
    name = Module.concat(__MODULE__, "NS#{System.unique_integer([:positive])}")
    start_supervised!({NonceServer, [name: name, initial_nonce: 5]})
    name
  end

  defp adapter(nonce_server, extra \\ []) do
    JSONRPC.new(
      Keyword.merge(
        [
          chains: %{@chain => "http://stub.invalid/rpc"},
          private_key: @privkey,
          fee_overrides: %{@chain => %{max_priority_fee_per_gas: 1, max_fee_per_gas: 2}},
          nonce_server: nonce_server
        ],
        extra
      )
    )
  end

  defp call, do: %{to: "0x" <> String.duplicate("11", 20), data: <<>>, value: 0, gas: 200_000}

  defp plug(table) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"method" => method, "id" => id, "params" => params} = Jason.decode!(body)

      payload =
        case method do
          "eth_getTransactionCount" ->
            result(id, "0x5")

          "eth_estimateGas" ->
            result(id, "0x5208")

          "eth_sendRawTransaction" ->
            n = :ets.update_counter(table, :tx_counter, 1)
            result(id, "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0"))

          "eth_getTransactionReceipt" ->
            receipt(id, params, table)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end
  end

  defp receipt(id, [hash | _], table) do
    case :ets.lookup(table, :receipt_ready) do
      [{:receipt_ready, false}] ->
        # Pending forever -- drives the await timeout.
        result(id, nil)

      _ ->
        [{:receipt_status, status}] = :ets.lookup(table, :receipt_status)
        result(id, %{"status" => status, "transactionHash" => hash, "blockNumber" => "0x1"})
    end
  end

  defp result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}

  # -- Tests --

  test "a successful tx (status 0x1) is reported as a successful write" do
    adapter = adapter(start_nonce_server())

    assert {:ok, [hash]} = ProviderAdapter.send_calls(adapter, @chain, [call()])
    assert String.starts_with?(hash, "0x")
  end

  test "a mined-but-reverted tx (status 0x0) is not reported as a successful write", %{
    table: table
  } do
    :ets.insert(table, {:receipt_status, "0x0"})
    adapter = adapter(start_nonce_server())

    assert {:error, {:tx_reverted, hash}} = ProviderAdapter.send_calls(adapter, @chain, [call()])
    assert String.starts_with?(hash, "0x")
  end

  test "a tx whose receipt never arrives times out instead of reporting success", %{
    table: table
  } do
    :ets.insert(table, {:receipt_ready, false})
    adapter = adapter(start_nonce_server(), receipt_wait_opts: [timeout_ms: 30, interval_ms: 5])

    assert {:error, :timeout} = ProviderAdapter.send_calls(adapter, @chain, [call()])
  end
end
