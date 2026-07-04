defmodule Raxol.ACP.Seller.Backend.WebSocket.Protocol do
  @moduledoc """
  Pure functional encode/decode for the Engine.IO v4 + Socket.IO v4
  wire format, restricted to what the Virtuals ACP socket actually uses.

  Mirrors `@virtuals-protocol/acp-node@0.3.0-beta.40`'s
  `socket.io-client` configuration:

      io(acpUrl, { auth: { walletAddress }, transports: ["websocket"] })

  Forcing `transports: ["websocket"]` lets us skip the engine.io
  long-polling phase and the WebSocket upgrade handshake. We connect
  straight to `wss://host/socket.io/?EIO=4&transport=websocket` and
  speak the binary-free packet protocol over WebSocket text frames.

  ## Wire format

  Each WebSocket text frame carries one Engine.IO packet. The first
  character is the Engine.IO packet type; remaining characters are
  the packet body.

      <eio_type><body>

  Engine.IO types we handle:

  | char | type     | direction |
  |------|----------|-----------|
  | `0`  | OPEN     | recv      |
  | `1`  | CLOSE    | both      |
  | `2`  | PING     | recv      |
  | `3`  | PONG     | send      |
  | `4`  | MESSAGE  | both      |

  A MESSAGE packet (`4`) wraps a Socket.IO packet. The Socket.IO body
  is again type-prefixed:

      <sio_type><namespace>?<ack_id>?<json>

  Socket.IO types we handle:

  | char | type           |
  |------|----------------|
  | `0`  | CONNECT        |
  | `1`  | DISCONNECT     |
  | `2`  | EVENT          |
  | `3`  | ACK            |
  | `4`  | CONNECT_ERROR  |

  For v0 we only support the **default namespace** (`/`). Multi-
  namespace support adds a `<namespace>,` prefix which we don't emit
  or parse.

  ## Examples (raw frames as the server sends them)

      "0{\"sid\":\"abc\",\"pingInterval\":25000,\"pingTimeout\":20000}"  # OPEN
      "40{\"sid\":\"sock-xyz\"}"                                           # CONNECT_OK
      "42[\"onNewTask\",{\"id\":1,\"phase\":0}]"                           # EVENT, no ACK
      "421[\"onNewTask\",{\"id\":1,\"phase\":0}]"                          # EVENT, ack=1
      "2"                                                                  # PING
      "1"                                                                  # CLOSE

  And what the client emits in response:

      "40{\"walletAddress\":\"0x...\"}"   # CONNECT with auth payload
      "431[true]"                          # ACK for id=1, payload=[true]
      "3"                                  # PONG
  """

  # -- Engine.IO packet type ids (mirrors the spec) --

  @eio_open "0"
  @eio_close "1"
  @eio_ping "2"
  @eio_pong "3"
  @eio_message "4"

  # -- Socket.IO packet type ids (subtype inside MESSAGE) --

  @sio_connect "0"
  @sio_disconnect "1"
  @sio_event "2"
  @sio_ack "3"
  @sio_connect_error "4"

  @type ack_id :: non_neg_integer()
  @type event_name :: String.t()
  @type event_payload :: list()

  @type decoded ::
          {:open, map()}
          | :close
          | :ping
          | {:connect_ok, map()}
          | :disconnect
          | {:event, event_name(), event_payload(), ack_id() | nil}
          | {:ack, ack_id(), event_payload()}
          | {:connect_error, term()}
          | {:unknown, String.t()}

  @doc """
  Decode one Engine.IO text frame from the socket.

  Returns a tagged tuple per the `t:decoded/0` type. Unknown frames
  surface as `{:unknown, raw}` rather than crashing -- the caller can
  log/telemetry and keep the connection alive.
  """
  @spec decode(binary()) :: decoded()
  def decode(@eio_open <> rest) do
    case parse_json(rest) do
      {:ok, map} when is_map(map) -> {:open, map}
      _ -> {:unknown, @eio_open <> rest}
    end
  end

  def decode(@eio_close), do: :close
  def decode(@eio_close <> _), do: :close
  def decode(@eio_ping), do: :ping
  def decode(@eio_ping <> _), do: :ping
  def decode(@eio_message <> rest), do: decode_message(rest)
  def decode(other), do: {:unknown, other}

  @doc "Build a PONG frame in response to a server PING."
  @spec encode_pong() :: binary()
  def encode_pong, do: @eio_pong

  @doc """
  Build a CONNECT frame for the default namespace with an optional
  auth payload (e.g. `%{walletAddress: "0x..."}`).
  """
  @spec encode_connect(map() | nil) :: binary()
  def encode_connect(nil), do: @eio_message <> @sio_connect

  def encode_connect(auth) when is_map(auth) do
    @eio_message <> @sio_connect <> Jason.encode!(auth)
  end

  @doc """
  Build an ACK frame for a server-requested EVENT.

  `payload` is the JSON array the server will receive as the ack
  callback args (Socket.IO convention).
  """
  @spec encode_ack(ack_id(), list()) :: binary()
  def encode_ack(ack_id, payload) when is_integer(ack_id) and ack_id >= 0 and is_list(payload) do
    @eio_message <> @sio_ack <> Integer.to_string(ack_id) <> Jason.encode!(payload)
  end

  @doc """
  Build a DISCONNECT frame for the default namespace (graceful close
  of the current Socket.IO session without tearing the WebSocket).
  """
  @spec encode_disconnect() :: binary()
  def encode_disconnect, do: @eio_message <> @sio_disconnect

  # -- Internal: Socket.IO packet decoder --

  defp decode_message(@sio_connect <> rest) do
    case parse_json(rest) do
      {:ok, map} when is_map(map) -> {:connect_ok, map}
      _ -> {:unknown, @eio_message <> @sio_connect <> rest}
    end
  end

  defp decode_message(@sio_disconnect <> _), do: :disconnect
  defp decode_message(@sio_event <> rest), do: decode_event(rest)
  defp decode_message(@sio_ack <> rest), do: decode_ack_frame(rest)

  defp decode_message(@sio_connect_error <> rest) do
    case parse_json(rest) do
      {:ok, term} -> {:connect_error, term}
      :error -> {:unknown, @eio_message <> @sio_connect_error <> rest}
    end
  end

  defp decode_message(other), do: {:unknown, @eio_message <> other}

  # EVENT body is `<ack_id?><json_array>`. ack_id is an optional run of digits;
  # if present the server wants an ACK back with that id. A non-array body or
  # invalid JSON is surfaced as `{:unknown, raw}` rather than crashing the
  # connection -- a malformed frame from the server must not take the link down.
  defp decode_event(body) do
    {ack_id, json} = split_leading_digits(body)

    case parse_json(json) do
      {:ok, [name | args]} -> {:event, name, args, ack_id}
      _ -> {:unknown, @eio_message <> @sio_event <> body}
    end
  end

  defp decode_ack_frame(body) do
    {ack_id, json} = split_leading_digits(body)

    case {ack_id, parse_json(json)} do
      {id, {:ok, payload}} when is_integer(id) and is_list(payload) -> {:ack, id, payload}
      _ -> {:unknown, @eio_message <> @sio_ack <> body}
    end
  end

  defp split_leading_digits(body) do
    case Regex.run(~r/^(\d+)(.*)$/s, body) do
      [_, digits, rest] -> {String.to_integer(digits), rest}
      _ -> {nil, body}
    end
  end

  # Tolerant JSON parse. An empty body is the empty object (Socket.IO sends
  # bodyless CONNECT/ACK frames); anything unparseable is `:error` so the caller
  # can surface `{:unknown, raw}` instead of raising.
  defp parse_json(""), do: {:ok, %{}}

  defp parse_json(json) do
    case Jason.decode(json) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> :error
    end
  end
end
