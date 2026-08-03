defmodule Raxol.Earn.Seller.Backend.WebSocket.Connection do
  @moduledoc """
  GenServer that holds a single `Mint.WebSocket` connection to the
  Virtuals ACP socket and forwards decoded events to a parent process.

  ## Lifecycle

      start_link
        -> Mint.HTTP.connect
        -> Mint.WebSocket.upgrade (GET /socket.io/?EIO=4&transport=websocket)
        -> wait for HTTP 101 response (becomes :websocket_open)
        -> wait for Engine.IO OPEN packet (carries pingInterval)
        -> send Socket.IO CONNECT (with auth payload)
        -> wait for CONNECT_OK (becomes :ready)
        -> stream events to :parent
        -> on disconnect, reconnect with exponential backoff

  ## State transitions

  - `:disconnected` -- not connected; reconnect timer pending
  - `:upgrading` -- WebSocket upgrade in flight
  - `:awaiting_open` -- WebSocket open, waiting for Engine.IO OPEN
  - `:awaiting_connect_ok` -- OPEN received, CONNECT sent, waiting for ACK
  - `:ready` -- handshake complete; events flowing

  ## Messages sent to `:parent`

  - `{:acp_ws, :ready}` -- handshake complete
  - `{:acp_ws, :event, name, args, ack_id}` -- server emitted an event
  - `{:acp_ws, :disconnected, reason}` -- connection dropped
  - `{:acp_ws, :reconnecting, attempt}` -- backoff timer set

  ## Options

  - `:url` (required) -- `https://` or `wss://` URL. The path defaults
    to `/socket.io/` if absent; the `EIO=4&transport=websocket` query
    is added automatically.
  - `:auth` -- map sent as the Socket.IO CONNECT payload.
    Default `nil` (anonymous CONNECT).
  - `:parent` -- pid that receives `:acp_ws` messages.
    Default `self()`.
  - `:reconnect_base_ms` -- starting backoff window. Default `500`.
  - `:reconnect_max_ms` -- ceiling for backoff. Default `30_000`.

  ## Heartbeats

  After CONNECT_OK the server sends an Engine.IO PING (`"2"`) every
  `pingInterval` ms (from OPEN). We respond with PONG (`"3"`)
  immediately. No client-initiated pings.
  """

  use GenServer

  alias Raxol.Earn.Seller.Backend.WebSocket.Protocol

  require Logger

  @default_path "/socket.io/"
  @default_query "EIO=4&transport=websocket"

  @type opts :: [
          url: String.t(),
          auth: map() | nil,
          parent: pid(),
          reconnect_base_ms: pos_integer(),
          reconnect_max_ms: pos_integer()
        ]

  defstruct [
    :url,
    :scheme,
    :host,
    :port,
    :path,
    :auth,
    :parent,
    :reconnect_base_ms,
    :reconnect_max_ms,
    :conn,
    :ws,
    :request_ref,
    :ping_interval_ms,
    phase: :disconnected,
    reconnect_attempts: 0
  ]

  # -- Public API --

  @spec start_link(opts()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Synchronously fetch the current phase. Mostly for tests.
  """
  @spec phase(GenServer.server()) :: atom()
  def phase(server), do: GenServer.call(server, :phase)

  @doc """
  Gracefully close the Socket.IO session and shut down the connection.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server), do: GenServer.cast(server, :close)

  # -- GenServer callbacks --

  @impl true
  def init(opts) do
    url = Keyword.fetch!(opts, :url)
    {scheme, host, port, path} = parse_url(url)

    state = %__MODULE__{
      url: url,
      scheme: scheme,
      host: host,
      port: port,
      path: path,
      auth: Keyword.get(opts, :auth),
      parent: Keyword.get(opts, :parent, self()),
      reconnect_base_ms: Keyword.get(opts, :reconnect_base_ms, 500),
      reconnect_max_ms: Keyword.get(opts, :reconnect_max_ms, 30_000)
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    {:noreply, attempt_connect(state)}
  end

  @impl true
  def handle_call(:phase, _from, state), do: {:reply, state.phase, state}

  @impl true
  def handle_cast(:close, state) do
    state = send_frame(state, Protocol.encode_disconnect())
    state = teardown(state, :closed_by_us)
    {:stop, :normal, state}
  end

  # All TCP/SSL traffic for the Mint connection arrives as messages.
  @impl true
  def handle_info(msg, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, msg) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        {:noreply, Enum.reduce(reorder_upgrade(responses), state, &handle_response/2)}

      {:error, conn, %Mint.TransportError{reason: reason}, _responses} ->
        Logger.warning("[acp.ws] transport error: #{inspect(reason)}")
        state = %{state | conn: conn}
        {:noreply, schedule_reconnect(teardown(state, {:transport, reason}))}

      {:error, conn, error, _responses} ->
        Logger.warning("[acp.ws] mint error: #{inspect(error)}")
        state = %{state | conn: conn}
        {:noreply, schedule_reconnect(teardown(state, {:mint, error}))}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(:reconnect, state), do: {:noreply, attempt_connect(state)}

  def handle_info(other, state) do
    Logger.debug("[acp.ws] unexpected message: #{inspect(other)}")
    {:noreply, state}
  end

  # -- Connect path --

  defp attempt_connect(state) do
    case do_connect(state) do
      {:ok, state} ->
        %{state | phase: :upgrading, reconnect_attempts: 0}

      {:error, reason} ->
        Logger.warning("[acp.ws] connect failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  defp do_connect(state) do
    http_scheme = if state.scheme == :wss, do: :https, else: :http
    ws_scheme = state.scheme

    with {:ok, conn} <-
           Mint.HTTP.connect(http_scheme, state.host, state.port, protocols: [:http1]),
         path = state.path <> "?" <> @default_query,
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(ws_scheme, conn, path, []) do
      {:ok, %{state | conn: conn, request_ref: ref}}
    end
  end

  # -- Mint stream responses --

  defp handle_response({:status, ref, status}, %{request_ref: ref} = state) do
    %{state | conn: Mint.HTTP.put_private(state.conn, :status, status)}
  end

  defp handle_response({:headers, ref, headers}, %{request_ref: ref} = state) do
    %{state | conn: Mint.HTTP.put_private(state.conn, :resp_headers, headers)}
  end

  defp handle_response({:done, ref}, %{request_ref: ref} = state) do
    status = Mint.HTTP.get_private(state.conn, :status)
    headers = Mint.HTTP.get_private(state.conn, :resp_headers) || []

    case Mint.WebSocket.new(state.conn, ref, status, headers) do
      {:ok, conn, ws} ->
        notify(state, :upgraded)
        %{state | conn: conn, ws: ws, phase: :awaiting_open}

      {:error, conn, reason} ->
        Logger.warning("[acp.ws] upgrade failed: #{inspect(reason)}")
        %{state | conn: conn} |> teardown({:upgrade_failed, reason}) |> schedule_reconnect()
    end
  end

  defp handle_response({:data, ref, data}, %{request_ref: ref, ws: ws} = state)
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} ->
        state = %{state | ws: ws}
        Enum.reduce(frames, state, &handle_frame/2)

      {:error, ws, reason} ->
        Logger.warning("[acp.ws] frame decode error: #{inspect(reason)}")
        %{state | ws: ws} |> teardown({:decode, reason}) |> schedule_reconnect()
    end
  end

  defp handle_response(_other, state), do: state

  # Mint sometimes emits `[:status, :headers, :data, :done]` when a 101
  # upgrade and the first server WebSocket frame arrive in the same TCP
  # segment. The `:data` is post-upgrade bytes that have to be decoded
  # with the WebSocket conn that `:done` creates -- if processed first,
  # `ws` is still nil and the bytes are dropped. Reorder so all
  # HTTP-level responses precede any `:data`.
  defp reorder_upgrade(responses) do
    {data, http} =
      Enum.split_with(responses, fn
        {:data, _ref, _bytes} -> true
        _ -> false
      end)

    http ++ data
  end

  # -- WebSocket frames --

  defp handle_frame({:text, payload}, state) do
    case Protocol.decode(payload) do
      {:open, info} ->
        ping = info["pingInterval"] || 25_000
        state = %{state | phase: :awaiting_connect_ok, ping_interval_ms: ping}
        send_frame(state, Protocol.encode_connect(state.auth))

      {:connect_ok, _info} ->
        state = %{state | phase: :ready}
        notify(state, :ready)
        state

      {:event, name, args, ack_id} ->
        notify(state, {:event, name, args, ack_id})
        state

      :ping ->
        send_frame(state, Protocol.encode_pong())

      :disconnect ->
        teardown(state, :server_disconnect) |> schedule_reconnect()

      :close ->
        teardown(state, :server_close) |> schedule_reconnect()

      {:connect_error, reason} ->
        Logger.warning("[acp.ws] connect_error: #{inspect(reason)}")
        teardown(state, {:connect_error, reason}) |> schedule_reconnect()

      {:unknown, raw} ->
        Logger.debug("[acp.ws] unknown frame: #{inspect(raw)}")
        state
    end
  end

  defp handle_frame({:close, code, reason}, state) do
    Logger.debug("[acp.ws] websocket closed: #{inspect(code)} #{inspect(reason)}")
    teardown(state, {:ws_close, code, reason}) |> schedule_reconnect()
  end

  defp handle_frame(_other, state), do: state

  # -- Send + reconnect helpers --

  defp send_frame(%{ws: nil} = state, _payload), do: state

  defp send_frame(state, payload) do
    {:ok, ws, data} = Mint.WebSocket.encode(state.ws, {:text, payload})

    case Mint.WebSocket.stream_request_body(state.conn, state.request_ref, data) do
      {:ok, conn} ->
        %{state | conn: conn, ws: ws}

      {:error, conn, reason} ->
        Logger.warning("[acp.ws] send failed: #{inspect(reason)}")
        %{state | conn: conn, ws: ws} |> teardown({:send, reason}) |> schedule_reconnect()
    end
  end

  defp teardown(state, reason) do
    notify(state, {:disconnected, reason})

    if state.conn, do: Mint.HTTP.close(state.conn)

    %{state | conn: nil, ws: nil, request_ref: nil, phase: :disconnected}
  end

  defp schedule_reconnect(state) do
    attempt = state.reconnect_attempts + 1
    delay = backoff(attempt, state.reconnect_base_ms, state.reconnect_max_ms)
    Process.send_after(self(), :reconnect, delay)
    notify(state, {:reconnecting, attempt, delay})
    %{state | reconnect_attempts: attempt}
  end

  defp backoff(attempt, base, max) do
    base
    |> Bitwise.bsl(min(attempt - 1, 16))
    |> min(max)
  end

  defp notify(state, payload), do: send(state.parent, {:acp_ws, payload})

  # -- URL parsing --

  defp parse_url(url) do
    uri = URI.parse(url)

    scheme =
      case uri.scheme do
        "wss" -> :wss
        "https" -> :wss
        "ws" -> :ws
        "http" -> :ws
        other -> raise ArgumentError, "unsupported scheme: #{inspect(other)}"
      end

    port = uri.port || default_port(scheme)
    path = uri.path || @default_path
    {scheme, uri.host, port, path}
  end

  defp default_port(:wss), do: 443
  defp default_port(:ws), do: 80
end
