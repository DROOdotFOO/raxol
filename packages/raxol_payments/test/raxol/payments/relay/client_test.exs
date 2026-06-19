defmodule Raxol.Payments.Relay.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Relay.Client
  alias Raxol.Payments.Relay.Schemas
  alias Raxol.Payments.Relay.Schemas.{QuoteRequest, ExecuteRequest}

  @tron Schemas.tron_chain_id()
  @tron_addr "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @evm_addr "0x" <> String.duplicate("ab", 20)
  @usdt_trc20 "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  defp config do
    %{
      base_url: "https://relay.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  defp request do
    %QuoteRequest{
      transfer_id: "t_1",
      from_chain_id: 8453,
      to_chain_id: @tron,
      from_token: @usdc_base,
      to_token: @usdt_trc20,
      from_amount: "500000",
      from_address: @evm_addr,
      to_address: @tron_addr
    }
  end

  describe "get_quote/2" do
    test "posts to /relay/quote and parses the response" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/relay/quote"

        Req.Test.json(conn, %{
          "transfer_id" => "t_1",
          "quote_id" => "q_1",
          "can_fill" => true,
          "to_amount" => "499000",
          "deposit_address" => @tron_addr
        })
      end)

      assert {:ok, resp} = Client.get_quote(config(), request())
      assert resp.quote_id == "q_1"
      assert resp.can_fill == true
      assert resp.deposit_address == @tron_addr
    end

    test "validates the request before any network call" do
      bad = %{request() | to_address: @evm_addr}
      assert {:error, {:invalid_to_address, _}} = Client.get_quote(config(), bad)
    end
  end

  describe "execute/2" do
    test "posts transfer_id + quote_id and parses the initial status" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/relay/execute"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body == %{"transfer_id" => "t_1", "quote_id" => "q_1"}

        Req.Test.json(conn, %{"transfer_id" => "t_1", "status" => "pending"})
      end)

      req = %ExecuteRequest{transfer_id: "t_1", quote_id: "q_1"}
      assert {:ok, status} = Client.execute(config(), req)
      assert status.status == :pending
    end
  end

  describe "get_status/2" do
    test "parses a completed transfer with its tx hash" do
      Req.Test.stub(__MODULE__, fn conn ->
        assert conn.request_path == "/relay/status/t_1"

        Req.Test.json(conn, %{
          "transfer_id" => "t_1",
          "status" => "completed",
          "tx_hash" => "abc123",
          "actual_to_amount" => "499000"
        })
      end)

      assert {:ok, status} = Client.get_status(config(), "t_1")
      assert status.status == :completed
      assert status.terminal == true
      assert status.tx_hash == "abc123"
    end

    test "returns an http error tuple on non-2xx" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
      end)

      assert {:error, {:http, 404, %{"error" => "not_found"}}} =
               Client.get_status(config(), "missing")
    end
  end

  test "rejects a non-HTTPS base_url" do
    assert_raise ArgumentError, fn ->
      Client.get_status(%{base_url: "http://evil.test", auth_token: "x"}, "t_1")
    end
  end
end
