defmodule Raxol.ACP.ProviderAdapter.JsonrpcNonceTest do
  @moduledoc """
  Hermetic proof that `Raxol.ACP.ProviderAdapter.JSONRPC` serializes nonce
  assignment through `Raxol.ACP.Wallet.NonceServer`, so concurrent
  `send_calls/3` for the same EOA never sign the same nonce.

  The RPC is stubbed with a `:plug` (picked up from the `:raxol_acp, :rpc`
  app config that the adapter's `RPC.client/1` reads); no real chain. A
  `fee_overrides` entry skips fee discovery, so the only chain read that
  matters here is `eth_getTransactionCount`, which the adapter must consult
  ONLY to seed the counter -- never per send once seeded.
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
    table = :ets.new(:jsonrpc_nonce_stub, [:set, :public])
    :ets.insert(table, {:get_tx_count_calls, 0})
    :ets.insert(table, {:tx_counter, 0})
    :ets.insert(table, {:chain_nonce, 5})
    :ets.insert(table, {:fail_send, false})

    Application.put_env(:raxol_acp, :rpc, plug: plug(table))
    on_exit(fn -> Application.delete_env(:raxol_acp, :rpc) end)

    %{table: table}
  end

  # -- Helpers --

  # A fresh, uniquely-named NonceServer per test so counter state never leaks.
  defp start_nonce_server(opts) do
    name = Module.concat(__MODULE__, "NS#{System.unique_integer([:positive])}")
    start_supervised!({NonceServer, Keyword.put(opts, :name, name)})
    name
  end

  defp adapter(nonce_server) do
    JSONRPC.new(
      chains: %{@chain => "http://stub.invalid/rpc"},
      private_key: @privkey,
      fee_overrides: %{@chain => %{max_priority_fee_per_gas: 1, max_fee_per_gas: 2}},
      nonce_server: nonce_server
    )
  end

  defp call, do: %{to: "0x" <> String.duplicate("11", 20), data: <<>>, value: 0, gas: 200_000}

  defp plug(table) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      %{"method" => method, "id" => id} = Jason.decode!(body)

      payload =
        case method do
          "eth_getTransactionCount" ->
            :ets.update_counter(table, :get_tx_count_calls, 1)
            [{:chain_nonce, n}] = :ets.lookup(table, :chain_nonce)
            result(id, hex(n))

          "eth_estimateGas" ->
            result(id, hex(21_000))

          "eth_sendRawTransaction" ->
            case :ets.lookup(table, :fail_send) do
              [{:fail_send, true}] ->
                %{
                  "jsonrpc" => "2.0",
                  "id" => id,
                  "error" => %{"code" => -32_000, "message" => "execution reverted"}
                }

              _ ->
                n = :ets.update_counter(table, :tx_counter, 1)
                result(id, "0x" <> String.pad_leading(Integer.to_string(n, 16), 64, "0"))
            end
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(payload))
    end
  end

  defp result(id, value), do: %{"jsonrpc" => "2.0", "id" => id, "result" => value}
  defp hex(n), do: "0x" <> Integer.to_string(n, 16)

  defp tx_count_calls(table) do
    [{:get_tx_count_calls, n}] = :ets.lookup(table, :get_tx_count_calls)
    n
  end

  # -- Tests --

  test "a seeded server serves a whole batch without touching the chain", %{table: table} do
    ns = start_nonce_server(initial_nonce: 5)
    a = adapter(ns)

    assert {:ok, [_, _, _]} = ProviderAdapter.send_calls(a, @chain, [call(), call(), call()])

    # Consumed three consecutive nonces from the local counter; never fetched
    # the chain nonce (the server was already seeded).
    assert NonceServer.peek(ns) == 8
    assert tx_count_calls(table) == 0
  end

  test "an unseeded server seeds from chain once, then serves locally", %{table: table} do
    ns = start_nonce_server([])
    a = adapter(ns)

    assert {:ok, [_]} = ProviderAdapter.send_calls(a, @chain, [call()])
    assert {:ok, [_]} = ProviderAdapter.send_calls(a, @chain, [call()])

    # Two separate sends took distinct nonces (5 then 6) from the shared server;
    # the chain was consulted only for the first (seeding) send.
    assert NonceServer.peek(ns) == 7
    assert tx_count_calls(table) == 1
  end

  test "concurrent send_calls for one wallet consume distinct serialized nonces" do
    ns = start_nonce_server(initial_nonce: 100)
    a = adapter(ns)

    results =
      1..20
      |> Task.async_stream(fn _ -> ProviderAdapter.send_calls(a, @chain, [call()]) end,
        max_concurrency: 16,
        ordered: false
      )
      |> Enum.map(fn {:ok, r} -> r end)

    assert Enum.all?(results, &match?({:ok, [_]}, &1))
    # 20 concurrent sends consumed exactly 20 nonces -- no collision, no
    # double-consume. Pre-fix, they would have raced on the same chain nonce.
    assert NonceServer.peek(ns) == 120
  end

  test "a failed send resyncs so the next send re-fetches the pending nonce", %{table: table} do
    ns = start_nonce_server(initial_nonce: 5)
    a = adapter(ns)

    :ets.insert(table, {:fail_send, true})
    assert {:error, _} = ProviderAdapter.send_calls(a, @chain, [call()])

    # After a failed broadcast the counter is unseeded again, so a good send
    # re-fetches the (unchanged) pending nonce and re-fills the gap.
    :ets.insert(table, {:fail_send, false})
    assert {:ok, [_]} = ProviderAdapter.send_calls(a, @chain, [call()])

    assert tx_count_calls(table) == 1
  end
end
