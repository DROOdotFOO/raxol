defmodule Raxol.Gateway.Adapter.Discord.GatewaySocket.MintTransport do
  @moduledoc """
  `Mint.WebSocket`-backed transport for the Discord gateway socket.

  Requires the optional `:mint_web_socket` dependency; `connect/2` returns
  `{:error, :mint_web_socket_not_loaded}` without it. WebSocket-level pings
  are answered here (pong) and never surface as events; Discord's
  application-level heartbeats are the socket's concern.
  """

  @behaviour Raxol.Gateway.Adapter.Discord.GatewaySocket.Transport

  @compile {:no_warn_undefined, [Mint.HTTP, Mint.WebSocket]}

  @impl true
  def connect(%{scheme: scheme, host: host, port: port, path: path}, _opts) do
    if Code.ensure_loaded?(Mint.WebSocket) do
      http_scheme = if scheme == :wss, do: :https, else: :http

      with {:ok, conn} <-
             Mint.HTTP.connect(http_scheme, host, port, protocols: [:http1]),
           {:ok, conn, ref} <- Mint.WebSocket.upgrade(scheme, conn, path, []) do
        {:ok, %{conn: conn, ws: nil, ref: ref, status: nil, headers: []}}
      else
        {:error, reason} -> {:error, reason}
        {:error, _conn, reason} -> {:error, reason}
      end
    else
      {:error, :mint_web_socket_not_loaded}
    end
  end

  @impl true
  def stream(%{conn: conn} = transport, msg) do
    case Mint.WebSocket.stream(conn, msg) do
      {:ok, conn, responses} ->
        {transport, events} =
          responses
          |> reorder_upgrade()
          |> Enum.reduce({%{transport | conn: conn}, []}, &collect_response/2)

        {:ok, transport, Enum.reverse(events)}

      {:error, conn, error, _responses} ->
        {:error, %{transport | conn: conn}, error}

      :unknown ->
        :unknown
    end
  end

  @impl true
  def send_text(%{ws: nil} = transport, _payload),
    do: {:error, transport, :websocket_not_open}

  def send_text(transport, payload) do
    {:ok, ws, data} = Mint.WebSocket.encode(transport.ws, {:text, payload})
    transport = %{transport | ws: ws}

    case Mint.WebSocket.stream_request_body(transport.conn, transport.ref, data) do
      {:ok, conn} -> {:ok, %{transport | conn: conn}}
      {:error, conn, reason} -> {:error, %{transport | conn: conn}, reason}
    end
  end

  @impl true
  def close(%{conn: nil}), do: :ok

  def close(%{conn: conn}) do
    Mint.HTTP.close(conn)
    :ok
  end

  # Mint sometimes emits `[:status, :headers, :data, :done]` when the 101
  # upgrade and the first server frame arrive in the same TCP segment. The
  # `:data` is post-upgrade bytes that need the WebSocket conn `:done`
  # creates - processed first, `ws` is still nil and the bytes are dropped.
  defp reorder_upgrade(responses) do
    {data, http} =
      Enum.split_with(responses, fn
        {:data, _ref, _bytes} -> true
        _other -> false
      end)

    http ++ data
  end

  defp collect_response({:status, ref, status}, {%{ref: ref} = t, events}),
    do: {%{t | status: status}, events}

  defp collect_response({:headers, ref, headers}, {%{ref: ref} = t, events}),
    do: {%{t | headers: headers}, events}

  defp collect_response({:done, ref}, {%{ref: ref} = t, events}) do
    case Mint.WebSocket.new(t.conn, ref, t.status, t.headers) do
      {:ok, conn, ws} ->
        {%{t | conn: conn, ws: ws}, [:upgraded | events]}

      {:error, conn, reason} ->
        {%{t | conn: conn}, [{:transport_error, {:upgrade_failed, reason}} | events]}
    end
  end

  defp collect_response({:data, ref, data}, {%{ref: ref, ws: ws} = t, events})
       when not is_nil(ws) do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} ->
        Enum.reduce(frames, {%{t | ws: ws}, events}, &collect_frame/2)

      {:error, ws, reason} ->
        {%{t | ws: ws}, [{:transport_error, {:decode, reason}} | events]}
    end
  end

  defp collect_response(_other, acc), do: acc

  defp collect_frame({:text, payload}, {t, events}),
    do: {t, [{:text, payload} | events]}

  defp collect_frame({:close, code, reason}, {t, events}),
    do: {t, [{:close, code, reason} | events]}

  defp collect_frame({:ping, data}, {t, events}) do
    case pong(t, data) do
      {:ok, t} -> {t, events}
      {:error, t, reason} -> {t, [{:transport_error, {:pong, reason}} | events]}
    end
  end

  defp collect_frame(_other, acc), do: acc

  defp pong(transport, data) do
    {:ok, ws, bytes} = Mint.WebSocket.encode(transport.ws, {:pong, data})
    transport = %{transport | ws: ws}

    case Mint.WebSocket.stream_request_body(
           transport.conn,
           transport.ref,
           bytes
         ) do
      {:ok, conn} -> {:ok, %{transport | conn: conn}}
      {:error, conn, reason} -> {:error, %{transport | conn: conn}, reason}
    end
  end
end
