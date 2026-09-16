if Code.ensure_loaded?(Plug.Router) do
  defmodule Raxol.MCP.Client.ReferenceServer.Legacy do
    @moduledoc """
    A reference MCP server speaking the 2025-06-18 revision: the era the hosted
    servers ADR-0033 measured on 2026-08-31 actually speak.

    What makes it legacy, and what the client is tested against:

      * `server/discover` is NOT implemented and answers method-not-found,
        which is the one JSON-RPC code that demotes an origin.
      * `initialize` is required first, and it mints a session id returned in
        the `Mcp-Session-Id` response header. Every later request must echo it;
        one that does not, or that carries an unknown id, is a 404 -- the
        session-rejected shape that re-probes the era exactly once.
      * `MCP-Protocol-Version` is required on every post.
      * `Accept` must name both content types, or the post is a 406.
      * Responses are plain JSON by default, because one of the two measured
        upstreams answers that way and the client must handle both.

    Started only through `Raxol.MCP.Client.ReferenceServer.seam/2`.
    """

    # `copy_opts_to_assign:` is how a route body reaches this router's options;
    # a bare `plug(:dispatch)` would hand it the plug's own, empty ones.
    use Plug.Router, copy_opts_to_assign: :state

    alias Raxol.MCP.Client.ReferenceServer

    @behaviour ReferenceServer

    plug(:match)
    plug(:dispatch)

    @doc false
    def init(opts) when is_map(opts), do: opts
    def init(opts), do: ReferenceServer.state(:legacy, opts)

    post _ do
      ReferenceServer.serve(conn, conn.assigns.state, __MODULE__)
    end

    match _ do
      send_resp(conn, 405, "")
    end

    @doc false
    def header_check(conn) do
      case ReferenceServer.header(conn, "mcp-protocol-version") do
        nil -> {400, "missing MCP-Protocol-Version"}
        _version -> :ok
      end
    end

    # Two methods may arrive without a session. `initialize` is what issues
    # one. `server/discover` is answered method-not-found whatever the session
    # state, because a server that does not implement a method says so rather
    # than hiding it behind an authorization failure -- and the era probe has
    # no session to present, by definition: it runs before the handshake.
    @sessionless ["initialize", "server/discover"]

    @doc false
    def answer(conn, opts, %{"method" => method} = message) when method in @sessionless do
      answer_method(conn, opts, message)
    end

    def answer(conn, opts, message) do
      session = ReferenceServer.header(conn, "mcp-session-id")

      if known_session?(opts, session) do
        answer_method(conn, opts, message)
      else
        # The session-rejected shape. A client holding an expired id must not
        # read this as "the endpoint is gone".
        send_resp(conn, 404, "unknown session")
      end
    end

    defp answer_method(conn, opts, %{"method" => "initialize", "id" => id}) do
      session = mint_session(opts)

      conn
      |> Plug.Conn.put_resp_header("mcp-session-id", session)
      |> ReferenceServer.reply_result(opts, id, %{
        "protocolVersion" => "2025-06-18",
        "capabilities" => %{"tools" => %{"listChanged" => false}},
        "serverInfo" => %{"name" => "reference-legacy", "version" => "1.0.0"}
      })
    end

    defp answer_method(conn, opts, %{"method" => "server/discover", "id" => id}) do
      ReferenceServer.reply_error(conn, opts, id, -32_601, "method not found: server/discover")
    end

    # Every other method, and every notification, is era-independent.
    defp answer_method(conn, opts, message) do
      ReferenceServer.dispatch(conn, opts, message)
    end

    defp known_session?(_opts, nil), do: false

    defp known_session?(%{sessions: sessions}, session) do
      :ets.member(sessions, session)
    end

    defp mint_session(%{sessions: sessions}) do
      session = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
      :ets.insert(sessions, {session, true})
      session
    end
  end
end
