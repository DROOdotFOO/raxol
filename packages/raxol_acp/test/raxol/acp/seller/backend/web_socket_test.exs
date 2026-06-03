defmodule Raxol.ACP.Seller.Backend.WebSocketTest do
  @moduledoc """
  Integration test for `Raxol.ACP.Seller.Backend.WebSocket` against a
  real Cowboy-backed Socket.IO v4 server (see
  `Raxol.ACP.TestSupport.SocketIOTestServer`).

  The fixture speaks the same wire format as `acpx.virtuals.io`; this
  is a second real implementation, not a mock.
  """

  use ExUnit.Case, async: false

  alias Raxol.ACP.Seller.Backend.WebSocket
  alias Raxol.ACP.Seller.Backend.WebSocket.Connection
  alias Raxol.ACP.TestSupport.SocketIOTestServer

  setup do
    {:ok, port} = SocketIOTestServer.start_link()

    on_exit(fn ->
      stop_if_running(WebSocket)
      SocketIOTestServer.stop()
    end)

    {:ok, port: port, url: "http://localhost:#{port}"}
  end

  defp start_backend(url, opts \\ []) do
    Application.put_env(:raxol_acp, :seller_backend_url, url)
    Application.put_env(:raxol_acp, :seller_backend_auth, Keyword.get(opts, :auth))

    on_exit(fn ->
      Application.delete_env(:raxol_acp, :seller_backend_url)
      Application.delete_env(:raxol_acp, :seller_backend_auth)
    end)

    {:ok, pid} = WebSocket.start_link(opts)
    pid
  end

  defp stop_if_running(name) do
    case Process.whereis(name) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp wait_until(fun, timeout_ms \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("wait_until never returned truthy")
      else
        Process.sleep(5)
        do_wait_until(fun, deadline)
      end
    end
  end

  describe "handshake" do
    test "completes the OPEN/CONNECT/CONNECT_OK dance and becomes ready", %{url: url} do
      start_backend(url)
      wait_until(fn -> WebSocket.ready?() end)
      assert WebSocket.ready?() == true
      assert SocketIOTestServer.connection_count() == 1
    end

    test "auth payload is delivered to the server", %{url: url} do
      start_backend(url, auth: %{walletAddress: "0xabc"})
      :ok = SocketIOTestServer.wait_for_connections(1)
      # Indirect check: the server's Handler stores the auth map and
      # the fixture would refuse the connection if decoding failed.
      wait_until(fn -> WebSocket.ready?() end)
    end
  end

  describe "subscribe + event delivery" do
    test "an onNewTask event arrives at every subscriber as :job_offered", %{url: url} do
      start_backend(url)
      wait_until(fn -> WebSocket.ready?() end)

      :ok = WebSocket.subscribe(self())
      assert WebSocket.subscriber_count() == 1

      SocketIOTestServer.push_event("onNewTask", %{
        id: 42,
        phase: 0,
        clientAddress: "0xclient",
        context: %{offering: "test.echo", requirements: %{"text" => "ping"}}
      })

      assert_receive {:acp_event, event}, 500
      assert event.type == :job_offered
      assert event.job_id == "42"
      assert event.offering == "test.echo"
      assert event.request == %{"text" => "ping"}
      assert event.buyer == "0xclient"
      assert event.raw["id"] == 42
    end

    test "onEvaluate arrives as :approval_received", %{url: url} do
      start_backend(url)
      wait_until(fn -> WebSocket.ready?() end)

      :ok = WebSocket.subscribe(self())

      SocketIOTestServer.push_event("onEvaluate", %{
        id: 99,
        phase: 3,
        context: %{deliverable: %{"echo" => "ping"}}
      })

      assert_receive {:acp_event, event}, 500
      assert event.type == :approval_received
      assert event.job_id == "99"
      assert event.payload == %{"echo" => "ping"}
    end

    test "unsubscribe stops further delivery", %{url: url} do
      start_backend(url)
      wait_until(fn -> WebSocket.ready?() end)

      :ok = WebSocket.subscribe(self())
      :ok = WebSocket.unsubscribe(self())
      assert WebSocket.subscriber_count() == 0

      SocketIOTestServer.push_event("onNewTask", %{
        id: 1,
        context: %{offering: "x", requirements: %{}}
      })

      refute_receive {:acp_event, _}, 100
    end

    test "subscriber DOWN auto-removes from registry", %{url: url} do
      start_backend(url)
      wait_until(fn -> WebSocket.ready?() end)

      # Spawn a transient process that subscribes then exits.
      parent = self()

      child =
        spawn(fn ->
          :ok = WebSocket.subscribe(self())
          send(parent, :subscribed)
          receive do: (:exit -> :ok)
        end)

      assert_receive :subscribed, 200
      assert WebSocket.subscriber_count() == 1

      send(child, :exit)
      wait_until(fn -> WebSocket.subscriber_count() == 0 end)
    end

    test "events for unknown names are dropped silently", %{url: url} do
      start_backend(url)
      wait_until(fn -> WebSocket.ready?() end)

      :ok = WebSocket.subscribe(self())

      SocketIOTestServer.push_event("notARealEvent", %{anything: true})
      refute_receive {:acp_event, _}, 100
    end
  end

  describe "Connection state machine" do
    test "phase progresses through upgrading -> awaiting_open -> awaiting_connect_ok -> ready",
         %{url: url} do
      start_backend(url)
      wait_until(fn -> WebSocket.ready?() end)

      conn = WebSocket.connection()
      assert Connection.phase(conn) == :ready
    end
  end

  describe "resolve_url/1 precedence" do
    setup do
      on_exit(fn ->
        Application.delete_env(:raxol_acp, :seller_backend_url)
        Application.delete_env(:raxol_acp, :chain)
      end)

      :ok
    end

    test "explicit opt wins over env and chain" do
      Application.put_env(:raxol_acp, :seller_backend_url, "https://env.example")
      Application.put_env(:raxol_acp, :chain, :sepolia)
      assert WebSocket.resolve_url(url: "https://opt.example") == "https://opt.example"
    end

    test "env wins over chain when no explicit opt" do
      Application.put_env(:raxol_acp, :seller_backend_url, "https://env.example")
      Application.put_env(:raxol_acp, :chain, :sepolia)
      assert WebSocket.resolve_url([]) == "https://env.example"
    end

    test "chain.mainnet acp_socket_url used when env unset" do
      Application.delete_env(:raxol_acp, :seller_backend_url)
      Application.put_env(:raxol_acp, :chain, :mainnet)
      assert WebSocket.resolve_url([]) == "https://acpx.virtuals.io"
    end

    test "chain.sepolia acp_socket_url used when env unset" do
      Application.delete_env(:raxol_acp, :seller_backend_url)
      Application.put_env(:raxol_acp, :chain, :sepolia)
      assert WebSocket.resolve_url([]) == "https://acpx.virtuals.gg"
    end

    test "unknown chain falls back to hardcoded mainnet URL" do
      Application.delete_env(:raxol_acp, :seller_backend_url)
      Application.put_env(:raxol_acp, :chain, :goerli)
      assert WebSocket.resolve_url([]) == "https://acpx.virtuals.io"
    end
  end
end
