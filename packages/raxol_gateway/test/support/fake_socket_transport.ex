defmodule Raxol.Gateway.Test.FakeSocketTransport do
  @moduledoc """
  Message-driven `GatewaySocket.Transport` for tests.

  The test owns the wire: it learns about connects via
  `{:transport_connect, url_parts}` sent to the `:owner` pid, then drives
  the socket by sending it `{:fake_transport, event}` messages
  (`:upgraded`, `{:text, json}`, `{:close, code, reason}`,
  `{:transport_error, reason}`). Everything the socket sends comes back to
  the owner as `{:transport_sent, payload}`; teardown arrives as
  `:transport_closed`. `{:fake_transport, {:stream_error, reason}}` makes
  `stream/2` return an error tuple, exercising the transport-failure path.

  Setting `:fail_connect` in the transport opts makes every `connect/2`
  attempt fail with that reason.
  """

  @behaviour Raxol.Gateway.Adapter.Discord.GatewaySocket.Transport

  @impl true
  def connect(url_parts, opts) do
    owner = Keyword.fetch!(opts, :owner)
    send(owner, {:transport_connect, url_parts})

    case Keyword.get(opts, :fail_connect) do
      nil -> {:ok, %{owner: owner}}
      reason -> {:error, reason}
    end
  end

  @impl true
  def stream(conn, {:fake_transport, {:stream_error, reason}}),
    do: {:error, conn, reason}

  def stream(conn, {:fake_transport, event}), do: {:ok, conn, [event]}
  def stream(_conn, _msg), do: :unknown

  @impl true
  def send_text(conn, payload) do
    send(conn.owner, {:transport_sent, payload})
    {:ok, conn}
  end

  @impl true
  def close(conn) do
    send(conn.owner, :transport_closed)
    :ok
  end
end
