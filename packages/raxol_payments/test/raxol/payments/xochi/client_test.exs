defmodule Raxol.Payments.Xochi.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Client
  alias Raxol.Payments.Xochi.Schemas.{ExecuteRequest, ExecuteResponse}

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

    test "a Secret-wrapped auth_token is revealed into the Bearer header" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth_token: Raxol.Payments.Secret.new("wrapped-jwt"),
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Client.claim(config, @claim_params)
      assert_receive {:req, _method, _path, headers, _body}
      assert {"authorization", "Bearer wrapped-jwt"} in downcase(headers)
      # The token never renders in the clear (redacted Inspect).
      refute inspect(config.auth_token) =~ "wrapped-jwt"
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

  describe "get_intent/2" do
    test "GETs /api/intent/:id and parses the authoritative corridor + amounts" do
      intent = %{
        "id" => "xi_9",
        "status" => "quoted",
        "from_chain_id" => 8453,
        "to_chain_id" => 42_161,
        "from_token" => "0xusdc_base",
        "to_token" => "0xusdc_arb",
        "from_amount" => "1000000000",
        "to_amount" => "999000000",
        "quote_id" => "xq_9",
        "fee_rate" => 0.003,
        "settlement_type" => "public"
      }

      config = %{base_url: "https://api.xochi.fi", req_options: [plug: json_plug(intent)]}

      assert {:ok, parsed} = Client.get_intent(config, "xi_9")
      assert parsed.intent_id == "xi_9"
      assert parsed.status == :quoted
      assert parsed.from_chain_id == 8453
      assert parsed.to_chain_id == 42_161
      assert parsed.from_amount == "1000000000"
      assert parsed.to_amount == "999000000"
      assert parsed.quote_id == "xq_9"
    end

    test "surfaces a 404 as an :http error" do
      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(%{"error" => "Intent not found"}, 404), retry: false]
      }

      assert {:error, {:http, 404, _}} = Client.get_intent(config, "xi_missing")
    end
  end

  # xochi#563: execute returns a one-time read capability; the reads present it
  # in a header so a stealth/shielded intent's on-chain legs come back.
  describe "read token" do
    @token "EEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE"

    test "execute parses read_token and keeps it out of inspect" do
      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [
          plug:
            json_plug(%{
              "success" => true,
              "intent_id" => "xi_1",
              "status" => "executing",
              "read_token" => @token
            })
        ]
      }

      request = %ExecuteRequest{intent_id: "xi_1", quote_id: "xq_1", signature: "0xsig", nonce: 1}

      assert {:ok, %ExecuteResponse{read_token: @token} = exec} = Client.execute(config, request)
      refute inspect(exec) =~ @token
      refute inspect({:error, exec}) =~ @token
    end

    test "an older worker's execute response carries no read_token" do
      exec = ExecuteResponse.from_json(%{"intent_id" => "xi_1", "status" => "executing"})
      assert exec.read_token == nil
    end

    test "get_status sends the token only as the x-xochi-read-token header" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, {:url, conn.request_path, conn.query_string})
        send(test_pid, {:headers, conn.req_headers})
        Req.Test.json(conn, %{"intent_id" => "xi_1", "status" => "completed"})
      end

      config = %{base_url: "https://api.xochi.fi", req_options: [plug: plug]}

      assert {:ok, _} = Client.get_status(config, "xi_1", read_token: @token)
      assert_receive {:url, "/api/intent/xi_1/status", ""}
      assert_receive {:headers, headers}
      assert {"x-xochi-read-token", @token} in downcase(headers)
    end

    test "get_intent sends the token as the x-xochi-read-token header" do
      assert {:ok, _} = Client.get_intent(config(auth: :none), "xi_1", read_token: @token)
      assert_receive {:req, "GET", "/api/intent/xi_1", headers, _body}
      assert {"x-xochi-read-token", @token} in downcase(headers)
    end

    test "without a token no read-token header is sent" do
      assert {:ok, _} = Client.get_status(config(auth: :none), "xi_1")
      assert_receive {:req, "GET", "/api/intent/xi_1/status", headers, _body}
      refute has_header?(headers, "x-xochi-read-token")

      assert {:ok, _} = Client.get_intent(config(auth: :none), "xi_1", read_token: nil)
      assert_receive {:req, "GET", "/api/intent/xi_1", headers, _body}
      refute has_header?(headers, "x-xochi-read-token")
    end

    test "mandate auth attaches nothing new to the reads" do
      assert {:ok, _} =
               Client.get_status(config(auth: {:mandate, "0xagent"}), "xi_1", read_token: @token)

      assert_receive {:req, "GET", "/api/intent/xi_1/status", headers, _body}
      refute has_header?(headers, "x-xochi-delegation")
      assert {"x-xochi-read-token", @token} in downcase(headers)
    end

    @exec_request %ExecuteRequest{
      intent_id: "xi_1",
      quote_id: "xq_1",
      signature: "0xsig",
      nonce: 1
    }

    defp exec_502(body) do
      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(body, 502), retry: false]
      }

      Client.execute(config, @exec_request)
    end

    test "a 502 carrying read_token is in doubt without putting the token in an error" do
      result =
        exec_502(%{
          "success" => false,
          "intent_id" => "xi_1",
          "status" => "completed",
          "error" => "solver",
          "read_token" => @token
        })

      assert {:ok, %ExecuteResponse{} = exec} = result
      assert exec.reconciling
      assert exec.read_token == @token
      assert exec.intent_id == "xi_1"
      assert exec.error == "{:http, 502}"
      refute inspect(result) =~ @token
    end

    test "a 502 without read_token remains in doubt under the known intent id" do
      assert {:ok, %ExecuteResponse{} = exec} =
               exec_502(%{"success" => false, "error" => "solver rejected"})

      assert exec.intent_id == "xi_1"
      assert exec.reconciling
      assert exec.read_token == nil
    end

    test "a malformed read_token on a 502 is dropped and never enters an error" do
      assert {:ok, %ExecuteResponse{} = exec} =
               exec_502(%{"error" => "x", "read_token" => "short"})

      assert exec.reconciling
      assert exec.read_token == nil
      refute inspect(exec) =~ "short"
    end

    test "a 4xx carrying a valid read token is not a clean rejection" do
      body = %{"error" => "uncertain", "read_token" => @token}

      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(body, 409), retry: false]
      }

      assert {:ok,
              %ExecuteResponse{
                intent_id: "xi_1",
                reconciling: true,
                read_token: @token
              }} = Client.execute(config, @exec_request)
    end

    test "a structurally valid 4xx is a clean rejection with nested tokens redacted" do
      body = %{"error" => "rejected", "details" => %{"read_token" => @token}}

      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(body, 422), retry: false]
      }

      assert {:error, {:http, 422, redacted}} = Client.execute(config, @exec_request)
      assert redacted["details"]["read_token"] == "[redacted]"
      refute inspect(redacted) =~ @token
    end

    defp exec_with(status, body) do
      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(body, status), retry: false]
      }

      Client.execute(config, @exec_request)
    end

    test "an intent another writer is executing is in doubt, not a clean rejection" do
      # The worker's lost-claim answer: this request did not execute the intent,
      # but another one is, so its outcome is unknown.
      assert {:ok, %ExecuteResponse{intent_id: "xi_1", reconciling: true, status: :unknown}} =
               exec_with(409, %{"success" => false, "error" => "Intent already being executed"})
    end

    test "an intent already past quoted is in doubt for every status but expired" do
      for status <- ["executing", "settling", "completed", "failed", "refunded"] do
        body = %{"success" => false, "error" => "Cannot execute intent in #{status} status"}

        assert {:ok, %ExecuteResponse{intent_id: "xi_1", reconciling: true}} =
                 exec_with(400, body)
      end
    end

    test "an expired intent and a pre-claim conflict stay clean rejections" do
      expired = %{"success" => false, "error" => "Cannot execute intent in expired status"}
      assert {:error, {:http, 400, _}} = exec_with(400, expired)

      promo = %{
        "success" => false,
        "error" => "This quote's promo code can no longer be used.",
        "error_category" => "promo_unavailable"
      }

      assert {:error, {:http, 409, _}} = exec_with(409, promo)
      assert {:error, {:http, 400, _}} = exec_with(400, %{"error" => "Nonce already used"})
    end

    test "transport timeout and reset remain in doubt and are never retried" do
      test_pid = self()

      for reason <- [:timeout, :closed] do
        plug = fn conn ->
          send(test_pid, {:execute_attempt, reason})
          Req.Test.transport_error(conn, reason)
        end

        config = %{
          base_url: "https://api.xochi.fi",
          req_options: [plug: plug, retry: :transient]
        }

        assert {:ok, %ExecuteResponse{intent_id: "xi_1", reconciling: true, read_token: nil}} =
                 Client.execute(config, @exec_request)

        assert_received {:execute_attempt, ^reason}
        refute_received {:execute_attempt, ^reason}
      end
    end

    test "an execute 5xx is never retried even when config requests transient retries" do
      test_pid = self()

      plug = fn conn ->
        send(test_pid, :execute_attempt)
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "upstream"})
      end

      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: plug, retry: :transient]
      }

      assert {:ok, %ExecuteResponse{intent_id: "xi_1", reconciling: true}} =
               Client.execute(config, @exec_request)

      assert_received :execute_attempt
      refute_received :execute_attempt
    end

    test "a decoded response with the wrong structure remains in doubt" do
      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: json_plug(["not", "an", "object"]), retry: false]
      }

      assert {:ok, %ExecuteResponse{intent_id: "xi_1", reconciling: true}} =
               Client.execute(config, @exec_request)
    end

    test "a JSON decode failure remains in doubt under the known intent id" do
      plug = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, "{not-json")
      end

      config = %{
        base_url: "https://api.xochi.fi",
        req_options: [plug: plug, retry: false]
      }

      assert {:ok, %ExecuteResponse{intent_id: "xi_1", reconciling: true}} =
               Client.execute(config, @exec_request)
    end

    test "a non-2xx text body has its read_token redacted" do
      plug = fn conn -> Plug.Conn.send_resp(conn, 500, ~s({"read_token": "#{@token}", "x": 1)) end
      config = %{base_url: "https://api.xochi.fi", req_options: [plug: plug, retry: false]}

      assert {:error, {:http, 500, body}} = Client.get_status(config, "xi_1")
      refute inspect(body) =~ @token
      assert body =~ ~s("read_token": "[redacted]")
    end

    test "a malformed read_token is refused before any request, without echoing it" do
      for bad <- ["", "short", @token <> "=", "not a token\r\nx-injected: 1"] do
        assert {:error, :invalid_read_token} =
                 Client.get_status(config(auth: :none), "xi_1", read_token: bad)

        assert {:error, :invalid_read_token} =
                 Client.get_intent(config(auth: :none), "xi_1", read_token: bad)
      end

      refute_received {:req, _, _, _, _}
    end

    test "a served read_token of the wrong shape is dropped" do
      exec = ExecuteResponse.from_json(%{"intent_id" => "xi_1", "read_token" => "short"})
      assert exec.read_token == nil
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

  defp json_plug(body, status \\ 200) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, Jason.encode!(body))
    end
  end

  defp downcase(headers), do: Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)

  defp has_header?(headers, name) do
    Enum.any?(downcase(headers), fn {k, _v} -> k == name end)
  end
end
