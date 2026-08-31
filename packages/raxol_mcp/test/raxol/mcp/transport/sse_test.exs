defmodule Raxol.MCP.Transport.SSETest do
  use ExUnit.Case, async: true

  import Plug.Test
  import Plug.Conn

  alias Raxol.MCP.{Protocol, Registry, Server, Transport}

  setup do
    registry_name = :"registry_#{System.unique_integer([:positive])}"
    server_name = :"server_#{System.unique_integer([:positive])}"

    {:ok, _registry} = Registry.start_link(name: registry_name)
    {:ok, _server} = Server.start_link(name: server_name, registry: registry_name)

    %{server: server_name, registry: registry_name}
  end

  defp post_mcp(server, message) do
    {:ok, body} = Jason.encode(message)

    :post
    |> conn("/mcp", body)
    |> put_req_header("content-type", "application/json")
    |> Transport.SSE.call(server: server)
  end

  describe "POST /mcp" do
    test "handles initialize", %{server: s} do
      req = Protocol.request(1, "initialize", %{protocolVersion: "2024-11-05"})
      conn = post_mcp(s, req)

      assert conn.status == 200
      {:ok, resp} = Jason.decode(conn.resp_body)
      assert resp["id"] == 1
      assert resp["result"]["protocolVersion"] == "2024-11-05"
    end

    test "handles ping", %{server: s} do
      req = Protocol.request(2, "ping")
      conn = post_mcp(s, req)

      assert conn.status == 200
      {:ok, resp} = Jason.decode(conn.resp_body)
      assert resp["id"] == 2
      assert resp["result"] == %{}
    end

    test "handles tools/list", %{server: s, registry: r} do
      tool = %{
        name: "test",
        description: "Test tool",
        inputSchema: %{type: "object"},
        callback: fn _args -> {:ok, "ok"} end
      }

      Registry.register_tools(r, [tool])

      req = Protocol.request(3, "tools/list")
      conn = post_mcp(s, req)

      assert conn.status == 200
      {:ok, resp} = Jason.decode(conn.resp_body)
      assert length(resp["result"]["tools"]) == 1
    end

    test "handles tools/call", %{server: s, registry: r} do
      tool = %{
        name: "echo",
        description: "Echo input",
        inputSchema: %{type: "object"},
        callback: fn args -> {:ok, "echo: #{args["msg"]}"} end
      }

      Registry.register_tools(r, [tool])

      req = Protocol.request(4, "tools/call", %{name: "echo", arguments: %{msg: "hi"}})
      conn = post_mcp(s, req)

      assert conn.status == 200
      {:ok, resp} = Jason.decode(conn.resp_body)
      [content] = resp["result"]["content"]
      assert content["text"] =~ "echo: hi"
    end

    test "returns 204 for notification", %{server: s} do
      notif = Protocol.notification("notifications/initialized")
      conn = post_mcp(s, notif)

      assert conn.status == 204
    end

    test "returns error for unknown method", %{server: s} do
      req = Protocol.request(5, "unknown/method")
      conn = post_mcp(s, req)

      assert conn.status == 200
      {:ok, resp} = Jason.decode(conn.resp_body)
      assert resp["error"]["code"] == Protocol.method_not_found()
    end
  end

  describe "GET /health" do
    test "returns ok" do
      conn =
        :get
        |> conn("/health")
        |> Transport.SSE.call([])

      assert conn.status == 200
      {:ok, body} = Jason.decode(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "unknown routes" do
    test "returns 404" do
      conn =
        :get
        |> conn("/unknown")
        |> Transport.SSE.call([])

      assert conn.status == 404
    end
  end

  # `handle_message/3` is a `GenServer.call(:infinity)`, so a frame the
  # dispatcher cannot terminate on does not error -- it spins, and the server
  # never answers anyone again. These are the shapes that reached a `tools/call`
  # clause requiring keys the frame did not carry: `normalize_body_params/1`
  # only sets `:params` when the client sent one, so an unauthenticated POST is
  # all it took.
  describe "a tools/call missing its params terminates" do
    @malformed [
      {"no params", %{jsonrpc: "2.0", id: 1, method: "tools/call"}},
      {"no id", %{jsonrpc: "2.0", method: "tools/call", params: %{}}},
      {"neither", %{jsonrpc: "2.0", method: "tools/call"}}
    ]

    for {label, message} <- @malformed do
      test "#{label} answers instead of hanging", %{server: s} do
        task = Task.async(fn -> post_mcp(s, unquote(Macro.escape(message))) end)

        assert %Plug.Conn{} = Task.await(task, 2_000),
               "the dispatcher did not terminate on this frame"

        # ...and the server is still able to serve the next request.
        conn = post_mcp(s, Protocol.request(99, "ping"))
        assert conn.status == 200
        assert {:ok, %{"id" => 99}} = Jason.decode(conn.resp_body)
      end
    end

    test "a well-formed call still reaches the tool", %{server: s, registry: r} do
      :ok =
        Registry.register_tools(r, [
          %{
            name: "echo",
            description: "echo",
            inputSchema: %{type: "object"},
            callback: fn _args -> {:ok, "echoed"} end
          }
        ])

      conn =
        post_mcp(
          s,
          Protocol.request(5, "tools/call", %{"name" => "echo", "arguments" => %{}})
        )

      assert conn.status == 200
      assert {:ok, %{"id" => 5, "result" => _}} = Jason.decode(conn.resp_body)
    end
  end

  # This transport serves many clients at once, so a request has to say which
  # connection it belongs to before an elicitation can be bound to one. These
  # cover the header plumbing that carries that; the ownership rules it feeds
  # are in `Raxol.MCP.ElicitationTest`.
  describe "connection identity" do
    setup %{registry: registry} do
      :ok =
        Registry.register_tools(registry, [
          %{
            name: "spend",
            description: "move money",
            inputSchema: %{type: "object"},
            callback: fn _args -> {:ok, "spent"} end
          }
        ])

      server_name = :"idsrv_#{System.unique_integer([:positive])}"

      {:ok, _} =
        Server.start_link(
          name: server_name,
          registry: registry,
          authorizer: fn _tool, _args, _ctx -> {:ask, "Approve?"} end
        )

      %{ask_server: server_name}
    end

    defp post_as(server, message, headers) do
      {:ok, body} = Jason.encode(message)

      Enum.reduce(headers, conn(:post, "/mcp", body), fn {k, v}, c ->
        put_req_header(c, k, v)
      end)
      |> put_req_header("content-type", "application/json")
      |> Transport.SSE.call(server: server)
    end

    test "a POST carrying a session id is attributed to that connection", %{ask_server: s} do
      # Stand in for the SSE stream process this session id belongs to.
      Server.subscribe(s, self(), "sess-1")

      post_as(s, Protocol.request(1, "initialize", %{capabilities: %{elicitation: %{}}}), [
        {"mcp-session-id", "sess-1"}
      ])

      conn =
        post_as(
          s,
          Protocol.request(2, "tools/call", %{"name" => "spend", "arguments" => %{}}),
          [{"mcp-session-id", "sess-1"}]
        )

      # Parked, not answered inline -- and the prompt reached THIS connection.
      assert conn.status == 204
      assert_receive {:mcp_notification, %{method: "elicitation/create"}}, 500
    end

    test "a POST with no session id cannot elicit, and is denied instead", %{ask_server: s} do
      Server.subscribe(s, self(), "sess-1")

      # Declared on an identified connection...
      post_as(s, Protocol.request(1, "initialize", %{capabilities: %{elicitation: %{}}}), [
        {"mcp-session-id", "sess-1"}
      ])

      # ...but this caller presents no id, so it is a different, anonymous
      # connection: it cannot borrow sess-1's capability or its stream.
      conn =
        post_mcp(s, Protocol.request(2, "tools/call", %{"name" => "spend", "arguments" => %{}}))

      assert conn.status == 200
      {:ok, resp} = Jason.decode(conn.resp_body)
      payload = Jason.decode!(hd(resp["result"]["content"])["text"])
      assert payload["error"] == "authorization_required"

      refute_receive {:mcp_notification, %{method: "elicitation/create"}}, 200
    end

    test "an unrelated POST cannot answer a session's elicitation", %{ask_server: s} do
      Server.subscribe(s, self(), "sess-1")

      post_as(s, Protocol.request(1, "initialize", %{capabilities: %{elicitation: %{}}}), [
        {"mcp-session-id", "sess-1"}
      ])

      post_as(s, Protocol.request(7, "tools/call", %{"name" => "spend", "arguments" => %{}}), [
        {"mcp-session-id", "sess-1"}
      ])

      assert_receive {:mcp_notification, %{method: "elicitation/create", id: elicit_id}}, 500

      # The attacker has the id -- read off its own stream, or guessed when ids
      # were a counter -- and POSTs an approval. Anonymously, and as a different
      # named session; neither owns it.
      approval = %{
        jsonrpc: "2.0",
        id: elicit_id,
        result: %{action: "accept", content: %{approve: true}}
      }

      assert post_mcp(s, approval).status == 204
      assert post_as(s, approval, [{"mcp-session-id", "sess-2"}]).status == 204

      # The tool never ran, and sess-1's parked call is untouched.
      refute_receive {:mcp_notification, %{id: 7}}, 200
    end
  end
end
