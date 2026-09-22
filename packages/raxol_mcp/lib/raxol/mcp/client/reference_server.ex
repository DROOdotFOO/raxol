if Code.ensure_loaded?(Plug.Router) do
  defmodule Raxol.MCP.Client.ReferenceServer do
    @moduledoc """
    The shared half of the two reference MCP servers, plus the seam that drives
    them.

    ADR-0033 section 3 sets the house convention these follow: a recorded
    upstream response or a reference implementation shipped in `lib/`, and no
    mocking library. `Raxol.MCP.Client.ReferenceServer.Modern` and
    `.Legacy` are real servers, not stubs: each implements one of the two
    protocol eras the client must survive, including the ways they refuse.

    They need `plug`, which is an optional dependency here, so the era tests run
    only in the build shape that has it -- and in that shape their absence is a
    crash rather than a skip.

    ## The seam, and why it is not a socket

    `seam/2` returns a function with the shape
    `Raxol.MCP.Client.Transport.Http`'s `:exchange` option takes, so a test
    drives a reference server through the transport's whole pre-socket pipeline:
    the scheme check, the address reject set, the era probe, the era headers,
    the metering gate and the SSE parser all run for real.

    It stops at the socket deliberately. A local listener necessarily listens on
    loopback, which `Raxol.Core.Outbound`'s reject set refuses BY DESIGN, so
    there is no arrangement of the guarded path that reaches one. Weakening the
    vet so a test could reach a local server would test a policy nobody runs.
    The socket half is therefore tested where it lives, by driving
    `Raxol.MCP.Client.Transport.Http.Exchange` directly at a real TLS endpoint.

    ## Observing what arrived

    `seam/2` sends the process named by `:observer` one message per request:

        {:reference_server, %{era: :modern | :legacy, method: String.t() | nil,
                              headers: [{String.t(), String.t()}],
                              addresses: [:inet.ip_address()],
                              status: non_neg_integer()}}

    That is how a test asserts what was on the wire -- `Accept`, `Mcp-Method`,
    `Mcp-Name`, the absence of `Mcp-Session-Id`, and which address was dialled
    -- without the server having to reflect it into a response body and corrupt
    the protocol shape.
    """

    @accept_json "application/json"
    @accept_sse "text/event-stream"

    @type state :: %{
            era: :modern | :legacy,
            tools: [map()],
            framing: :json | :sse,
            refusals: :counters.counters_ref() | nil,
            sessions: :ets.table() | nil,
            observer: pid() | nil,
            result: (String.t(), map() -> {:ok, map()} | {:error, {integer(), String.t()}}) | nil
          }

    @doc """
    What an era requires of a post's headers: `:ok`, or the `{status, body}` it
    is refused with.

    Both eras demand headers on every post and both refuse one that omits
    them; WHICH headers is the difference, so that is all a child answers.
    """
    @callback header_check(Plug.Conn.t()) :: :ok | {non_neg_integer(), binary()}

    @doc """
    How an era answers a decoded message.

    Only the methods the era treats specially -- `initialize` and
    `server/discover`, where the two eras disagree by construction, plus the
    legacy session gate. Anything else a child hands to `dispatch/3`.
    """
    @callback answer(Plug.Conn.t(), state(), map()) :: Plug.Conn.t()

    @doc """
    Fill in a server's options.

    Options:

      * `:tools` - what `tools/list` answers, default one `echo` tool.
      * `:framing` - `:json` or `:sse` for response bodies. A real MCP server
        picks per response and both measured upstreams pick SSE for at least
        one method, so both are first-class here.
      * `:refuse` - how many requests to answer `403` before answering
        normally. This is the wedge: a refusal is not era evidence.
      * `:observer` - a pid to report each request to, default the calling
        process.
      * `:result` - `(method, params -> {:ok, result} | {:error, {code, message}})`,
        overriding the built-in answers for one test.

    """
    @spec state(:modern | :legacy, keyword()) :: state()
    def state(era, opts \\ []) do
      %{
        era: era,
        tools: Keyword.get(opts, :tools, [default_tool()]),
        framing: Keyword.get(opts, :framing, if(era == :modern, do: :sse, else: :json)),
        refusals: refusals(Keyword.get(opts, :refuse, 0)),
        sessions: if(era == :legacy, do: :ets.new(:reference_sessions, [:set, :public])),
        observer: Keyword.get(opts, :observer, self()),
        result: Keyword.get(opts, :result)
      }
    end

    @doc """
    An `:exchange` function that drives `router` with `state`.

    Also where a request is observed, rather than inside the routers: the seam
    sees the vetted addresses, the request as built, AND the response status, so
    one message covers a refused request too. A test asserting on headers wants
    the ones that went out whatever came back.
    """
    @spec seam(module(), state()) ::
            (map(), map(), keyword() -> {:ok, map()} | {:error, term()})
    def seam(router, state) do
      opts = router.init(state)

      fn vetted, request, _opts ->
        body = IO.iodata_to_binary(Map.get(request, :body) || "")

        conn =
          Plug.Test.conn(request.method, Map.get(request, :path, "/"), body)

        conn =
          Enum.reduce(Map.get(request, :headers, []), conn, fn {name, value}, conn ->
            Plug.Conn.put_req_header(conn, name, value)
          end)

        conn = router.call(conn, opts)
        observe(state, vetted, request, body, conn.status)

        {:ok, %{status: conn.status, headers: conn.resp_headers, body: conn.resp_body}}
      end
    end

    defp observe(%{observer: nil}, _vetted, _request, _body, _status), do: :ok

    defp observe(state, vetted, request, body, status) do
      Kernel.send(
        state.observer,
        {:reference_server,
         %{
           era: state.era,
           method: method(body),
           headers: Map.get(request, :headers, []),
           addresses: Map.get(vetted, :addresses, []),
           status: status
         }}
      )

      :ok
    end

    defp method(body) do
      case Jason.decode(body) do
        {:ok, %{"method" => method}} -> method
        _undecodable -> nil
      end
    end

    @doc "The default tool: enough to be listed and called."
    @spec default_tool() :: map()
    def default_tool do
      %{
        "name" => "echo",
        "description" => "Echo the arguments back",
        "inputSchema" => %{"type" => "object"}
      }
    end

    @doc """
    Run a post through the half of the pipeline that does not vary by era.

    The wedge refusal, the `Accept` check, the era's own header check, the body
    decode, then the era's answer. Both reference servers' `post` routes are
    this call and nothing else: the order is a protocol property rather than a
    per-era choice, and the 403 wedge has to come first so that a refusal is
    never mistaken for era evidence.
    """
    @spec serve(Plug.Conn.t(), state(), module()) :: Plug.Conn.t()
    def serve(conn, state, era) do
      cond do
        refuse?(state) ->
          Plug.Conn.send_resp(conn, 403, "refused")

        not accepts_both?(conn) ->
          Plug.Conn.send_resp(conn, 406, "")

        true ->
          checked(conn, state, era, era.header_check(conn))
      end
    end

    defp checked(conn, state, era, :ok) do
      case read_message(conn) do
        {:ok, message, conn} -> era.answer(conn, state, message)
        {:error, conn} -> Plug.Conn.send_resp(conn, 400, "unparseable")
      end
    end

    defp checked(conn, _state, _era, {status, body}) do
      Plug.Conn.send_resp(conn, status, body)
    end

    # Whether this request is one of the ones a `:refuse` count refuses.
    # Decremented per call, so `refuse: 1` answers 403 once and then answers
    # normally, which is exactly the wedge case ADR-0037 validation item 4
    # describes.
    @spec refuse?(state()) :: boolean()
    defp refuse?(%{refusals: nil}), do: false

    defp refuse?(%{refusals: ref}) do
      if :counters.get(ref, 1) > 0 do
        :counters.sub(ref, 1, 1)
        true
      else
        false
      end
    end

    # Read and decode the JSON-RPC body of a request.
    @spec read_message(Plug.Conn.t()) :: {:ok, map(), Plug.Conn.t()} | {:error, Plug.Conn.t()}
    defp read_message(conn) do
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      case Jason.decode(body) do
        {:ok, %{} = message} -> {:ok, message, conn}
        _undecodable -> {:error, conn}
      end
    end

    # Whether `Accept` names both content types.
    #
    # Mandatory, measured rather than assumed
    # (`docs/proposals/web3-upstream-survey.md:79-82`), so a server here
    # refuses a POST that omits either with a 406 instead of quietly
    # answering.
    @spec accepts_both?(Plug.Conn.t()) :: boolean()
    defp accepts_both?(conn) do
      accept = conn |> Plug.Conn.get_req_header("accept") |> Enum.join(", ")
      String.contains?(accept, @accept_json) and String.contains?(accept, @accept_sse)
    end

    @doc "One request header, or nil."
    @spec header(Plug.Conn.t(), String.t()) :: String.t() | nil
    def header(conn, name) do
      case Plug.Conn.get_req_header(conn, name) do
        [value | _rest] -> value
        [] -> nil
      end
    end

    @doc """
    Answer a JSON-RPC result in the server's framing.

    `:sse` wraps the payload in a frame with an `event:` and an `id:`, which the
    client's parser is required to retain rather than drop.
    """
    @spec reply(Plug.Conn.t(), state(), map()) :: Plug.Conn.t()
    def reply(conn, %{framing: :json}, message) do
      conn
      |> Plug.Conn.put_resp_content_type(@accept_json)
      |> Plug.Conn.send_resp(200, Jason.encode!(message))
    end

    def reply(conn, %{framing: :sse}, message) do
      frame =
        "id: #{:erlang.unique_integer([:positive])}\nevent: message\ndata: #{Jason.encode!(message)}\n\n"

      conn
      |> Plug.Conn.put_resp_content_type(@accept_sse)
      |> Plug.Conn.send_resp(200, frame)
    end

    @doc "Answer a JSON-RPC error in the server's framing."
    @spec reply_error(Plug.Conn.t(), state(), term(), integer(), String.t()) :: Plug.Conn.t()
    def reply_error(conn, state, id, code, message) do
      reply(conn, state, %{
        "jsonrpc" => "2.0",
        "id" => id,
        "error" => %{"code" => code, "message" => message}
      })
    end

    @doc "Answer a JSON-RPC result for `id`."
    @spec reply_result(Plug.Conn.t(), state(), term(), map()) :: Plug.Conn.t()
    def reply_result(conn, state, id, result) do
      reply(conn, state, %{"jsonrpc" => "2.0", "id" => id, "result" => result})
    end

    @doc """
    Answer a method the era does not treat specially.

    The built-in results, or the `:result` override, in the server's framing;
    a notification -- a message carrying no `id` -- is accepted with a 202 and
    nothing to answer. Neither half varies by era, so neither reference server
    carries a copy of it.
    """
    @spec dispatch(Plug.Conn.t(), state(), map()) :: Plug.Conn.t()
    def dispatch(conn, state, %{"method" => method, "id" => id} = message) do
      case result(state, method, message["params"] || %{}) do
        {:ok, result} -> reply_result(conn, state, id, result)
        {:error, {code, text}} -> reply_error(conn, state, id, code, text)
      end
    end

    def dispatch(conn, _state, %{"method" => _method}) do
      Plug.Conn.send_resp(conn, 202, "")
    end

    # The built-in answers shared by both eras, or the `:result` override.
    #
    # `tools/list` carries `ttlMs` and `cacheScope` because the 2026-07-28
    # revision requires them on list results; a legacy client ignores them,
    # which is why one implementation serves both.
    @spec result(state(), String.t(), map()) ::
            {:ok, map()} | {:error, {integer(), String.t()}}
    defp result(%{result: fun} = state, method, params) when is_function(fun, 2) do
      case fun.(method, params) do
        :default -> default_result(state, method, params)
        other -> other
      end
    end

    defp result(state, method, params), do: default_result(state, method, params)

    defp default_result(state, "tools/list", _params) do
      {:ok, %{"tools" => state.tools, "ttlMs" => 60_000, "cacheScope" => "session"}}
    end

    defp default_result(state, "tools/call", params) do
      name = params["name"]

      if Enum.any?(state.tools, &(&1["name"] == name)) do
        {:ok,
         %{
           "content" => [%{"type" => "text", "text" => Jason.encode!(params["arguments"] || %{})}],
           "isError" => false
         }}
      else
        {:error, {-32_602, "unknown tool"}}
      end
    end

    defp default_result(_state, method, _params) do
      {:error, {-32_601, "method not found: #{method}"}}
    end

    defp refusals(0), do: nil

    defp refusals(count) when is_integer(count) and count > 0 do
      ref = :counters.new(1, [])
      :counters.add(ref, 1, count)
      ref
    end
  end
end
