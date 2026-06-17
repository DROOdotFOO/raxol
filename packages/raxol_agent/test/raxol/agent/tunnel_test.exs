defmodule Raxol.Agent.TunnelTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Tunnel
  alias Raxol.Agent.Tunnel.Link

  # A host on_open that spawns a local echo handler. The handler runs on the
  # host endpoint (the "owner's machine"): it echoes inbound data back through
  # the host tunnel, and reports closes to the test process.
  defp echo_on_open(test_pid) do
    fn %{channel_id: _cid, tunnel: tunnel} ->
      handler =
        spawn(fn -> echo_loop(tunnel, test_pid) end)

      {:ok, handler}
    end
  end

  defp echo_loop(tunnel, test_pid) do
    receive do
      {:tunnel_data, cid, data} ->
        Tunnel.send_data(tunnel, cid, "echo:" <> data)
        echo_loop(tunnel, test_pid)

      {:tunnel_closed, cid, reason} ->
        send(test_pid, {:host_closed, cid, reason})
    end
  end

  defp connected(opts \\ []) do
    test_pid = self()

    host =
      start_supervised!(
        {Tunnel,
         [
           role: :host,
           host_id: "host-1",
           capabilities: ["claude", "codex"],
           on_open: Keyword.get(opts, :on_open, echo_on_open(test_pid))
         ]},
        id: :host
      )

    server = start_supervised!({Tunnel, [role: :server]}, id: :server)
    :ok = Link.connect(host, server)
    %{host: host, server: server}
  end

  describe "hello handshake" do
    test "the server learns the host identity after the link is attached" do
      %{server: server} = connected()

      assert %{"host_id" => "host-1", "capabilities" => ["claude", "codex"]} =
               Tunnel.peer_hello(server)
    end
  end

  describe "channel open + data" do
    test "data sent on the server is handled on the host and echoes back" do
      %{server: server} = connected()

      {:ok, cid} = Tunnel.open_channel(server, "/runner/session-1")
      :ok = Tunnel.send_data(server, cid, "ping")

      assert_receive {:tunnel_data, ^cid, "echo:ping"}
    end

    test "the host materializes a channel for each open" do
      %{host: host, server: server} = connected()
      {:ok, cid} = Tunnel.open_channel(server, "/runner/x")

      # The host registered a local channel handler for the attach.
      assert cid in Tunnel.channels(host)
      assert cid in Tunnel.channels(server)
    end
  end

  describe "multiplexing many channels over one link" do
    test "channels are isolated by id" do
      %{server: server} = connected()

      {:ok, c1} = Tunnel.open_channel(server, "/runner/a")
      {:ok, c2} = Tunnel.open_channel(server, "/runner/b")

      :ok = Tunnel.send_data(server, c1, "one")
      :ok = Tunnel.send_data(server, c2, "two")

      assert_receive {:tunnel_data, ^c1, "echo:one"}
      assert_receive {:tunnel_data, ^c2, "echo:two"}
    end
  end

  describe "close" do
    test "closing on the server tears the channel down on the host" do
      %{host: host, server: server} = connected()
      {:ok, cid} = Tunnel.open_channel(server, "/runner/x")

      :ok = Tunnel.close_channel(server, cid, "done")

      assert_receive {:host_closed, ^cid, "done"}
      refute cid in Tunnel.channels(server)
      wait_until(fn -> cid not in Tunnel.channels(host) end)
    end
  end

  describe "owner liveness" do
    test "a dead channel owner closes the channel and notifies the peer" do
      %{host: host, server: server} = connected()

      owner = spawn(fn -> Process.sleep(:infinity) end)
      {:ok, cid} = Tunnel.open_channel(server, "/runner/x", owner: owner)
      assert cid in Tunnel.channels(server)

      Process.exit(owner, :kill)

      # The server drops the channel and the host is told (owner_down).
      wait_until(fn -> cid not in Tunnel.channels(server) end)
      assert_receive {:host_closed, ^cid, "owner_down"}
      wait_until(fn -> cid not in Tunnel.channels(host) end)
    end
  end

  describe "error handling" do
    test "sending on an unknown channel errors" do
      %{server: server} = connected()
      assert {:error, :unknown_channel} = Tunnel.send_data(server, "deadbeef", "x")
    end

    test "opening without a link errors" do
      tunnel = start_supervised!({Tunnel, [role: :server]})
      assert {:error, :no_link} = Tunnel.open_channel(tunnel, "/runner/x")
    end

    test "an open with no host handler is refused" do
      no_handler = start_supervised!({Tunnel, [role: :host, host_id: "h"]}, id: :nh_host)
      server = start_supervised!({Tunnel, [role: :server]}, id: :nh_server)
      :ok = Link.connect(no_handler, server)

      {:ok, cid} = Tunnel.open_channel(server, "/runner/x", owner: self())
      # Host refuses (no on_open) and sends a close; the server owner is notified.
      assert_receive {:tunnel_closed, ^cid, "no_handler"}
    end
  end

  # Deterministic spin without sleeps-as-timing: polls a predicate up to a bound.
  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(5)
      wait_until(fun, attempts - 1)
    end
  end
end
