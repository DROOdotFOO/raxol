defmodule Raxol.Agent.SessionStreamServerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamServer
  alias Raxol.Agent.SessionStreamer

  setup do
    {:ok, streamer} = SessionStreamer.start_link(name: nil, max_history: 50)
    %{streamer: streamer}
  end

  defp call(conn, streamer) do
    conn
    |> Plug.Conn.put_private(:streamer, streamer)
    # Routing/serialization tests run the surface in open mode; the
    # "authentication" describe block below exercises the gate itself.
    |> Plug.Conn.put_private(:session_stream_require_auth, false)
    |> SessionStreamServer.call(SessionStreamServer.init([]))
  end

  describe "GET /sessions" do
    test "returns empty list when no subscribers", %{streamer: streamer} do
      conn = conn(:get, "/sessions") |> call(streamer)

      assert conn.status == 200
      assert %{"sessions" => []} = Jason.decode!(conn.resp_body)
    end

    test "returns sessions with subscribers", %{streamer: streamer} do
      SessionStreamer.subscribe(:agent_1, streamer)

      conn = conn(:get, "/sessions") |> call(streamer)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["sessions"]) == 1
      assert hd(body["sessions"])["id"] == "agent_1"
    end
  end

  describe "GET /sessions/:id/history" do
    test "returns empty history for unknown session", %{streamer: streamer} do
      conn = conn(:get, "/sessions/unknown/history") |> call(streamer)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["events"] == []
    end

    test "returns event history", %{streamer: streamer} do
      # Use string session ID to match how HTTP path params are parsed
      SessionStreamer.emit("test_session", {:text_delta, "hello"}, streamer)

      SessionStreamer.emit(
        "test_session",
        {:tool_use, %{name: "read", arguments: %{}, id: "t1"}},
        streamer
      )

      Process.sleep(50)

      conn = conn(:get, "/sessions/test_session/history") |> call(streamer)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["events"]) == 2

      first_event = Enum.at(body["events"], 0)
      assert first_event["event"] == "text_delta"
      assert first_event["data"]["text"] == "hello"

      second_event = Enum.at(body["events"], 1)
      assert second_event["event"] == "tool_use"
      assert second_event["data"]["name"] == "read"
    end
  end

  describe "GET /sessions/:id" do
    test "returns 404 for unknown session", %{streamer: streamer} do
      conn = conn(:get, "/sessions/nonexistent") |> call(streamer)

      assert conn.status == 404
      assert %{"error" => "session not found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "404 fallback" do
    test "returns 404 for unknown routes", %{streamer: streamer} do
      conn = conn(:get, "/unknown/path") |> call(streamer)

      assert conn.status == 404
      assert %{"error" => "not found"} = Jason.decode!(conn.resp_body)
    end
  end

  describe "authentication" do
    # Drive the surface the way production does (no `require_auth: false`
    # escape hatch), varying only the configured/presented token.
    defp auth_call(conn, streamer, private) do
      conn
      |> Plug.Conn.put_private(:streamer, streamer)
      |> then(fn c ->
        Enum.reduce(private, c, fn {k, v}, acc ->
          Plug.Conn.put_private(acc, k, v)
        end)
      end)
      |> SessionStreamServer.call(SessionStreamServer.init([]))
    end

    test "fail-closed: no token configured refuses with 503", %{
      streamer: streamer
    } do
      conn = conn(:get, "/sessions") |> auth_call(streamer, %{})

      assert conn.status == 503
      assert %{"error" => msg} = Jason.decode!(conn.resp_body)
      assert msg =~ "auth token"
    end

    test "401 when a token is configured but none is presented", %{
      streamer: streamer
    } do
      conn =
        conn(:get, "/sessions")
        |> auth_call(streamer, %{session_stream_token: "s3cret"})

      assert conn.status == 401
    end

    test "401 on a wrong bearer token", %{streamer: streamer} do
      conn =
        conn(:get, "/sessions")
        |> put_req_header("authorization", "Bearer nope")
        |> auth_call(streamer, %{session_stream_token: "s3cret"})

      assert conn.status == 401
    end

    test "200 with the correct bearer token", %{streamer: streamer} do
      conn =
        conn(:get, "/sessions")
        |> put_req_header("authorization", "Bearer s3cret")
        |> auth_call(streamer, %{session_stream_token: "s3cret"})

      assert conn.status == 200
    end

    test "200 with the correct ?access_token= query param (EventSource path)",
         %{streamer: streamer} do
      conn =
        conn(:get, "/sessions?access_token=s3cret")
        |> auth_call(streamer, %{session_stream_token: "s3cret"})

      assert conn.status == 200
    end

    test "an enumerated session id is unreachable without the token", %{
      streamer: streamer
    } do
      SessionStreamer.emit(0, {:text_delta, "secret prompt"}, streamer)
      Process.sleep(20)

      conn =
        conn(:get, "/sessions/0/history")
        |> auth_call(streamer, %{session_stream_token: "s3cret"})

      assert conn.status == 401
      refute conn.resp_body =~ "secret prompt"
    end
  end

  describe "CORS" do
    # Asserted on `/sessions` (JSON) rather than the SSE `/events` route, which
    # blocks in its stream loop; the scoped-CORS helper is shared across both.
    test "no access-control-allow-origin header by default (same-origin only)",
         %{streamer: streamer} do
      conn =
        conn(:get, "/sessions")
        |> put_req_header("origin", "https://evil.example")
        |> Plug.Conn.put_private(:streamer, streamer)
        |> Plug.Conn.put_private(:session_stream_require_auth, false)
        |> SessionStreamServer.call(SessionStreamServer.init([]))

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") == []
    end

    test "echoes an allowlisted origin, never a wildcard", %{streamer: streamer} do
      conn =
        conn(:get, "/sessions")
        |> put_req_header("origin", "https://ops.example")
        |> Plug.Conn.put_private(:streamer, streamer)
        |> Plug.Conn.put_private(:session_stream_require_auth, false)
        |> Plug.Conn.put_private(
          :session_stream_allowed_origins,
          ["https://ops.example"]
        )
        |> SessionStreamServer.call(SessionStreamServer.init([]))

      assert Plug.Conn.get_resp_header(conn, "access-control-allow-origin") ==
               ["https://ops.example"]
    end
  end

  describe "event serialization" do
    test "serializes all event types to history", %{streamer: streamer} do
      events = [
        {:text_delta, "chunk"},
        {:tool_use, %{name: "cmd", arguments: %{}, id: "1"}},
        {:tool_result, %{name: "cmd", result: %{ok: true}}},
        {:state_change, %{from: :thinking, to: :acting}},
        {:turn_complete, %{iteration: 0}},
        {:done, %{content: "final"}},
        {:error, :timeout}
      ]

      for event <- events do
        SessionStreamer.emit("serial_test", event, streamer)
      end

      Process.sleep(50)

      conn = conn(:get, "/sessions/serial_test/history") |> call(streamer)
      body = Jason.decode!(conn.resp_body)

      event_types = Enum.map(body["events"], & &1["event"])

      assert "text_delta" in event_types
      assert "tool_use" in event_types
      assert "tool_result" in event_types
      assert "state_change" in event_types
      assert "turn_complete" in event_types
      assert "done" in event_types
      assert "error" in event_types
    end

    test "a contract %Event{} (the ACP-adapter / EmitBridge producer path) serializes by its own type, never falls to unknown",
         %{streamer: streamer} do
      event = %Event{
        id: 1,
        session_id: "acp_test",
        turn_id: "turn-1",
        ts: System.system_time(:microsecond),
        family: :loop,
        type: :item_delta,
        tier: :ephemeral,
        payload: %{chunk: "hi"}
      }

      SessionStreamer.emit("acp_test", event, streamer)
      Process.sleep(50)

      conn = conn(:get, "/sessions/acp_test/history") |> call(streamer)
      body = Jason.decode!(conn.resp_body)

      assert [%{"event" => "item_delta", "data" => %{"chunk" => "hi"}}] =
               body["events"]
    end

    test "a contract %Event{} payload carrying a non-JSON-encodable term degrades to text instead of crashing the encoder",
         %{streamer: streamer} do
      event = %Event{
        id: 2,
        session_id: "acp_test_err",
        turn_id: "turn-1",
        ts: System.system_time(:microsecond),
        family: :loop,
        type: :error,
        tier: :durable,
        payload: %{reason: {:tool_failed, :enoent}}
      }

      SessionStreamer.emit("acp_test_err", event, streamer)
      Process.sleep(50)

      conn = conn(:get, "/sessions/acp_test_err/history") |> call(streamer)
      body = Jason.decode!(conn.resp_body)

      assert [%{"event" => "error", "data" => data}] = body["events"]
      assert data["reason"] =~ "tool_failed"
    end
  end
end
