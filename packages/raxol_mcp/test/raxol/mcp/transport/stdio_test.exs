defmodule Raxol.MCP.Transport.StdioTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.{Protocol, Registry, Server, Transport}
  alias Raxol.MCP.TestSupport.PushIO

  setup do
    registry_name = :"registry_#{System.unique_integer([:positive])}"
    server_name = :"server_#{System.unique_integer([:positive])}"

    {:ok, _registry} = Registry.start_link(name: registry_name)
    {:ok, _server} = Server.start_link(name: server_name, registry: registry_name)

    # One device serves as stdin and stdout: the test pushes each input line
    # and receives each written frame as a message.
    {:ok, io} = PushIO.start_link()

    {:ok, transport} =
      Transport.Stdio.start_link(server: server_name, io_device: io, output_device: io)

    %{
      server: server_name,
      registry: registry_name,
      io: io,
      transport: transport,
      transport_ref: Process.monitor(transport)
    }
  end

  defp push(io, message),
    do: PushIO.push(io, message |> Protocol.encode!() |> IO.iodata_to_binary())

  defp next_frame(io) do
    assert_receive {:push_io, ^io, data}
    {:ok, frame} = Protocol.decode(data)
    frame
  end

  # After the transport is DOWN nothing more can be written, so a zero-window
  # `refute_received` is exact.
  defp assert_eof_stops(%{io: io, transport: transport, transport_ref: ref}) do
    PushIO.push(io, :eof)
    assert_receive {:DOWN, ^ref, :process, ^transport, :normal}
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
    assert_receive {:entered, worker}
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
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}
      assert_receive {:DOWN, ^transport_ref, :process, ^transport, :normal}
      refute_received {:push_io, ^io, _}
    end

    test "notifications/cancelled kills the blocked worker and answers nothing",
         %{io: io, registry: r} = ctx do
      register_blocking_tool(r)
      {worker, worker_ref} = call_blocking_tool(io, "call-1")

      push(io, Protocol.notification("notifications/cancelled", %{"requestId" => "call-1"}))
      assert_receive {:DOWN, ^worker_ref, :process, ^worker, :killed}

      # The cancelled call's reply would be written before this one.
      push(io, Protocol.request(3, "ping"))
      assert next_frame(io).id == 3

      assert_eof_stops(ctx)
    end
  end
end
