defmodule Raxol.MCP.ClientTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.Client
  alias Raxol.MCP.Client.Transport
  alias Raxol.MCP.TestSupport.StdioPeer

  # ADR-0037 validation item 2, stdio parity: the session machine drives a real
  # subprocess over a real port through `Transport.Stdio`, including the
  # `:noeol` reassembly path and `{:exit_status, _}`.

  defp start_peer(opts) do
    name = :"peer_#{System.unique_integer([:positive])}"
    {:ok, client} = Client.start_link([name: name] ++ StdioPeer.spec() ++ opts)
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
end
