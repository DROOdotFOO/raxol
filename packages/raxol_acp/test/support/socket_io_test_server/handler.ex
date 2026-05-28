defmodule Raxol.ACP.TestSupport.SocketIOTestServer.Handler do
  @moduledoc """
  Cowboy WebSocket handler implementing the server side of the
  Engine.IO v4 + Socket.IO v4 wire format that
  `Raxol.ACP.TestSupport.SocketIOTestServer` exposes.

  Lifecycle inside one connection:

      init             -> :cowboy_websocket (upgrade)
      websocket_init   -> push OPEN packet, schedule first ping
      CONNECT (from client)    -> register, push CONNECT_OK
      :server_event (from test) -> push EVENT (with optional ack id)
      :ping_tick (timer)       -> push PING
      client ACK / PONG / DISCONNECT -> noop / state update / close
  """

  @behaviour :cowboy_websocket

  alias Raxol.ACP.Seller.Backend.WebSocket.Protocol
  alias Raxol.ACP.TestSupport.SocketIOTestServer

  defstruct connected?: false, auth: nil

  # -- :cowboy_websocket callbacks --

  @impl true
  def init(req, _state) do
    {:cowboy_websocket, req, %__MODULE__{}}
  end

  @impl true
  def websocket_init(state) do
    defaults = SocketIOTestServer.open_defaults()
    open_frame = "0" <> Jason.encode!(defaults)
    schedule_ping(defaults.pingInterval)
    {[{:text, open_frame}], state}
  end

  @impl true
  def websocket_handle({:text, payload}, state) do
    case Protocol.decode(payload) do
      {:connect_ok, auth_map} ->
        SocketIOTestServer.register_handler(self())

        ok = "40" <> Jason.encode!(%{sid: "sock-" <> random_id()})
        {[{:text, ok}], %{state | connected?: true, auth: auth_map}}

      :ping ->
        {[{:text, "3"}], state}

      :disconnect ->
        SocketIOTestServer.deregister_handler(self())
        {[:close], state}

      _other ->
        {[], state}
    end
  end

  def websocket_handle(_other, state), do: {[], state}

  @impl true
  def websocket_info({:server_event, name, payload, nil}, state) do
    body = Jason.encode!([name, payload])
    {[{:text, "42" <> body}], state}
  end

  def websocket_info({:server_event, name, payload, ack_id}, state)
      when is_integer(ack_id) do
    body = Jason.encode!([name, payload])
    {[{:text, "42" <> Integer.to_string(ack_id) <> body}], state}
  end

  def websocket_info(:ping_tick, state) do
    schedule_ping(SocketIOTestServer.open_defaults().pingInterval)
    {[{:text, "2"}], state}
  end

  def websocket_info({:push_text, raw}, state), do: {[{:text, raw}], state}

  def websocket_info(:server_disconnect, state) do
    SocketIOTestServer.deregister_handler(self())
    {[{:text, "41"}, :close], state}
  end

  def websocket_info(_other, state), do: {[], state}

  @impl true
  def terminate(_reason, _req, _state) do
    SocketIOTestServer.deregister_handler(self())
    :ok
  end

  # -- Helpers --

  defp schedule_ping(interval_ms) do
    Process.send_after(self(), :ping_tick, interval_ms)
  end

  defp random_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
end
