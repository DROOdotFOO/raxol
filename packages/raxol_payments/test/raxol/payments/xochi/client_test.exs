defmodule Raxol.Payments.Xochi.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Client

  @claim_params %{
    stealth_address: "0xstealth",
    recipient: "0xrecipient",
    ephemeral_pub_key: "0xephemeral",
    signature: "0xsig"
  }

  describe "auth modes" do
    test "member mode sends an Authorization: Bearer header" do
      assert {:ok, _} = Client.claim(config(auth: {:member, "jwt-123"}), @claim_params)
      assert_receive {:req, _method, _path, headers, _body}
      assert {"authorization", "Bearer jwt-123"} in downcase(headers)
    end

    test "legacy auth_token maps to a member Bearer header" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth_token: "legacy-jwt",
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Client.claim(config, @claim_params)
      assert_receive {:req, _method, _path, headers, _body}
      assert {"authorization", "Bearer legacy-jwt"} in downcase(headers)
    end

    test "none mode sends no Authorization header" do
      assert {:ok, _} = Client.claim(config(auth: :none), @claim_params)
      assert_receive {:req, _method, _path, headers, _body}
      refute has_header?(headers, "authorization")
    end

    test "x402 mode wires AutoPay without forcing an Authorization header" do
      # On a 200 the AutoPay response step is a no-op; this asserts the wiring
      # does not break the happy path or inject a Bearer/delegation header.
      assert {:ok, _} = Client.claim(config(auth: {:x402, wallet: NoWallet}), @claim_params)
      assert_receive {:req, _method, _path, headers, _body}
      refute has_header?(headers, "authorization")
      refute has_header?(headers, "x-payment")
    end

    test "mandate mode skips the delegation header when no Store is running" do
      # raxol_payments is a library; the Store is host-started and absent here.
      # The plugin must degrade to no header rather than crash the request.
      assert {:ok, _} = Client.claim(config(auth: {:mandate, "0xagent"}), @claim_params)
      assert_receive {:req, _method, _path, headers, _body}
      refute has_header?(headers, "x-xochi-delegation")
    end
  end

  describe "claim/2" do
    test "posts a snake_case body to /api/stealth/claim" do
      params = Map.put(@claim_params, :view_tag, "0x1f")

      assert {:ok, body} = Client.claim(config(auth: :none), params)
      assert_receive {:req, "POST", "/api/stealth/claim", _headers, raw_body}

      assert Jason.decode!(raw_body) == %{
               "stealth_address" => "0xstealth",
               "recipient" => "0xrecipient",
               "ephemeral_pub_key" => "0xephemeral",
               "signature" => "0xsig",
               "view_tag" => "0x1f"
             }

      assert body["status"] == "submitted"
      assert body["tx_hash"] == "0xabc"
    end

    test "omits view_tag when it is not provided" do
      assert {:ok, _} = Client.claim(config(auth: :none), @claim_params)
      assert_receive {:req, "POST", "/api/stealth/claim", _headers, raw_body}
      refute Map.has_key?(Jason.decode!(raw_body), "view_tag")
    end
  end

  describe "base_url validation" do
    test "rejects a non-HTTPS base_url" do
      config = %{base_url: "ftp://api.xochi.fi", auth: :none}
      assert_raise ArgumentError, fn -> Client.claim(config, @claim_params) end
    end
  end

  # -- Helpers --

  defp config(opts) do
    %{base_url: "https://api.xochi.fi", req_options: [plug: echo_plug(self())]}
    |> Map.merge(Map.new(opts))
  end

  defp echo_plug(test_pid) do
    fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:req, conn.method, conn.request_path, conn.req_headers, body})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{"tx_hash" => "0xabc", "status" => "submitted"}))
    end
  end

  defp downcase(headers), do: Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

  defp has_header?(headers, name) do
    Enum.any?(downcase(headers), fn {k, _v} -> k == name end)
  end
end
