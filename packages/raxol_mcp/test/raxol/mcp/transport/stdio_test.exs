defmodule Raxol.MCP.Transport.StdioTest do
  use ExUnit.Case, async: true

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
      {worker, worker_ref} = approve(io, elicit_id)

      push(io, Protocol.notification("notifications/cancelled", %{"requestId" => 7}))
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout

      push(io, Protocol.request(3, "ping"))
      assert next_frame(io).id == 3
      assert_eof_stops(ctx)
    end

    test "end of input once approved kills the tool",
         %{io: io, elicit_id: elicit_id, transport: transport, transport_ref: ref} do
      {worker, worker_ref} = approve(io, elicit_id)

      PushIO.push(io, :eof)
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}, @timeout
      assert_receive {:DOWN, ^ref, :process, ^transport, :normal}, @timeout
      refute_received {:push_io, ^io, _}
    end
  end

  defp approval(elicit_id),
    do: %{jsonrpc: "2.0", id: elicit_id, result: %{action: "accept", content: %{approve: true}}}

  defp approve(io, elicit_id) do
    push(io, approval(elicit_id))
    assert_receive {:entered, worker}, @timeout
    {worker, Process.monitor(worker)}
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
      assert_receive {:DOWN, ^reader_ref, :process, ^reader, {:server_down, :killed}}, @timeout
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
  end
end
