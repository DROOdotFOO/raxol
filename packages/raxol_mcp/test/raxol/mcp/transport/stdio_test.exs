defmodule Raxol.MCP.Transport.StdioTest do
  use ExUnit.Case, async: false

  alias Raxol.MCP.{Protocol, Registry, Server, Transport}
  alias Raxol.MCP.TestSupport.PushIO

  setup do
    registry_name = :"registry_#{System.unique_integer([:positive])}"
    server_name = :"server_#{System.unique_integer([:positive])}"

    {:ok, _registry} = Registry.start_link(name: registry_name)
    {:ok, _server} = Server.start_link(name: server_name, registry: registry_name)

    Map.put(start_transport(server_name), :registry, registry_name)
  end

  # One device serves as stdin and stdout: the test pushes each input line
  # and receives each written frame as a message.
  defp start_transport(server_name) do
    {:ok, io} = PushIO.start_link()

    {:ok, transport} =
      Transport.Stdio.start_link(server: server_name, io_device: io, output_device: io)

    %{
      server: server_name,
      io: io,
      transport: transport,
      transport_ref: Process.monitor(transport)
    }
  end

  # Above ExUnit's 100 ms default, so a loaded machine does not flake.
  @timeout 1_000

  defp push(io, message),
    do: PushIO.push(io, message |> Protocol.encode!() |> IO.iodata_to_binary())

  defp next_frame(io) do
    assert_receive {:push_io, ^io, data}, @timeout
    {:ok, frame} = Protocol.decode(data)
    frame
  end

  # After the transport is DOWN nothing more can be written, so a zero-window
  # `refute_received` is exact.
  defp assert_eof_stops(%{io: io, transport: transport, transport_ref: ref}) do
    PushIO.push(io, :eof)
    assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, @timeout
    refute_received {:push_io, ^io, _}
  end

  defp register_blocking_tool(registry) do
    parent = self()

    Registry.register_tools(registry, [
      %{
        name: "block",
        description: "Blocks until released",
        inputSchema: %{type: "object"},
        callback: fn _args ->
          :erlang.trace(self(), true, [:procs, {:tracer, parent}])
          send(parent, {:entered, self()})

          receive do
            :release -> {:ok, "released"}
          end
        end
      }
    ])
  end

  defp call_blocking_tool(io, id) do
    push(io, Protocol.request(id, "tools/call", %{"name" => "block", "arguments" => %{}}))
    assert_receive {:entered, worker}, @timeout
    {worker, Process.monitor(worker)}
  end

  describe "stdio transport" do
    test "handles initialize request", %{io: io} = ctx do
      push(io, Protocol.request(1, "initialize", %{protocolVersion: "2024-11-05"}))

      resp = next_frame(io)
      assert resp.id == 1
      # After JSON round-trip, result keys are strings
      assert resp.result["protocolVersion"] == "2024-11-05"

      assert_eof_stops(ctx)
    end

    test "handles multiple requests", %{io: io} = ctx do
      push(io, Protocol.request(1, "initialize", %{protocolVersion: "2024-11-05"}))
      push(io, Protocol.request(2, "ping"))

      resp1 = next_frame(io)
      resp2 = next_frame(io)

      assert resp1.id == 1
      assert resp2.id == 2
      assert resp2.result == %{}

      assert_eof_stops(ctx)
    end

    test "end of input still writes the replies owed for lines read before it",
         %{io: io, transport: transport, transport_ref: ref} do
      push(io, Protocol.request(1, "initialize", %{protocolVersion: "2024-11-05"}))
      push(io, Protocol.request(2, "ping"))
      PushIO.push(io, :eof)

      assert next_frame(io).id == 1
      assert next_frame(io).id == 2
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, @timeout
      refute_received {:push_io, ^io, _}
    end

    test "a request named notifications/cancelled is answered method not found",
         %{io: io} = ctx do
      push(io, Protocol.request(5, "notifications/cancelled", %{"requestId" => 1}))

      resp = next_frame(io)
      assert resp.id == 5
      assert resp.error["code"] == Protocol.method_not_found()

      assert_eof_stops(ctx)
    end

    # The transport stops when its server does, so a frame that crashed the
    # server would take every stdio transport with it.
    test "malformed frames are answered and leave the server and transport up",
         %{io: io, server: server} = ctx do
      server_pid = Process.whereis(server)

      PushIO.push(
        io,
        ~s({"jsonrpc":"2.0","id":1,"method":"logging/setLevel","params":{"level":{"x":1}}})
      )

      PushIO.push(io, ~s({"jsonrpc":"2.0","id":2,"method":{"x":1}}))
      PushIO.push(io, ~s({"jsonrpc":"2.0","id":3,"method":[{}]}))
      push(io, Protocol.request(4, "ping"))

      assert %{id: 1, error: %{"code" => -32_602}} = next_frame(io)
      assert %{id: 2, error: %{"code" => -32_600}} = next_frame(io)
      assert %{id: 3, error: %{"code" => -32_600}} = next_frame(io)
      assert %{id: 4, result: %{}} = next_frame(io)
      assert Process.whereis(server) == server_pid

      assert_eof_stops(ctx)
    end

    test "skips notifications (no response)", %{io: io} = ctx do
      push(io, Protocol.notification("notifications/initialized"))
      push(io, Protocol.request(1, "ping"))

      # Only the ping response, not the notification
      assert next_frame(io).id == 1
      assert_eof_stops(ctx)
    end

    test "ignores blank lines", %{io: io} = ctx do
      PushIO.push(io, "")
      push(io, Protocol.request(1, "ping"))
      PushIO.push(io, "")

      assert next_frame(io).id == 1
      assert_eof_stops(ctx)
    end

    test "handles tools/list with registered tools", %{io: io, registry: r} = ctx do
      tool = %{
        name: "test_tool",
        description: "A tool",
        inputSchema: %{type: "object"},
        callback: fn _args -> {:ok, "result"} end
      }

      Registry.register_tools(r, [tool])

      push(io, Protocol.request(1, "tools/list"))
      resp = next_frame(io)

      assert length(resp.result["tools"]) == 1
      assert hd(resp.result["tools"])["name"] == "test_tool"

      assert_eof_stops(ctx)
    end
  end

  describe "requests in flight" do
    test "tools/list answers while a tools/call blocks; EOF kills the blocked worker",
         %{io: io, registry: r, transport: transport, transport_ref: transport_ref} do
      register_blocking_tool(r)
      {worker, worker_ref} = call_blocking_tool(io, 1)

      push(io, Protocol.request(2, "tools/list"))
      resp = next_frame(io)
      assert resp.id == 2
      assert [%{"name" => "block"}] = resp.result["tools"]

      PushIO.push(io, :eof)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
      assert_receive {:DOWN, ^transport_ref, :process, ^transport, :normal}, @timeout
      refute_received {:push_io, ^io, _}
    end

    test "notifications/cancelled kills the blocked worker and answers nothing",
         %{io: io, registry: r, server: server, transport: transport} = ctx do
      register_blocking_tool(r)
      {worker, worker_ref} = call_blocking_tool(io, "call-1")

      push(io, Protocol.notification("notifications/cancelled", %{"requestId" => "call-1"}))
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout

      # The cancelled call's reply would be written before this one.
      push(io, Protocol.request(3, "ping"))
      assert next_frame(io).id == 3

      # The server answered the cancelled call, so neither side still holds it.
      assert :gen_server.reqids_size(:sys.get_state(transport).requests) == 0
      assert :sys.get_state(server).in_flight == %{}

      assert_eof_stops(ctx)
    end

    test "a request reusing an in-flight id is refused, and the first stays cancellable",
         %{io: io, registry: r} = ctx do
      register_blocking_tool(r)
      {worker, worker_ref} = call_blocking_tool(io, 7)

      push(io, Protocol.request(7, "tools/call", %{"name" => "block", "arguments" => %{}}))
      resp = next_frame(io)
      assert resp.id == 7
      assert resp.error["code"] == Protocol.invalid_request()
      assert resp.error["message"] == "duplicate request id in flight"

      push(io, Protocol.notification("notifications/cancelled", %{"requestId" => 7}))
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout

      # The duplicate never reached the server, so no second worker started.
      refute_received {:entered, _}
      assert_eof_stops(ctx)
    end
  end

  describe "a tools/call parked for elicitation" do
    setup %{registry: registry} do
      server_name = :"ask_server_#{System.unique_integer([:positive])}"

      {:ok, _server} =
        Server.start_link(
          name: server_name,
          registry: registry,
          authorizer: fn _tool, _args, _ctx -> {:ask, "Run it?"} end
        )

      register_blocking_tool(registry)
      ctx = start_transport(server_name)

      push(ctx.io, Protocol.request(1, "initialize", %{capabilities: %{elicitation: %{}}}))
      assert next_frame(ctx.io).id == 1

      push(ctx.io, Protocol.request(7, "tools/call", %{"name" => "block", "arguments" => %{}}))
      assert %{method: "elicitation/create", id: elicit_id} = next_frame(ctx.io)

      Map.put(ctx, :elicit_id, elicit_id)
    end

    test "cancelled while waiting: never answered, and a later approval runs nothing",
         %{io: io, server: server, elicit_id: elicit_id} = ctx do
      push(io, Protocol.notification("notifications/cancelled", %{"requestId" => 7}))
      push(io, approval(elicit_id))

      # The server handles one sender's messages in order, so by this reply it
      # has seen the cancel and the approval: nothing is parked or running.
      push(io, Protocol.request(3, "ping"))
      assert next_frame(io).id == 3
      assert %{pending_elicitations: pending, in_flight: in_flight} = :sys.get_state(server)
      assert pending == %{}
      assert in_flight == %{}

      assert_eof_stops(ctx)
    end

    test "cancelled once approved: the tool is killed and nothing is written",
         %{io: io, elicit_id: elicit_id} = ctx do
      {worker, worker_ref} = approve(ctx, elicit_id)

      push(io, Protocol.notification("notifications/cancelled", %{"requestId" => 7}))
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout

      push(io, Protocol.request(3, "ping"))
      assert next_frame(io).id == 3
      assert_eof_stops(ctx)
    end

    test "end of input once approved kills the tool",
         %{io: io, elicit_id: elicit_id, transport: transport, transport_ref: ref} = ctx do
      {worker, worker_ref} = approve(ctx, elicit_id)

      PushIO.push(io, :eof)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, @timeout
      refute_received {:push_io, ^io, _}
    end
  end

  defp approval(elicit_id),
    do: %{jsonrpc: "2.0", id: elicit_id, result: %{action: "accept", content: %{approve: true}}}

  defp approve(%{io: io, server: server}, elicit_id) do
    server = GenServer.whereis(server)
    trace_worker_kills(server)
    push(io, approval(elicit_id))
    assert_receive {:entered, worker}, @timeout
    worker_ref = Process.monitor(worker)

    assert Process.alive?(worker),
           "approved worker was dead when monitored: " <>
             inspect(worker_exit_diagnostics(server, worker, worker_ref))

    {worker, worker_ref}
  end

  defp trace_worker_kills(server) do
    :erlang.trace_pattern({:erlang, :exit, 2}, true, [:local])
    :erlang.trace(server, true, [:call])

    on_exit(fn ->
      if Process.alive?(server), do: :erlang.trace(server, false, [:call])
      :erlang.trace_pattern({:erlang, :exit, 2}, false, [:local])
    end)
  end

  defp worker_exit_diagnostics(server, worker, worker_ref) do
    collect_worker_exit_diagnostics(server, worker, worker_ref, [])
  end

  defp collect_worker_exit_diagnostics(server, worker, worker_ref, events) do
    receive do
      {:trace, ^server, :call, {:erlang, :exit, [^worker, reason]}} ->
        collect_worker_exit_diagnostics(
          server,
          worker,
          worker_ref,
          [{:exit_sent_by, server, reason} | events]
        )

      {:trace, ^worker, :exit, reason} ->
        collect_worker_exit_diagnostics(
          server,
          worker,
          worker_ref,
          [{:worker_exit, reason} | events]
        )

      {:DOWN, ^worker_ref, :process, ^worker, reason} ->
        Enum.reverse([{:monitor_down, reason} | events])
    after
      @timeout -> Enum.reverse([:diagnostic_timeout | events])
    end
  end

  # These kill a process the test is linked to, so each unlinks it first.
  describe "abnormal exits" do
    test "a killed transport takes its reader and its in-flight workers with it",
         %{io: io, registry: r, transport: transport, transport_ref: ref} do
      register_blocking_tool(r)
      {worker, worker_ref} = call_blocking_tool(io, 1)
      reader = :sys.get_state(transport).reader
      reader_ref = Process.monitor(reader)

      Process.unlink(transport)
      Process.exit(transport, :kill)

      assert_receive {:DOWN, ^ref, :process, ^transport, :killed}, @timeout
      assert_receive {:DOWN, ^reader_ref, :process, ^reader, :killed}, @timeout
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
    end

    @tag :capture_log
    test "the server going down stops the transport with {:server_down, reason}",
         %{io: io, registry: r, server: server, transport: transport, transport_ref: ref} do
      register_blocking_tool(r)
      call_blocking_tool(io, 1)
      reader = :sys.get_state(transport).reader
      reader_ref = Process.monitor(reader)
      server_pid = Process.whereis(server)

      Process.unlink(transport)
      Process.unlink(server_pid)
      Process.exit(server_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^transport, {:server_down, :killed}}, @timeout
      assert_receive {:DOWN, ^reader_ref, :process, ^reader, :killed}, @timeout
    end

    # A restarted server knows nothing of this transport's subscription, so a
    # transport that outlived it would never see a notification again.
    @tag :capture_log
    test "the server going down while nothing is pending stops the transport too",
         %{io: io, server: server, transport: transport, transport_ref: ref} do
      push(io, Protocol.request(1, "ping"))
      assert next_frame(io).id == 1
      reader = :sys.get_state(transport).reader
      reader_ref = Process.monitor(reader)
      server_pid = Process.whereis(server)

      Process.unlink(transport)
      Process.unlink(server_pid)
      Process.exit(server_pid, :kill)

      assert_receive {:DOWN, ^ref, :process, ^transport, {:server_down, :killed}}, @timeout
      assert_receive {:DOWN, ^reader_ref, :process, ^reader, :killed}, @timeout
    end

    @tag :capture_log
    test "a transport started with no server running stops with {:server_down, :noproc}" do
      {:ok, io} = PushIO.start_link()
      Process.flag(:trap_exit, true)

      {:ok, transport} =
        Transport.Stdio.start_link(
          server: :"missing_#{System.unique_integer([:positive])}",
          io_device: io,
          output_device: io
        )

      assert_receive {:EXIT, ^transport, {:server_down, :noproc}}, @timeout
    end

    @tag :capture_log
    test "the reader dying closes the transport like end of input",
         %{io: io, registry: r, transport: transport, transport_ref: ref} do
      register_blocking_tool(r)
      {worker, worker_ref} = call_blocking_tool(io, 1)

      Process.exit(:sys.get_state(transport).reader, :kill)

      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, @timeout
      refute_received {:push_io, ^io, _}
    end

    @tag :capture_log
    test "a linked process's crash stops the transport with its reason",
         %{io: io, registry: r, transport: transport, transport_ref: ref} do
      register_blocking_tool(r)
      {worker, worker_ref} = call_blocking_tool(io, 1)
      reader_ref = Process.monitor(:sys.get_state(transport).reader)
      Process.unlink(transport)

      # The link and the exit come from one process, so they arrive in order.
      spawn(fn ->
        Process.link(transport)
        exit(:boom)
      end)

      assert_receive {:DOWN, ^ref, :process, ^transport, :boom}, @timeout
      assert_receive {:DOWN, ^reader_ref, :process, _reader, :killed}, @timeout
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
    end

    test "the starting process exiting stops the transport and its reader", %{server: server} do
      {:ok, io} = PushIO.start_link()
      test_pid = self()

      parent =
        spawn(fn ->
          {:ok, transport} =
            Transport.Stdio.start_link(server: server, io_device: io, output_device: io)

          send(test_pid, {:started, transport})
          receive do: (:exit -> :ok)
        end)

      assert_receive {:started, transport}, @timeout
      ref = Process.monitor(transport)
      reader_ref = Process.monitor(:sys.get_state(transport).reader)

      send(parent, :exit)

      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, @timeout
      assert_receive {:DOWN, ^reader_ref, :process, _reader, :killed}, @timeout
    end
  end
end
