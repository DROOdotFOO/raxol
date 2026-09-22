defmodule Raxol.MCP.TestSupport.StdioPeer do
  @moduledoc """
  A real MCP server on the other end of a real port, scripted to misbehave.

  Test support rather than a `lib/` reference implementation, and the
  distinction is the one `Raxol.Web3.TestSupport.TLSEndpoint` draws: nothing
  here fakes a behaviour of this package. It is a subprocess that speaks
  newline-delimited JSON-RPC, and what it proves is that
  `Raxol.MCP.Client.Transport.Stdio` reassembles a line longer than the port's
  1 MiB buffer, survives non-JSON output on the same stream, and reports an
  exit status -- none of which is observable without a process on the other end
  of a pipe. A fake transport would prove the opposite of the property under
  test.

  The peer is an `elixir -e` subprocess, so it needs no build step, no project
  and no JSON dependency: it matches the id and the method out of the request
  line and writes a canned response. That is enough, because the client is what
  is under test.

  ## The scripted tools

  | `tools/call` name | What the peer does |
  | ----------------- | ------------------ |
  | `echo` | answers with the arguments as text |
  | `big` | answers with a payload larger than the port's line buffer, which forces the `:noeol` reassembly path |
  | `bad` | answers with a JSON-RPC error |
  | `silent` | answers nothing at all, which is what the per-request timer is for |
  | `boom` | exits with status 3 mid-session |
  | `null` | answers `"result": null`, a well-formed JSON-RPC success the client must still answer its caller for |
  | `ask` | sends the client an unsolicited SERVER request and only answers the tool call once the client has answered that |

  The peer also writes one non-JSON banner line at startup, because a real MCP
  server writes to stderr and the port is opened `:stderr_to_stdout`.

  ## The modes

  | mode | The peer |
  | ---- | -------- |
  | `:default` | the MCP server above |
  | `:bad_handshake` | answers `initialize` with `"ok"` -- a result that is not an object, which no clause in the client's `handle_result/4` accepts |
  | `:deaf` | never reads its stdin and never exits on EOF, which is what an `npx` wrapper around a long-lived server is |
  | `:flood` | writes more than the client's line ceiling with no newline in it |

  The last two are `bash`, not `elixir`: a BEAM node exits when its stdin
  closes, which is the one behaviour a test of "closing the port does not stop
  the server" must not have.
  """

  @doc """
  The `:command` and `:args` a client spec needs to spawn this peer.

      {:ok, client} = Client.start_link([name: :peer] ++ StdioPeer.spec())
  """
  @spec spec(:default | :bad_handshake | :deaf | :flood) :: keyword()
  def spec(mode \\ :default)

  def spec(:deaf), do: bash("echo stdio-peer ready; sleep 30")

  # 4 MB of `x` and not one newline, then it keeps the pipe open. A `{:line, N}`
  # port hands over a `:noeol` chunk only when the line buffer FILLS, so the
  # client sees whole 1 MiB chunks: three of them clear its 2 MiB ceiling, and
  # the tail it never delivers is why this is 4 MB rather than 3.
  def spec(:flood), do: bash("head -c 4000000 /dev/zero | tr '\\0' 'x'; sleep 30")

  def spec(mode), do: [command: System.find_executable("elixir"), args: ["-e", script(mode)]]

  defp bash(script), do: [command: System.find_executable("bash"), args: ["-c", script]]

  @doc "The peer's source, as handed to `elixir -e`."
  @spec script(:default | :bad_handshake) :: String.t()
  def script(mode \\ :default) do
    """
    defmodule Peer do
      def run do
        case IO.gets("") do
          :eof -> :ok
          {:error, _} -> :ok
          line -> handle(line); run()
        end
      end

      # A line carrying our own unsolicited request's id is the CLIENT
      # answering us, not a request. Answering it is how a test observes that
      # the client answered at all.
      defp handle(line) do
        if String.contains?(line, ~s("id":9001)) do
          answered(line)
        else
          id = capture(line, ~r/"id":(\\d+)/)
          method = capture(line, ~r/"method":"([^"]+)"/)
          name = capture(line, ~r/"name":"([^"]+)"/)
          respond(method, id, name)
        end
      end

      defp answered(line) do
        code = capture(line, ~r/"code":(-?\\d+)/) || "none"
        emit(Process.get(:asked), ~s({"content":[{"type":"text","text":"answered:) <> code <> ~s("}],"isError":false}))
      end

      defp capture(line, pattern) do
        case Regex.run(pattern, line) do
          [_whole, captured] -> captured
          _none -> nil
        end
      end

      defp respond("initialize", id, _name) do
        emit(id, ~s(#{initialize_result(mode)}))
      end

      defp respond("notifications/initialized", _id, _name), do: :ok

      defp respond("tools/list", id, _name) do
        emit(id, ~s({"tools":[{"name":"echo","description":"echo","inputSchema":{"type":"object"}},{"name":"big","description":"big","inputSchema":{}},{"name":"bad","description":"bad","inputSchema":{}},{"name":"silent","description":"silent","inputSchema":{}},{"name":"boom","description":"boom","inputSchema":{}},{"name":"null","description":"null","inputSchema":{}},{"name":"ask","description":"ask","inputSchema":{}}]}))
      end

      defp respond("tools/call", id, "big") do
        padding = String.duplicate("x", 1_500_000)
        emit(id, ~s({"content":[{"type":"text","text":") <> padding <> ~s("}],"isError":false}))
      end

      defp respond("tools/call", id, "bad") do
        IO.puts(~s({"jsonrpc":"2.0","id":) <> id <> ~s(,"error":{"code":-32602,"message":"nope"}}))
      end

      defp respond("tools/call", id, "null"), do: emit(id, "null")

      defp respond("tools/call", id, "ask") do
        Process.put(:asked, id)
        IO.puts(~s({"jsonrpc":"2.0","id":9001,"method":"elicitation/create","params":{}}))
      end

      defp respond("tools/call", _id, "silent"), do: :ok

      defp respond("tools/call", _id, "boom"), do: System.halt(3)

      defp respond("tools/call", id, name) do
        emit(id, ~s({"content":[{"type":"text","text":") <> to_string(name) <> ~s("}],"isError":false}))
      end

      defp respond(_method, _id, _name), do: :ok

      defp emit(nil, _result), do: :ok

      defp emit(id, result) do
        IO.puts(~s({"jsonrpc":"2.0","id":) <> id <> ~s(,"result":) <> result <> "}")
      end
    end

    IO.puts("stdio-peer ready")
    Peer.run()
    """
  end

  # A result that is not an object: every `handle_result/4` clause for
  # `initialize` guards on `is_map`, so this is the shape that used to leave
  # the client in `:initializing` forever.
  defp initialize_result(:bad_handshake), do: ~s("ok")

  defp initialize_result(_default),
    do: ~s({"protocolVersion":"2024-11-05","serverInfo":{"name":"stdio-peer"}})
end
