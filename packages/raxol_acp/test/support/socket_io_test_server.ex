defmodule Raxol.ACP.TestSupport.SocketIOTestServer do
  @moduledoc """
  Minimal Engine.IO v4 + Socket.IO v4 server for integration testing
  `Raxol.ACP.Seller.Backend.WebSocket`.

  Not a mock -- a real second implementation of the wire protocol. The
  Connection talks to this exactly the way it would talk to
  `acpx.virtuals.io`.

  ## What it implements

  - The WebSocket-only Engine.IO transport (`?transport=websocket`)
  - Server-initiated OPEN packet on connect
  - Socket.IO CONNECT / CONNECT_OK handshake (with optional auth payload)
  - Server-initiated EVENT packets via `push_event/3`
  - PING/PONG heartbeat -- the server pings every `:ping_interval_ms`
    and expects a PONG within `:ping_timeout_ms` (loose enforcement)
  - ACK frames sent in response to EVENTs with ack ids

  Each connection corresponds to one Cowboy WebSocket handler process.
  The handler registers itself under `__MODULE__` (via Process group)
  so tests can address it without knowing the pid.

  ## Test usage

      {:ok, port} = SocketIOTestServer.start_link()
      url = "http://localhost:\#{port}"

      # ... start the client ...

      SocketIOTestServer.push_event("onNewTask", %{id: 1, phase: 0})
  """

  use GenServer

  @path "/socket.io"
  @ping_interval_ms 25_000
  @ping_timeout_ms 20_000

  defstruct port: nil, listener_ref: nil, handlers: MapSet.new()

  # -- Public API --

  @spec start_link(keyword()) :: {:ok, pos_integer()} | {:error, term()}
  def start_link(opts \\ []) do
    # Synchronously kill any previous instance so the cowboy listener
    # is torn down before we try to bind a new socket. Without this
    # tests racing through setup leave half-closed listeners around
    # and the new connection times out mid-handshake.
    stop()

    case GenServer.start_link(__MODULE__, opts, name: __MODULE__) do
      {:ok, _pid} -> {:ok, GenServer.call(__MODULE__, :port)}
      other -> other
    end
  end

  @spec stop() :: :ok
  def stop do
    case Process.whereis(__MODULE__) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)

        try do
          GenServer.stop(pid, :normal, 1_000)
        catch
          :exit, _ -> :ok
        end

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 -> :ok
        end
    end
  end

  @doc """
  Push an event into every currently-connected client. Returns the
  number of clients that received it.
  """
  @spec push_event(String.t(), term(), keyword()) :: non_neg_integer()
  def push_event(name, payload, opts \\ []) do
    GenServer.call(__MODULE__, {:push_event, name, payload, opts})
  end

  @doc "Count active connections (post-CONNECT_OK)."
  @spec connection_count() :: non_neg_integer()
  def connection_count, do: GenServer.call(__MODULE__, :connection_count)

  @doc """
  Block until at least `count` handlers are connected, or fail after
  `timeout_ms`. Returns `:ok` on success.
  """
  @spec wait_for_connections(non_neg_integer(), pos_integer()) :: :ok | {:error, :timeout}
  def wait_for_connections(count, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_connections(count, deadline)
  end

  defp do_wait_for_connections(count, deadline) do
    if connection_count() >= count do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        {:error, :timeout}
      else
        Process.sleep(5)
        do_wait_for_connections(count, deadline)
      end
    end
  end

  @doc false
  # Called by the Cowboy handler when it accepts a Socket.IO CONNECT.
  def register_handler(pid), do: GenServer.cast(__MODULE__, {:register, pid})

  @doc false
  def deregister_handler(pid), do: GenServer.cast(__MODULE__, {:deregister, pid})

  @doc "Return the OPEN packet defaults the server advertises."
  def open_defaults do
    %{
      sid: "test-sid",
      upgrades: [],
      pingInterval: @ping_interval_ms,
      pingTimeout: @ping_timeout_ms
    }
  end

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {@path <> "/[...]", __MODULE__.Handler, []}
         ]}
      ])

    port = Keyword.get(opts, :port, 0)
    ref = make_ref()

    {:ok, _listener_pid} =
      :cowboy.start_clear(
        ref,
        [{:port, port}],
        %{env: %{dispatch: dispatch}}
      )

    actual_port = :ranch.get_port(ref)

    {:ok, %__MODULE__{port: actual_port, listener_ref: ref}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  def handle_call(:connection_count, _from, state),
    do: {:reply, MapSet.size(state.handlers), state}

  def handle_call({:push_event, name, payload, opts}, _from, state) do
    ack_id = Keyword.get(opts, :ack_id)
    count = 0

    final_count =
      Enum.reduce(state.handlers, count, fn pid, acc ->
        send(pid, {:server_event, name, payload, ack_id})
        acc + 1
      end)

    {:reply, final_count, state}
  end

  @impl true
  def handle_cast({:register, pid}, state) do
    Process.monitor(pid)
    {:noreply, %{state | handlers: MapSet.put(state.handlers, pid)}}
  end

  def handle_cast({:deregister, pid}, state),
    do: {:noreply, %{state | handlers: MapSet.delete(state.handlers, pid)}}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, %{state | handlers: MapSet.delete(state.handlers, pid)}}

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{listener_ref: ref}) when not is_nil(ref) do
    :cowboy.stop_listener(ref)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
