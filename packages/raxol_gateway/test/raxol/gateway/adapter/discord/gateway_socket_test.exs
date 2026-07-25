defmodule Raxol.Gateway.Adapter.Discord.GatewaySocketTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Raxol.Gateway.Adapter.Discord.GatewaySocket
  alias Raxol.Gateway.Test.FakeSocketTransport

  # The fake transport reports connects/sends/closes to this test process;
  # the test drives the socket with {:fake_transport, event} messages. All
  # timers that matter fire manually (send :heartbeat) or within a 1-2ms
  # reconnect backoff - no sleeps, no wall-clock asserts. jitter_fn 1.0
  # parks the real first-heartbeat timer a full interval away.
  defp start_socket!(opts \\ []) do
    test_pid = self()

    defaults = [
      token: "bot-token",
      on_event: fn frame -> send(test_pid, {:event, frame}) end,
      transport: FakeSocketTransport,
      transport_opts: [owner: test_pid],
      parent: test_pid,
      reconnect_base_ms: 1,
      reconnect_max_ms: 4,
      jitter_fn: fn -> 1.0 end
    ]

    start_supervised!(
      %{
        id: make_ref(),
        start: {GatewaySocket, :start_link, [Keyword.merge(defaults, opts)]}
      },
      restart: :temporary
    )
  end

  defp fake(pid, event), do: send(pid, {:fake_transport, event})

  defp text(pid, frame), do: fake(pid, {:text, Jason.encode!(frame)})

  defp hello(pid, interval \\ 300_000),
    do: text(pid, %{op: 10, d: %{heartbeat_interval: interval}})

  defp dispatch(pid, type, data, seq),
    do: text(pid, %{op: 0, t: type, s: seq, d: data})

  defp assert_sent_op(op) do
    assert_receive {:transport_sent, payload}
    frame = Jason.decode!(payload)
    assert frame["op"] == op
    frame
  end

  defp connect_to_ready(pid) do
    assert_receive {:transport_connect, _parts}
    fake(pid, :upgraded)
    hello(pid)
    identify = assert_sent_op(2)

    dispatch(
      pid,
      "READY",
      %{
        "session_id" => "sess-1",
        "resume_gateway_url" => "wss://resume.example"
      },
      1
    )

    assert_receive {:discord_socket, :ready}
    assert_receive {:event, %{"t" => "READY"}}
    identify
  end

  test "connects to the versioned gateway URL, identifies, reaches ready" do
    pid = start_socket!()

    assert_receive {:transport_connect, parts}

    assert parts == %{
             scheme: :wss,
             host: "gateway.discord.gg",
             port: 443,
             path: "/?v=10&encoding=json"
           }

    fake(pid, :upgraded)
    hello(pid)

    identify = assert_sent_op(2)
    assert identify["d"]["token"] == "bot-token"
    assert identify["d"]["intents"] == 37_377

    dispatch(
      pid,
      "READY",
      %{"session_id" => "s", "resume_gateway_url" => "wss://r"},
      1
    )

    assert_receive {:discord_socket, :ready}
    assert GatewaySocket.phase(pid) == :ready
  end

  test "dispatch frames reach on_event raw and advance the sequence" do
    pid = start_socket!()
    connect_to_ready(pid)

    dispatch(pid, "MESSAGE_CREATE", %{"content" => "hi"}, 5)

    assert_receive {:event, frame}
    assert frame["t"] == "MESSAGE_CREATE"
    assert frame["d"] == %{"content" => "hi"}

    send(pid, :heartbeat)
    heartbeat = assert_sent_op(1)
    assert heartbeat["d"] == 5
  end

  test "acked heartbeats keep beating; a missed ack forces resume" do
    pid = start_socket!()
    connect_to_ready(pid)

    send(pid, :heartbeat)
    assert_sent_op(1)
    text(pid, %{op: 11})

    send(pid, :heartbeat)
    assert_sent_op(1)

    # No ack this time: the next beat declares the connection a zombie.
    log =
      capture_log(fn ->
        send(pid, :heartbeat)
        assert_receive :transport_closed
      end)

    assert log =~ "zombie"
    assert_receive {:discord_socket, {:disconnected, :zombie}}
    assert_receive {:discord_socket, {:reconnecting, 1, _delay}}

    # Reconnect goes to the resume URL and resumes the session.
    assert_receive {:transport_connect, %{host: "resume.example"}}
    fake(pid, :upgraded)
    hello(pid)

    resume = assert_sent_op(6)
    assert resume["d"]["session_id"] == "sess-1"
    assert resume["d"]["seq"] == 1

    dispatch(pid, "RESUMED", %{}, 2)
    assert_receive {:discord_socket, :ready}
    assert GatewaySocket.phase(pid) == :ready
  end

  test "an unresumable invalid session re-identifies from the base URL" do
    pid = start_socket!()
    connect_to_ready(pid)

    text(pid, %{op: 9, d: false})
    assert_receive :transport_closed
    assert_receive {:discord_socket, {:reconnecting, 1, _delay}}

    assert_receive {:transport_connect, %{host: "gateway.discord.gg"}}
    fake(pid, :upgraded)
    hello(pid)

    assert_sent_op(2)
  end

  test "a server heartbeat request gets an immediate beat" do
    pid = start_socket!()
    connect_to_ready(pid)

    text(pid, %{op: 1})
    heartbeat = assert_sent_op(1)
    assert heartbeat["d"] == 1
  end

  test "a crashing on_event is logged and does not kill the socket" do
    test_pid = self()

    pid =
      start_socket!(
        on_event: fn
          %{"t" => "MESSAGE_CREATE"} -> raise "sink exploded"
          frame -> send(test_pid, {:event, frame})
        end
      )

    connect_to_ready(pid)

    log =
      capture_log(fn ->
        dispatch(pid, "MESSAGE_CREATE", %{"content" => "boom"}, 9)
        dispatch(pid, "TYPING_START", %{}, 10)
        assert_receive {:event, %{"t" => "TYPING_START"}}
      end)

    assert log =~ "sink exploded"
    assert GatewaySocket.phase(pid) == :ready
  end

  test "a transport stream error tears down and reconnects" do
    pid = start_socket!()
    connect_to_ready(pid)

    log =
      capture_log(fn ->
        fake(pid, {:stream_error, :econnreset})
        assert_receive :transport_closed
      end)

    assert log =~ "econnreset"
    assert_receive {:discord_socket, {:disconnected, {:transport, :econnreset}}}
    assert_receive {:transport_connect, _parts}
  end

  test "a server close frame tears down and reconnects" do
    pid = start_socket!()
    connect_to_ready(pid)

    capture_log(fn ->
      fake(pid, {:close, 4000, "unknown error"})
      assert_receive :transport_closed
      assert_receive {:discord_socket, {:disconnected, {:ws_close, 4000, _}}}
      assert_receive {:transport_connect, _parts}
    end)
  end

  test "a failed connect backs off and retries" do
    log =
      capture_log(fn ->
        start_socket!(transport_opts: [owner: self(), fail_connect: :nxdomain])

        assert_receive {:transport_connect, _parts}
        assert_receive {:discord_socket, {:reconnecting, 1, _delay}}
        assert_receive {:transport_connect, _parts}
        assert_receive {:discord_socket, {:reconnecting, 2, _delay}}
      end)

    assert log =~ "nxdomain"
  end

  test "close/1 tears down gracefully" do
    pid = start_socket!()
    connect_to_ready(pid)

    ref = Process.monitor(pid)
    GatewaySocket.close(pid)

    assert_receive :transport_closed
    assert_receive {:discord_socket, {:disconnected, :closed_by_us}}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end
end
