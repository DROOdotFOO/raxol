defmodule Raxol.Payments.Protocols.XochiTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.QuoteResponse

  # Signs with a fixed 65-byte signature (520 bits). The signature value is
  # irrelevant to the nonce behaviour under test; this is a signing-boundary
  # stub, not a mock of an internal module.
  defmodule SignerWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_domain, _types, _message), do: {:ok, <<7::size(520)>>}
  end

  describe "Protocol behaviour stubs" do
    test "name returns Xochi" do
      assert Xochi.name() == "Xochi"
    end

    test "detect? always returns false" do
      refute Xochi.detect?(402, [{"payment-required", "test"}])
      refute Xochi.detect?(200, [])
    end

    test "parse_challenge returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.parse_challenge([])
    end

    test "build_payment returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.build_payment(%{}, MockWallet)
    end

    test "parse_receipt returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.parse_receipt([])
    end
  end

  describe "amount/1" do
    test "extracts to_amount as Decimal" do
      assert Decimal.equal?(
               Xochi.amount(%{to_amount: "1000000"}),
               Decimal.new("1000000")
             )
    end

    test "falls back to xochi_fee" do
      assert Decimal.equal?(
               Xochi.amount(%{xochi_fee: "3000"}),
               Decimal.new("3000")
             )
    end

    test "returns zero for unknown shape" do
      assert Decimal.equal?(Xochi.amount(%{}), Decimal.new(0))
    end
  end

  describe "validate_quote (via execute)" do
    test "rejects quotes that cannot be solved" do
      quote_resp = %Raxol.Payments.Xochi.Schemas.QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: false,
        error: "no liquidity"
      }

      config = %{base_url: "https://test", auth_token: "t"}

      assert {:error, {:cannot_solve, "no liquidity"}} =
               Xochi.execute(config, quote_resp, MockWallet)
    end

    test "rejects quotes without eip712 data" do
      quote_resp = %Raxol.Payments.Xochi.Schemas.QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: true,
        eip712_data: nil
      }

      config = %{base_url: "https://test", auth_token: "t"}

      assert {:error, :no_eip712_data} =
               Xochi.execute(config, quote_resp, MockWallet)
    end
  end

  describe "execute/3 nonce" do
    test "sends the nonce embedded in the signed eip712 message" do
      quote_resp = quote_with_nonce(42)

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, SignerWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      assert Jason.decode!(raw_body)["nonce"] == 42
    end

    test "defaults to 0 when the signed message carries no nonce" do
      # The legacy/9-field Intent type the worker served has no nonce field.
      quote_resp = %QuoteResponse{
        intent_id: "xi_" <> String.duplicate("a", 32),
        quote_id: "xq_" <> String.duplicate("b", 32),
        can_solve: true,
        eip712_data: %{
          "domain" => %{"name" => "Xochi Intent", "version" => "1", "chainId" => 8453},
          "primaryType" => "Intent",
          "types" => %{"Intent" => [%{"name" => "intentId", "type" => "string"}]},
          "message" => %{"intentId" => "xi_x"}
        }
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, SignerWallet)
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      assert Jason.decode!(raw_body)["nonce"] == 0
    end
  end

  # -- Helpers --

  defp quote_with_nonce(nonce) do
    %QuoteResponse{
      intent_id: "xi_" <> String.duplicate("a", 32),
      quote_id: "xq_" <> String.duplicate("b", 32),
      can_solve: true,
      eip712_data: %{
        "domain" => %{"name" => "Xochi", "version" => "1", "chainId" => 8453},
        "primaryType" => "XochiIntent",
        "types" => %{"XochiIntent" => [%{"name" => "nonce", "type" => "uint256"}]},
        "message" => %{"nonce" => nonce}
      }
    }
  end

  defp echo_plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn.method, conn.request_path, conn.req_headers, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"status" => "submitted"}))
    end
  end
end
