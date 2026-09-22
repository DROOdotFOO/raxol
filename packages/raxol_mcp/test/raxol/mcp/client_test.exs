defmodule Raxol.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.Transport
  alias Raxol.MCP.TestSupport.StdioPeer

  # ADR-0037 validation item 2, stdio parity: the session machine drives a real
  # subprocess over a real port through `Transport.Stdio`, including the
  # `:noeol` reassembly path and `{:exit_status, _}`.

  # The client's contract with `Raxol.MCP.Client.Transport` is transport-
  # independent by construction (ADR-0037 decision 1), and one branch of it is
  # unreachable on demand through either in-tree transport: a `send/3` that
  # refuses the handshake SYNCHRONOUSLY. Stdio's port is still open at that
  # point in a connect, and the HTTP leg reports a failed send asynchronously
  # through `decode_info/2`, which already routes to the same place. So this
  # is the behaviour itself, implemented to refuse, and nothing else.
  defmodule RefusingTransport do
    @moduledoc false
    @behaviour Raxol.MCP.Client.Transport

    @impl true
    def connect(_config), do: {:ok, :refusing}

    @impl true
    def session(:refusing), do: {:handshake, %{version: "2024-11-05", concurrency: :stateless}}

    @impl true
    def send(:refusing, _id, _request), do: {:error, :not_connected}

    @impl true
    def respond(:refusing, _method, _response), do: {:error, :not_connected}

    @impl true
    def cancel(:refusing, _id), do: :refusing

    @impl true
    def close(:refusing), do: :ok

    @impl true
    def decode_info(:refusing, _message), do: :ignore
  end

  @wait_ms 5_000

  defp start_peer(opts), do: start_peer(:default, opts)

  defp start_peer(mode, opts) do
    name = :"peer_#{System.unique_integer([:positive])}"
    {:ok, client} = Client.start_link([name: name] ++ StdioPeer.spec(mode) ++ opts)
    on_exit(fn -> stop_quietly(client) end)
    client
  end

  # The client is linked to the test process, so an `on_exit` stop races the
  # exit signal that is already on its way. Prompt cleanup is still worth
  # having: it reaps the subprocess before the next test starts.
  defp stop_quietly(client) do
    Client.stop(client)
  catch
    :exit, _reason -> :ok
  end

  # The client answers readiness itself. A `Process.sleep` poll loop here was
  # a race dressed up as a helper: it could only ever observe a state the
  # client had already left, and on a loaded runner it observed none at all.
  defp await_ready(client, timeout \\ 5_000) do
    assert {:ok, status} = Client.await_ready(client, timeout)
    status
  end

  # A state the client reaches on its own, asked for against a deadline rather
  # than after a fixed sleep: a loaded runner makes this slower, not red.
  # There is no readiness event for a session that FAILED -- `await_ready/2`
  # only answers its own timeout -- so this is the only thing to park on.
  defp await_status(client, expected) do
    assert wait_until(fn -> Map.take(Client.status(client), Map.keys(expected)) == expected end),
           "client status settled at #{inspect(Client.status(client))}, wanted #{inspect(expected)}"
  end

  defp wait_until(fun, timeout_ms \\ @wait_ms) do
    poll_until(fun, System.monotonic_time(:millisecond) + timeout_ms)
  end

  defp poll_until(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        Process.sleep(20)
        poll_until(fun, deadline)
    end
  end

  # The port the client opened, found through the link it holds it by, and the
  # OS pid behind it. Polled because `handle_continue(:connect)` runs after
  # `start_link/1` has already answered.
  defp await_os_pid(client) do
    assert wait_until(fn -> os_pid(client) != nil end), "the client never opened a port"
    os_pid(client)
  end

  defp os_pid(client) do
    with {:links, links} <- Process.info(client, :links),
         port when is_port(port) <- Enum.find(links, &is_port/1),
         {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      os_pid
    else
      _not_yet -> nil
    end
  end

  # Asked of the OS, and through bash's `kill` BUILTIN rather than `kill(1)`:
  # procps-ng answers `kill -0` with exit 0 for targets it never found, so an
  # oracle built on it reports everything alive forever and turns a
  # `refute alive?` red for the wrong reason.
  defp alive?(os_pid) do
    {_out, status} =
      System.cmd(
        System.find_executable("bash"),
        ["-c", ~s(kill "$1" "$2"), "mcp-client-test-oracle", "-0", "#{os_pid}"],
        stderr_to_stdout: true
      )

    status == 0
  end

  describe "a stdio session" do
    test "handshakes through the transport and lists the server's tools" do
      # The peer writes a non-JSON banner line first, the way a real MCP server
      # writes to stderr on a port opened `:stderr_to_stdout`. Reaching :ready
      # at all is the assertion that it was tolerated.
      client = start_peer([])

      assert %{status: :ready, version: "2024-11-05"} = await_ready(client)
      assert {:ok, tools} = Client.list_tools(client)
      assert Enum.find(tools, &(&1.name == "echo")).description == "echo"
      assert Enum.find(tools, &(&1.name == "echo")).input_schema == %{"type" => "object"}
    end

    test "calls a tool and returns its content" do
      client = start_peer([])
      await_ready(client)

      assert {:ok, %{content: content, is_error: false}} =
               Client.call_tool(client, "echo", %{"a" => 1})

      assert [%{"type" => "text", "text" => "echo"}] = content
    end

    test "reassembles a response larger than the port's line buffer" do
      # The port is opened `{:line, 1_048_576}`, so a 1.5 MB response arrives as
      # a run of `:noeol` chunks followed by one `:eol`. The buffer that
      # rejoins them moved from the client into the transport handle; this is
      # the test that it still rejoins them.
      client = start_peer([])
      await_ready(client)

      assert {:ok, %{content: [%{"text" => text}]}} = Client.call_tool(client, "big", %{})
      assert byte_size(text) == 1_500_000
    end

    test "hands a JSON-RPC error to the caller that asked" do
      client = start_peer([])
      await_ready(client)

      assert {:error, %{"code" => -32_602, "message" => "nope"}} =
               Client.call_tool(client, "bad", %{})

      # The session survives an error for one request.
      assert {:ok, _result} = Client.call_tool(client, "echo", %{})
    end

    test "a server that exits fails the in-flight request, closes, and reconnects" do
      client = start_peer(reconnect_ms: 50)
      await_ready(client)

      assert {:error, {:server_exited, 3}} = Client.call_tool(client, "boom", %{})

      # The caller is told WHY from here on, rather than which state the
      # client is passing through.
      assert %{status: :closed, pending: 0} = Client.status(client)

      assert {:error, {:connect_failed, {:server_exited, 3}}} =
               Client.call_tool(client, "echo", %{})

      # And it comes back. A subprocess that died mid-session used to leave a
      # live process no supervisor restarts: `close_session/2` marked the
      # client `:closed` and scheduled nothing.
      assert %{status: :ready} = await_ready(client)
      assert {:ok, _result} = Client.call_tool(client, "echo", %{})
    end

    test "a request the server never answers expires instead of leaking" do
      # The leak this closes predates the change: an entry was removed only by a
      # reply, a JSON-RPC error or an exit status, so a caller whose call timed
      # out left its entry behind forever.
      client = start_peer(call_timeout: 300)
      await_ready(client)

      assert {:error, :timeout} = Client.call_tool(client, "silent", %{}, timeout: 10_000)
      assert %{pending: 0, queued: 0} = Client.status(client)

      # And the session is still usable: one expiry is not a closed connection.
      assert {:ok, _result} = Client.call_tool(client, "echo", %{})
    end
  end

  describe "the spec discriminator" do
    test "both :command and :url is refused before anything is started" do
      # The refusal comes from `start_link/1` itself rather than from a process
      # that then stops, so there is no pid to clean up and no supervision
      # noise: the discriminator is decided on the spec.
      assert {:error, {:invalid_spec, spec}} =
               Client.start_link(name: :both, command: "cat", url: "https://example.test/mcp")

      assert spec.command == "cat"
      assert spec.url == "https://example.test/mcp"
    end

    test "neither :command nor :url is refused" do
      assert {:error, {:invalid_spec, _spec}} = Client.start_link(name: :neither)
    end

    test "a map spec is accepted as readily as a keyword list" do
      assert {:error, {:invalid_spec, _spec}} =
               Client.start_link(%{name: :from_map, command: "cat", url: "https://x.test/"})
    end

    test "a refused spec's header values do not appear in the error term" do
      # A spec carries resolved credentials, and an error term is one of the
      # four places ADR-0033 section 7 names as where they leak.
      assert {:error, {:invalid_spec, spec}} =
               Client.start_link(
                 name: :leaky,
                 command: "cat",
                 url: "https://example.test/mcp",
                 headers: [{"authorization", "Bearer sk-live-do-not-log"}]
               )

      refute inspect(spec) =~ "sk-live-do-not-log"
      assert spec.headers == [{"authorization", "[redacted]"}]
    end
  end

  describe "the transport's refusal to write into nothing" do
    test "a disconnected stdio handle errors rather than silently accepting" do
      # `send_to_port/2` fell through to `:ok` for a non-port, so a client whose
      # server had exited accepted a request, never replied, and blocked the
      # caller for the full 30 s call timeout.
      handle = %Transport.Stdio{command: "cat", port: nil}

      assert {:error, :not_connected} =
               Transport.Stdio.send(handle, 1, %{method: "tools/list", params: %{}})
    end

    test "a command that does not exist leaves a client that names the reason" do
      # The connect deliberately does not stop the process: `start_link/1`
      # returns as soon as `init/1` does, so a `{:stop, _}` there or in the
      # continue would take the LINKED caller down with it, and a bad spec must
      # not kill the agent that started the client. The reason is reported to
      # the caller instead.
      {:ok, client} = Client.start_link(name: :missing, command: "raxol-no-such-executable")
      on_exit(fn -> stop_quietly(client) end)

      assert {:error, {:connect_failed, {:spawn_failed, :enoent}}} =
               Client.list_tools(client)

      assert %{status: :closed} = Client.status(client)
    end
  end

  describe "an inbound message the client used to drop on the floor" do
    test "a request the SERVER started is answered with method-not-found" do
      # This client declares no capabilities at `initialize`, so a conformant
      # peer sends no requests -- but `elicitation/create` and
      # `sampling/createMessage` arrive from peers that send them anyway, and
      # every one was dropped: no response, no log, and the server left
      # blocked on an answer that was never coming.
      #
      # The peer only answers the `ask` call once it has READ our response, and
      # it reports the code it read, so the content is the proof.
      client = start_peer([])
      await_ready(client)

      assert {:ok, %{content: [%{"text" => "answered:-32601"}]}} =
               Client.call_tool(client, "ask", %{}, timeout: 10_000)
    end

    test "a null result answers the caller instead of stalling it" do
      # `{"id":N,"result":null}` is a well-formed JSON-RPC success. Normalizing
      # on truthiness erased the key, so the message matched no response clause
      # and the caller waited out its whole timeout for a reply that had
      # already arrived.
      client = start_peer([])
      await_ready(client)

      assert {:error, {:invalid_response, "tools/call"}} =
               Client.call_tool(client, "null", %{}, timeout: 10_000)

      # Answered, not merely unblocked: the slot is free and the session lives.
      assert %{pending: 0, queued: 0} = Client.status(client)
      assert {:ok, _result} = Client.call_tool(client, "echo", %{})
    end
  end

  describe "a handshake that cannot complete" do
    test "a non-object initialize result fails the session instead of wedging it" do
      # `{"result":"ok"}` fails the `is_map` guard on the initialize clause and
      # reached the generic one, which replies to `:init` -- a no-op. The
      # client stayed `:initializing` forever and answered
      # `{:not_ready, :initializing}` to everything after it, which is what
      # makes `McpBundle.poll_tools/5` spend its whole readiness budget.
      client = start_peer(:bad_handshake, reconnect_ms: 60_000)

      await_status(client, %{status: :closed})

      assert {:error,
              {:connect_failed, {:initialization_failed, {:invalid_response, "initialize"}}}} =
               Client.list_tools(client)
    end

    test "a transport that refuses the handshake send fails the session too" do
      {:ok, client} =
        GenServer.start_link(Client, %{
          name: :refused_handshake,
          transport: RefusingTransport,
          reconnect_ms: 60_000
        })

      on_exit(fn -> stop_quietly(client) end)

      await_status(client, %{status: :closed})

      assert {:error, {:connect_failed, {:initialization_failed, :not_connected}}} =
               Client.list_tools(client)
    end
  end

  describe "what a hostile or broken server can put in the client's heap" do
    test "output with no newline in it fails the session at the ceiling" do
      # `{:line, 1_048_576}` bounds one port CHUNK, not the line: a server
      # emitting 100 MB with no newline put 100 MB in the client's heap, one
      # `:noeol` chunk at a time. The reason names the ceiling it passed.
      client = start_peer(:flood, reconnect_ms: 60_000)

      await_status(client, %{status: :closed})

      assert {:error, {:connect_failed, {:line_too_long, 2_097_152}}} =
               Client.list_tools(client)
    end
  end

  describe "stopping the client stops the server" do
    test "the owner's :shutdown reaps the OS subprocess, not just the port" do
      # `Raxol.Agent.Code.McpLoader`'s janitor ends a session with exactly this
      # signal, documented as reaping the client, its linked port AND the OS
      # subprocess. A non-trapping GenServer never runs `terminate/2`, and
      # closing a port only closes the child's stdio, so every `npx`/`uvx`
      # server that does not exit on EOF survived -- one orphan per session.
      Process.flag(:trap_exit, true)
      client = start_peer(:deaf, [])
      os_pid = await_os_pid(client)
      assert alive?(os_pid)

      Process.exit(client, :shutdown)
      assert_receive {:EXIT, ^client, :shutdown}, @wait_ms

      assert wait_until(fn -> not alive?(os_pid) end),
             "the MCP server outlived the client that owned it"
    end

    test "an orderly stop reaps it as well" do
      # The supervisor and `Client.stop/1` path: `terminate/2` ran here before,
      # but it only closed the port, which a server that ignores stdin ignores.
      client = start_peer(:deaf, [])
      os_pid = await_os_pid(client)
      assert alive?(os_pid)

      Client.stop(client)

      assert wait_until(fn -> not alive?(os_pid) end),
             "the MCP server outlived an orderly client stop"
    end
  end
end
