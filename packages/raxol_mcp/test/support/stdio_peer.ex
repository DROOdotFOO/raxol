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

  The peer also writes one non-JSON banner line at startup, because a real MCP
  server writes to stderr and the port is opened `:stderr_to_stdout`.
  """

  @doc """
  The `:command` and `:args` a client spec needs to spawn this peer.

      {:ok, client} = Client.start_link([name: :peer] ++ StdioPeer.spec())
  """
  @spec spec() :: keyword()
  def spec, do: [command: System.find_executable("elixir"), args: ["-e", script()]]

  @doc "The peer's source, as handed to `elixir -e`."
  @spec script() :: String.t()
  def script do
    """
    defmodule Peer do
      def run do
        case IO.gets("") do
          :eof -> :ok
          {:error, _} -> :ok
          line -> handle(line); run()
        end
      end

      defp handle(line) do
        id = capture(line, ~r/"id":(\\d+)/)
        method = capture(line, ~r/"method":"([^"]+)"/)
        name = capture(line, ~r/"name":"([^"]+)"/)
        respond(method, id, name)
      end

      defp capture(line, pattern) do
        case Regex.run(pattern, line) do
          [_whole, captured] -> captured
          _none -> nil
        end
      end

      defp respond("initialize", id, _name) do
        emit(id, ~s({"protocolVersion":"2024-11-05","serverInfo":{"name":"stdio-peer"}}))
      end

      defp respond("notifications/initialized", _id, _name), do: :ok

      defp respond("tools/list", id, _name) do
        emit(id, ~s({"tools":[{"name":"echo","description":"echo","inputSchema":{"type":"object"}},{"name":"big","description":"big","inputSchema":{}},{"name":"bad","description":"bad","inputSchema":{}},{"name":"silent","description":"silent","inputSchema":{}},{"name":"boom","description":"boom","inputSchema":{}}]}))
      end

      defp respond("tools/call", id, "big") do
        padding = String.duplicate("x", 1_500_000)
        emit(id, ~s({"content":[{"type":"text","text":") <> padding <> ~s("}],"isError":false}))
      end

      defp respond("tools/call", id, "bad") do
        IO.puts(~s({"jsonrpc":"2.0","id":) <> id <> ~s(,"error":{"code":-32602,"message":"nope"}}))
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
end
