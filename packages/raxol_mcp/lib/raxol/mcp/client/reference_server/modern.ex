if Code.ensure_loaded?(Plug.Router) do
  defmodule Raxol.MCP.Client.ReferenceServer.Modern do
    @moduledoc """
    A reference MCP server speaking the 2026-07-28 revision.

    What makes it modern, and what the client is tested against:

      * `server/discover` is implemented, which is what the era probe asks.
      * `initialize` is REFUSED with method-not-found. SEP-2575 removed it, so a
        client that handshakes here gets nothing, which is the failure ADR-0037
        decision 2's probe exists to avoid.
      * No session is ever minted, and a request carrying `Mcp-Session-Id` is
        refused with a 400. SEP-2567 removed the header; a client that sends one
        to a stateless origin is making an error this server is entitled to
        surface, so it does.
      * `Mcp-Method` and `Mcp-Name` are REQUIRED on every post. Missing either
        is a 400.
      * `Accept` must name both `application/json` and `text/event-stream`, or
        the post is a 406.
      * Responses are SSE-framed by default, with `event:` and `id:` fields the
        client's parser must retain.

    Started only through `Raxol.MCP.Client.ReferenceServer.seam/2`, which needs
    no HTTP adapter: this package depends on `plug` optionally and on no server.
    """

    # `copy_opts_to_assign:` is how a route body reaches this router's options.
    # A bare `plug(:dispatch)` hands the body the plug's OWN options, which are
    # empty, so the state would never arrive.
    use Plug.Router, copy_opts_to_assign: :state

    alias Raxol.MCP.Client.ReferenceServer

    @behaviour ReferenceServer

    plug(:match)
    plug(:dispatch)

    @doc false
    def init(opts) when is_map(opts), do: opts
    def init(opts), do: ReferenceServer.state(:modern, opts)

    post _ do
      ReferenceServer.serve(conn, conn.assigns.state, __MODULE__)
    end

    match _ do
      send_resp(conn, 405, "")
    end

    @doc false
    def header_check(conn) do
      cond do
        ReferenceServer.header(conn, "mcp-session-id") ->
          {400, "sessions were removed in 2026-07-28"}

        is_nil(ReferenceServer.header(conn, "mcp-method")) ->
          {400, "missing Mcp-Method"}

        is_nil(ReferenceServer.header(conn, "mcp-name")) ->
          {400, "missing Mcp-Name"}

        true ->
          :ok
      end
    end

    @doc false
    def answer(conn, opts, %{"method" => "initialize", "id" => id}) do
      ReferenceServer.reply_error(conn, opts, id, -32_601, "initialize was removed in 2026-07-28")
    end

    def answer(conn, opts, %{"method" => "server/discover", "id" => id}) do
      ReferenceServer.reply_result(conn, opts, id, %{
        "protocolVersion" => "2026-07-28",
        "capabilities" => %{"tools" => %{"listChanged" => false}},
        "serverInfo" => %{"name" => "reference-modern", "version" => "1.0.0"},
        "ttlMs" => 60_000,
        "cacheScope" => "origin"
      })
    end

    # Every other method, and every notification, is era-independent.
    def answer(conn, opts, message) do
      ReferenceServer.dispatch(conn, opts, message)
    end
  end
end
