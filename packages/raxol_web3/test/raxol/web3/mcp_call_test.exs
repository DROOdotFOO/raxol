defmodule Raxol.Web3.MCPCallTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.MCPCall

  @endpoint "https://portal.sqd.dev/mcp"

  defp unmetered do
    [
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end
    ]
  end

  defp answering(status, body) do
    [
      {:exchange,
       fn _vetted, request, _opts ->
         send(self(), {:request, request})
         {:ok, %{status: status, headers: [], body: body}}
       end}
      | unmetered()
    ]
  end

  defp call(status, body, arguments \\ %{}) do
    MCPCall.call(@endpoint, "portal_get_head", arguments, answering(status, body))
  end

  defp envelope(result) do
    Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1, "result" => result})
  end

  defp text_result(payload, extra \\ %{}) do
    Map.merge(%{"content" => [%{"type" => "text", "text" => Jason.encode!(payload)}]}, extra)
  end

  defp framed(body), do: "event: message\ndata: " <> body <> "\n\n"

  describe "the request this module makes" do
    test "one POST, with no handshake and no session header" do
      # The whole reason this module exists rather than a session client: a
      # stateless server needs no initialize, and issue #1028 records that as
      # why the Solana primary was unblocked while Tron was not.
      assert {:ok, _payload} =
               call(200, framed(envelope(text_result(%{"number" => 1}))), %{"network" => "solana"})

      assert_received {:request, request}
      assert request.method == "POST"

      names = Enum.map(request.headers, fn {name, _value} -> String.downcase(name) end)
      refute "mcp-session-id" in names

      body = Jason.decode!(request.body)
      assert body["method"] == "tools/call"

      assert body["params"] == %{
               "name" => "portal_get_head",
               "arguments" => %{"network" => "solana"}
             }

      # And exactly one request: no initialize preceded it.
      refute_received {:request, _another}
    end

    test "it accepts both content types, because the spec lets a server pick" do
      assert {:ok, _payload} = call(200, framed(envelope(text_result(%{"number" => 1}))))
      assert_received {:request, request}

      accept =
        Enum.find_value(request.headers, fn {name, value} ->
          if String.downcase(name) == "accept", do: value
        end)

      assert accept == "application/json, text/event-stream"
    end

    test "a caller's credential header survives, and the defaults still arrive" do
      # An account-gated server takes an authorization header. Assigning the
      # default list over the caller's would make a credential structurally
      # impossible to send through this module, which is a bug rather than a
      # policy: this module knows nothing about whose account it is.
      opts =
        Keyword.put(
          answering(200, framed(envelope(text_result(%{"number" => 1})))),
          :headers,
          [{"authorization", "Bearer sekrit"}]
        )

      assert {:ok, _payload} = MCPCall.call(@endpoint, "get_head", %{}, opts)
      assert_received {:request, request}

      names = Map.new(request.headers, fn {name, value} -> {String.downcase(name), value} end)

      assert names["authorization"] == "Bearer sekrit"
      assert names["content-type"] == "application/json"
      assert names["accept"] == "application/json, text/event-stream"
    end

    test "a caller that sets a default itself is not overridden" do
      # ccscan answers application/json and never frames, so narrowing accept
      # is a caller's business. Merging per name is what lets them.
      opts =
        Keyword.put(
          answering(200, envelope(text_result(%{"number" => 1}))),
          :headers,
          [{"Accept", "application/json"}]
        )

      assert {:ok, _payload} = MCPCall.call(@endpoint, "get_head", %{}, opts)
      assert_received {:request, request}

      accepts =
        for {name, value} <- request.headers, String.downcase(name) == "accept", do: value

      assert accepts == ["application/json"]
    end
  end

  describe "decoding" do
    test "an SSE-framed answer decodes to the payload inside content[0].text" do
      # SQD answers text/event-stream, measured 2026-09-14, so a plain JSON
      # decode of the body fails and the frame has to come off first.
      body = framed(envelope(text_result(%{"number" => 446_956_167, "type" => "latest"})))

      assert {:ok, %{"number" => 446_956_167, "type" => "latest"}} = call(200, body)
    end

    test "an unframed application/json answer decodes too, with no framing at all" do
      # ccscan answers application/json. The body is tried as JSON first, so a
      # server that never sends SSE needs nothing special here.
      body = envelope(text_result(%{"number" => 7}))

      assert {:ok, %{"number" => 7}} = call(200, body)
    end

    test "structuredContent is ignored even when the server sends it" do
      # Two carriers for one value means two shapes to pin and a silent
      # divergence when they disagree. Here they disagree on purpose.
      result =
        text_result(%{"number" => 1}, %{"structuredContent" => %{"number" => 999}})

      assert {:ok, %{"number" => 1}} = call(200, framed(envelope(result)))
    end
  end

  describe "an announced tool error" do
    test "arrives tagged, carrying the structured body the caller must classify" do
      # SQD's unknown network and ccscan's account_required are the same shape:
      # HTTP 200, isError true, and a machine-readable code inside the text.
      # Collapsing this would throw away the only field that distinguishes
      # "this source does not serve that chain" from "your arguments are wrong".
      payload = %{"error" => %{"code" => "unknown_network", "retryable" => false}}
      result = text_result(payload, %{"isError" => true})

      assert {:tool_error, %{"error" => %{"code" => "unknown_network"}}} =
               call(200, framed(envelope(result)))
    end

    test "a refusal whose body is prose is a refusal, not a decode failure" do
      # The protocol already said what happened; only the prose is unusable, and
      # none of it travels in the error term.
      result = %{
        "content" => [%{"type" => "text", "text" => "Your API key was withdrawn."}],
        "isError" => true
      }

      assert {:error, {:upstream_refused, :unknown}} = call(200, framed(envelope(result)))
    end

    test "an unannounced body that is not an object is a decode failure" do
      result = %{"content" => [%{"type" => "text", "text" => "not json at all"}]}

      assert {:error, {:decode_failed, :json}} = call(200, framed(envelope(result)))
    end

    test "a result with no text content at all is a decode failure" do
      assert {:error, {:decode_failed, :mcp_content}} =
               call(200, framed(envelope(%{"content" => []})))
    end
  end

  describe "envelope and transport failures" do
    test "a JSON-RPC envelope error classifies by code, never by message" do
      for {code, class} <- [
            {-32_601, :not_found},
            {-32_602, :not_found},
            {-32_001, :auth},
            {401, :auth},
            {-32_005, :rate_limit},
            {429, :rate_limit},
            {-1, :unknown}
          ] do
        body =
          Jason.encode!(%{
            "jsonrpc" => "2.0",
            "id" => 1,
            "error" => %{"code" => code, "message" => "upstream prose that must not travel"}
          })

        assert {:error, {:upstream_refused, ^class}} = call(200, framed(body)),
               "code #{code} should classify as #{class}"
      end
    end

    test "a non-2xx is a status and carries no body onward" do
      assert {:error, {:http, 403}} = call(403, "<html>challenge</html>")
    end

    test "a body that is neither JSON nor a complete SSE frame fails as framing" do
      # An unterminated frame is not a frame: `payloads/1` returns it as the
      # remainder rather than as a payload, so there is nothing to decode.
      assert {:error, {:decode_failed, :sse}} = call(200, "event: message\ndata: {\"a\":1}")
    end

    test "an envelope with neither result nor error is a JSON-RPC decode failure" do
      assert {:error, {:decode_failed, :jsonrpc}} =
               call(200, framed(Jason.encode!(%{"jsonrpc" => "2.0", "id" => 1})))
    end
  end

  describe "the framing raxol_mcp owns" do
    # The grammar itself is `Raxol.MCP.Client.SSE`'s subject and is tested
    # there. What belongs here is that this module reaches it: a body framed
    # the way a real server frames it decodes end to end.
    test "a CRLF-separated frame decodes as readily as an LF-separated one" do
      body = "event: message\r\ndata: " <> envelope(text_result(%{"number" => 5})) <> "\r\n\r\n"

      assert {:ok, %{"number" => 5}} = call(200, body)
    end

    test "data with no space after the colon decodes too" do
      body = "event: message\ndata:" <> envelope(text_result(%{"number" => 6})) <> "\n\n"

      assert {:ok, %{"number" => 6}} = call(200, body)
    end
  end
end
