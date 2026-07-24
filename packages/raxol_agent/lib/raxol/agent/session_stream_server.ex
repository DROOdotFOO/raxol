if Code.ensure_loaded?(Plug.Router) do
  defmodule Raxol.Agent.SessionStreamServer do
    @moduledoc """
    HTTP/SSE server for remote agent session observation.

    Provides REST endpoints for session listing and SSE endpoints for
    real-time event streaming. Built on Plug for zero Phoenix dependency.

    Requires `plug` as a dependency (available transitively via raxol).

    ## Endpoints

    - `GET /sessions` -- list active sessions (JSON)
    - `GET /sessions/:id` -- session info (JSON)
    - `GET /sessions/:id/events` -- SSE stream of real-time events
    - `GET /sessions/:id/history` -- recent event history (JSON)

    ## Security

    Every endpoint discloses live session content -- prompts, tool calls, and
    the agent's reasoning -- so all of them are behind a shared-secret bearer
    token and the surface is **fail-closed by default**: with no token
    configured a request is refused (`503`) rather than served open. Configure
    the token one of three ways (checked in this order):

        config :raxol_agent, session_stream_token: "..."   # app env
        RAXOL_SESSION_STREAM_TOKEN=...                       # system env

    Present it as `Authorization: Bearer <token>` or, for a browser
    `EventSource` (which cannot set headers), the `?access_token=<token>`
    query parameter. Tokens are compared in constant time.

    To run open on a trusted loopback bind (dev), opt out explicitly:

        config :raxol_agent, session_stream_require_auth: false

    Cross-origin reads are refused unless the request `Origin` is on an
    allowlist (there is no `*` wildcard): a same-origin dashboard needs no
    config; to permit specific web origins,

        config :raxol_agent, session_stream_allowed_origins: ["https://ops.example.com"]

    (`:all` echoes any `Origin` back -- opt into that only behind other auth).

    ## Usage

        # Start as part of supervision tree (requires Bandit or Plug.Cowboy)
        children = [
          {Raxol.Agent.SessionStreamer, []},
          {Bandit, plug: Raxol.Agent.SessionStreamServer, port: 4001}
        ]

        # Or start manually
        {:ok, _} = Bandit.start_link(
          plug: {Raxol.Agent.SessionStreamServer, streamer: MyStreamer},
          port: 4001
        )

    ## SSE Format

    Events are sent as Server-Sent Events with JSON data:

        event: text_delta
        data: {"text":"Hello"}

        event: tool_use
        data: {"name":"read_file","arguments":{"path":"mix.exs"},"id":"t1"}

        event: state_change
        data: {"from":"thinking","to":"acting"}
    """

    use Plug.Router

    alias Raxol.Agent.Contract
    alias Raxol.Agent.Contract.Event

    plug(:match)

    plug(Plug.Parsers,
      parsers: [:json],
      pass: ["application/json"],
      json_decoder: Jason
    )

    plug(:enforce_session_auth)

    plug(:dispatch)

    @doc false
    def init(opts), do: opts

    # -- Routes ------------------------------------------------------------------

    get "/sessions" do
      streamer = get_streamer(conn)
      sessions = Raxol.Agent.SessionStreamer.list_sessions(streamer)

      session_list =
        Enum.map(sessions, fn id ->
          %{id: to_string(id), active: true}
        end)

      send_json(conn, 200, %{sessions: session_list})
    end

    get "/sessions/:id/events" do
      streamer = get_streamer(conn)
      session_id = parse_session_id(conn.params["id"])

      conn =
        conn
        |> put_resp_header("content-type", "text/event-stream")
        |> put_resp_header("cache-control", "no-cache")
        |> put_resp_header("connection", "keep-alive")
        |> put_stream_cors()
        |> send_chunked(200)

      Raxol.Agent.SessionStreamer.subscribe(session_id, streamer)

      sse_loop(conn, session_id)
    end

    get "/sessions/:id/history" do
      streamer = get_streamer(conn)
      session_id = parse_session_id(conn.params["id"])
      events = Raxol.Agent.SessionStreamer.history(session_id, streamer)

      json_events =
        Enum.map(events, fn event ->
          {event_type, data} = serialize_event(event)
          %{event: event_type, data: data}
        end)

      send_json(conn, 200, %{
        session_id: to_string(session_id),
        events: json_events
      })
    end

    get "/sessions/:id" do
      session_id = parse_session_id(conn.params["id"])

      case lookup_session_info(session_id) do
        {:ok, info} ->
          send_json(conn, 200, info)

        {:error, :not_found} ->
          send_json(conn, 404, %{error: "session not found"})
      end
    end

    match _ do
      send_json(conn, 404, %{error: "not found"})
    end

    # -- SSE Loop ----------------------------------------------------------------

    defp sse_loop(conn, session_id) do
      receive do
        {:session_event, ^session_id, event} ->
          {event_type, data} = serialize_event(event)

          case Jason.encode(data) do
            {:ok, json} ->
              case chunk(conn, "event: #{event_type}\ndata: #{json}\n\n") do
                {:ok, conn} ->
                  sse_loop(conn, session_id)

                {:error, _reason} ->
                  conn
              end

            {:error, _} ->
              sse_loop(conn, session_id)
          end
      after
        30_000 ->
          # Send keepalive comment
          case chunk(conn, ": keepalive\n\n") do
            {:ok, conn} -> sse_loop(conn, session_id)
            {:error, _} -> conn
          end
      end
    end

    # -- Helpers ----------------------------------------------------------------

    defp get_streamer(conn) do
      case conn.private do
        %{streamer: s} -> s
        _ -> Raxol.Agent.SessionStreamer
      end
    end

    # -- Auth --------------------------------------------------------------------

    # Every session endpoint discloses live prompts/tool-calls/reasoning, so the
    # whole surface sits behind one bearer token and is fail-closed: an
    # unconfigured server refuses (503) rather than serving open, and a wrong or
    # absent token is 401. A deployment that deliberately wants an open loopback
    # bind sets `session_stream_require_auth: false`. Config resolves from
    # `conn.private` first (the seam tests and in-process wrappers use) then app
    # env / system env (the Bandit-adapter production path), mirroring how the
    # streamer itself is resolved.
    defp enforce_session_auth(conn, _opts) do
      conn = Plug.Conn.fetch_query_params(conn)

      case check_auth(conn) do
        :ok ->
          conn

        {:error, status, message} ->
          conn |> send_json(status, %{error: message}) |> halt()
      end
    end

    defp check_auth(conn) do
      case auth_token(conn) do
        token when is_binary(token) and token != "" ->
          if valid_presented_token?(conn, token),
            do: :ok,
            else: {:error, 401, "unauthorized"}

        _ ->
          if require_auth?(conn) do
            {:error, 503,
             "session streaming requires an auth token " <>
               "(set RAXOL_SESSION_STREAM_TOKEN or " <>
               "config :raxol_agent, :session_stream_token)"}
          else
            :ok
          end
      end
    end

    # Constant-time comparison; a missing/blank presented token never matches.
    defp valid_presented_token?(conn, token) do
      case presented_token(conn) do
        presented when is_binary(presented) and presented != "" ->
          Plug.Crypto.secure_compare(presented, token)

        _ ->
          false
      end
    end

    # `Authorization: Bearer <token>` when the client can set headers; the
    # `?access_token=` query param is the fallback for a browser `EventSource`,
    # which cannot.
    defp presented_token(conn) do
      bearer_token(conn) || conn.query_params["access_token"]
    end

    defp bearer_token(conn) do
      case Plug.Conn.get_req_header(conn, "authorization") do
        ["Bearer " <> token | _] -> token
        _ -> nil
      end
    end

    defp auth_token(conn) do
      private_val(conn, :session_stream_token) ||
        Application.get_env(:raxol_agent, :session_stream_token) ||
        System.get_env("RAXOL_SESSION_STREAM_TOKEN")
    end

    defp require_auth?(conn) do
      case private_val(conn, :session_stream_require_auth) do
        nil -> Application.get_env(:raxol_agent, :session_stream_require_auth, true)
        value -> value
      end
    end

    # Scoped CORS: echo the request `Origin` only when it is explicitly
    # allowlisted (or `:all` was opted into) -- never a bare `*`. With no
    # allowlist configured the header is omitted entirely, so a browser holds
    # the stream to same-origin reads.
    defp put_stream_cors(conn) do
      origin = List.first(Plug.Conn.get_req_header(conn, "origin"))
      allowed = allowed_origins(conn)

      if is_binary(origin) and (allowed == :all or origin in allowed) do
        put_resp_header(conn, "access-control-allow-origin", origin)
      else
        conn
      end
    end

    defp allowed_origins(conn) do
      private_val(conn, :session_stream_allowed_origins) ||
        Application.get_env(:raxol_agent, :session_stream_allowed_origins, [])
    end

    defp private_val(conn, key), do: Map.get(conn.private, key)

    defp parse_session_id(id) do
      case Integer.parse(id) do
        {n, ""} -> n
        _ -> id
      end
    end

    defp lookup_session_info(session_id) do
      if Process.whereis(Raxol.Agent.Registry) do
        do_lookup_session_info(session_id)
      else
        {:error, :not_found}
      end
    end

    defp do_lookup_session_info(session_id) do
      case Registry.lookup(Raxol.Agent.Registry, {:process, session_id}) do
        [{pid, _}] ->
          try do
            status = Raxol.Agent.Process.get_status(pid)

            {:ok,
             %{
               id: to_string(session_id),
               status: to_string(status.status),
               pid: inspect(pid)
             }}
          catch
            :exit, _ -> {:error, :not_found}
          end

        [] ->
          case Registry.lookup(Raxol.Agent.Registry, session_id) do
            [{_pid, _}] -> {:ok, %{id: to_string(session_id), status: "active"}}
            [] -> {:error, :not_found}
          end
      end
    end

    @passthrough_events [
      :tool_use,
      :tool_result,
      :state_change,
      :turn_complete,
      :done
    ]

    # The contract-envelope producer path (`Raxol.Agent.Contract.pump/3`,
    # `Raxol.Agent.EmitBridge`, `Raxol.Agent.AcpStreamAdapter`) emits
    # `%Event{}` structs through the SAME `SessionStreamer.emit/3` channel the
    # legacy tuple producers use — the SSE surface must speak both vocabularies
    # or a contract-backed session renders as a wall of `event: unknown`
    # frames (the bug this clause closes). The wire event name is the
    # contract `type` verbatim (`"turn_started"`, `"item_delta"`, …); the
    # payload is sanitized the same way `Contract.encode_line/1` sanitizes a
    # durable record, so a payload carrying a non-JSON-encodable term (an
    # error reason tuple, a struct) degrades to `inspect/1` text instead of
    # crashing `Jason.encode/1` mid-stream.
    defp serialize_event(%Event{type: type, payload: payload}) do
      {Atom.to_string(type), Contract.sanitize_payload(payload)}
    end

    defp serialize_event({:text_delta, text}), do: {"text_delta", %{text: text}}
    defp serialize_event({:reasoning, text}), do: {"reasoning", %{text: text}}

    defp serialize_event({:error, reason}),
      do: {"error", %{reason: inspect(reason)}}

    defp serialize_event({type, info}) when type in @passthrough_events do
      {Atom.to_string(type), info}
    end

    defp serialize_event(other), do: {"unknown", %{data: inspect(other)}}

    defp send_json(conn, status, data) do
      # Same origin-scoped CORS as the SSE stream: a cross-origin `fetch` of
      # `/history` or `/sessions` discloses the same content, so it is held to
      # the same allowlist rather than being readable from any web origin.
      conn = put_stream_cors(conn)

      case Jason.encode(data) do
        {:ok, json} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, json)

        {:error, _} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(500, ~s({"error":"encoding_failed"}))
      end
    end
  end
end
