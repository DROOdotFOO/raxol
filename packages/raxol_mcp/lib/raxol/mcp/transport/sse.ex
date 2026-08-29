if Code.ensure_loaded?(Plug.Router) do
  defmodule Raxol.MCP.Transport.SSE do
    @moduledoc """
    HTTP/SSE transport for MCP.

    Plug-based router providing JSON-RPC over HTTP POST and server-sent events
    for notifications. No Phoenix dependency.

    ## Endpoints

    - `POST /mcp` -- receive JSON-RPC request, return response
    - `GET /mcp/sse` -- server-sent events stream for notifications
    - `GET /health` -- health check

    ## Connection identity

    Unlike stdio, this transport serves many clients at once, and each POST is
    a separate short-lived process with nothing tying it to a stream. That
    matters for elicitation: an approval prompt belongs to the client that
    triggered it, and only that client may answer it.

    `GET /mcp/sse` therefore mints a session id and emits it as the stream's
    first event:

        event: endpoint
        data: {"sessionId":"..."}

    A client echoes it on every POST via the `mcp-session-id` header. Requests
    that carry it are attributed to that connection; requests without it are
    unidentified, which is safe but limited -- an unidentified caller can make
    ordinary requests and simply cannot elicit (an ASK resolves to the
    machine-readable deny). It can never answer someone else's prompt, because
    every unidentified request is a DISTINCT anonymous connection that owns
    nothing.

    ## Usage

    Mount in a Plug pipeline or start standalone with `Plug.Cowboy`:

        Plug.Cowboy.http(Raxol.MCP.Transport.SSE, [server: Raxol.MCP.Server], port: 4001)
    """

    use Plug.Router
    require Logger

    alias Raxol.MCP.{Deployment, Protocol, Server}

    plug(:match)
    plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
    plug(:dispatch)

    # SSE exposes tools over the network, so unlike stdio it fails closed: outside
    # dev/test it refuses to boot unless the server it fronts has an authorizer
    # configured. Override with `config :raxol_mcp, require_authorization: false`.
    @doc false
    def init(opts) do
      server = Keyword.get(opts, :server, Server)

      Deployment.enforce_authorization!(
        Server.authorization_configured?(server),
        "MCP SSE transport"
      )

      opts
    end

    post "/mcp" do
      server = conn.private[:mcp_server] || Server

      body =
        case conn.body_params do
          %Plug.Conn.Unfetched{} ->
            {:ok, raw, _conn} = Plug.Conn.read_body(conn)

            case Protocol.decode(raw) do
              {:ok, decoded} -> decoded
              {:error, _} -> nil
            end

          params when is_map(params) ->
            normalize_body_params(params)
        end

      if body do
        try do
          {:reply, response} = Server.handle_message(server, body, conn_id(conn))

          if response do
            json = Jason.encode!(response)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, json)
          else
            send_resp(conn, 204, "")
          end
        rescue
          e ->
            Logger.error("[MCP.SSE] Error handling message: #{Exception.message(e)}")

            error =
              Protocol.error_response(nil, Protocol.internal_error(), "Internal server error")

            json = Jason.encode!(error)

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(500, json)
        end
      else
        error = Protocol.error_response(nil, Protocol.parse_error(), "Invalid JSON")
        json = Jason.encode!(error)

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(400, json)
      end
    end

    get "/mcp/sse" do
      server = conn.private[:mcp_server] || Server
      session_id = mint_session_id()

      conn =
        conn
        |> put_resp_content_type("text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("mcp-session-id", session_id)
        |> send_chunked(200)

      # Subscribe this process AS this connection. The same id the client is
      # about to be told is what its POSTs must carry to be recognised.
      Server.subscribe(server, self(), session_id)

      # The client needs its id before it can send anything attributable, so it
      # is the first frame -- not a keepalive.
      {:ok, conn} =
        Plug.Conn.chunk(
          conn,
          "event: endpoint\ndata: #{Jason.encode!(%{sessionId: session_id})}\n\n"
        )

      sse_loop(conn)
    end

    get "/health" do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, ~s({"status":"ok"}))
    end

    match _ do
      send_resp(conn, 404, "Not found")
    end

    @doc false
    def call(conn, opts) do
      server = Keyword.get(opts, :server, Server)

      conn
      |> Plug.Conn.put_private(:mcp_server, server)
      |> super(opts)
    end

    # -- SSE loop ---------------------------------------------------------------

    defp sse_loop(conn) do
      receive do
        {:mcp_notification, notification} ->
          case Jason.encode(notification) do
            {:ok, json} ->
              event = "data: #{json}\n\n"

              case Plug.Conn.chunk(conn, event) do
                {:ok, conn} -> sse_loop(conn)
                {:error, _} -> conn
              end

            {:error, _} ->
              sse_loop(conn)
          end

        _ ->
          sse_loop(conn)
      after
        30_000 ->
          # Send keepalive every 30s
          case Plug.Conn.chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> sse_loop(conn)
            {:error, _} -> conn
          end
      end
    end

    # -- Private ----------------------------------------------------------------

    # The connection a request belongs to. A caller that presents no session id
    # gets a FRESH anonymous id rather than a shared one: two unidentified
    # callers must not land on the same connection, or one could answer the
    # other's elicitation exactly as before. An anonymous connection has no
    # subscriber, so it can never elicit and never owns anything to answer.
    defp conn_id(conn) do
      case Plug.Conn.get_req_header(conn, "mcp-session-id") do
        [id | _] when is_binary(id) and id != "" -> id
        _ -> {:anonymous, mint_session_id()}
      end
    end

    defp mint_session_id do
      Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    end

    defp normalize_body_params(params) do
      # Plug.Parsers decodes JSON with string keys; normalize known fields
      params
      |> normalize_param("jsonrpc", :jsonrpc)
      |> normalize_param("id", :id)
      |> normalize_param("method", :method)
      |> normalize_param("params", :params)
      |> normalize_param("result", :result)
      |> normalize_param("error", :error)
    end

    defp normalize_param(map, string_key, atom_key) do
      case Map.pop(map, string_key) do
        {nil, map} -> map
        {value, map} -> Map.put(map, atom_key, value)
      end
    end
  end
end
