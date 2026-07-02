defmodule Raxol.Payments.Protocols.XochiSettledTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  defmodule Wallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_domain, _types, _message), do: {:ok, <<7::size(520)>>}
  end

  defp config do
    %{
      base_url: "https://xochi.test",
      auth_token: "t",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp request do
    %QuoteRequest{
      wallet: Wallet.address(),
      from_chain_id: 8453,
      to_chain_id: 1,
      from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
      to_token: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      from_amount: "1100000",
      settlement_preference: "public",
      slippage_bps: 50
    }
  end

  # Canned quote -> execute -> completed status, so a full transfer/4 runs offline.
  defp stub_transfer do
    Req.Test.stub(__MODULE__, fn conn ->
      case conn.request_path do
        "/api/intent/quote" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "quoteId" => "q_1",
            "canSolve" => true,
            "toAmount" => "1002487",
            "xochiFee" => "2205",
            "eip712Data" => %{
              "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
              "types" => %{"Intent" => [%{"name" => "amount", "type" => "uint256"}]},
              "message" => %{"amount" => 1_100_000}
            }
          })

        "/api/intent/execute" ->
          Req.Test.json(conn, %{"success" => true, "intentId" => "int_1", "status" => "executing"})

        "/api/intent/int_1/status" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "status" => "completed",
            "terminal" => true,
            "txHash" => "0xfill"
          })
      end
    end)
  end

  test "transfer/4 emits [:raxol, :payments, :xochi, :settled] on completion" do
    stub_transfer()
    test_pid = self()
    handler = "xochi-settled-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:raxol, :payments, :xochi, :settled],
      fn _event, meas, meta, _cfg -> send(test_pid, {:settled, meas, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert {:ok, %{status: :completed}} = Xochi.transfer(config(), request(), Wallet)

    assert_received {:settled, _meas, meta}
    assert meta.intent_id == "int_1"
    assert meta.from_chain_id == 8453
    assert meta.to_chain_id == 1
    assert meta.from_amount == "1100000"
    assert meta.to_amount == "1002487"
    assert meta.xochi_fee == "2205"
    assert meta.tx_hash == "0xfill"
  end
end
