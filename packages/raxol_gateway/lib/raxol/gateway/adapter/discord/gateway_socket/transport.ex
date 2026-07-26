defmodule Raxol.Gateway.Adapter.Discord.GatewaySocket.Transport do
  @moduledoc """
  The wire seam under `Raxol.Gateway.Adapter.Discord.GatewaySocket`.

  A transport owns the WebSocket mechanics (TCP connect, HTTP upgrade,
  frame encode/decode) and surfaces a small event vocabulary; the socket
  owns every Discord semantic (heartbeats, identify/resume, sequence
  tracking). `MintTransport` is the production implementation; tests
  inject a message-driven fake, so the full socket lifecycle is testable
  without a network or mocks.

  `connect/2` returns as soon as the upgrade request is in flight; the
  `:upgraded` event arrives later through `stream/2`, which is fed every
  process message the socket cannot interpret itself.
  """

  @type conn :: term()

  @typedoc """
  What `stream/2` can surface:

    * `:upgraded` - the HTTP 101 completed; the WebSocket is open
    * `{:text, payload}` - one inbound text frame
    * `{:close, code, reason}` - the server closed the WebSocket
    * `{:transport_error, reason}` - the connection is unusable
  """
  @type event ::
          :upgraded
          | {:text, String.t()}
          | {:close, term(), term()}
          | {:transport_error, term()}

  @type url_parts :: %{
          scheme: :ws | :wss,
          host: String.t(),
          port: :inet.port_number(),
          path: String.t()
        }

  @callback connect(url_parts(), keyword()) :: {:ok, conn()} | {:error, term()}
  @callback stream(conn(), term()) ::
              {:ok, conn(), [event()]} | {:error, conn(), term()} | :unknown
  @callback send_text(conn(), String.t()) ::
              {:ok, conn()} | {:error, conn(), term()}
  @callback close(conn()) :: :ok
end
