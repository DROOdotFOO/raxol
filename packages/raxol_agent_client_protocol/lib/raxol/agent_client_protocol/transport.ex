defmodule Raxol.AgentClientProtocol.Transport do
  @moduledoc """
  Behaviour for pluggable ACP message carriers.

  A transport moves *decoded* JSON-RPC frames (Elixir maps — already
  parsed, or for in-process transports never serialized at all) between a
  local process (the "owner") and a peer. `Raxol.AgentClientProtocol.Connection`
  is transport-agnostic: it only ever calls `send_message/2` and `close/1`,
  and receives inbound traffic as plain messages (documented below).
  Concrete transports:

    * `Raxol.AgentClientProtocol.Transport.Paired` — an in-process pair of
      handles used as the test backbone and for BEAM-local agent/client
      wiring. No JSON encode/decode: maps pass straight through. Byte-level
      codec correctness (encoding, framing, partial reads) is exercised by
      the stdio transport instead, not here.
    * a future `Raxol.AgentClientProtocol.Transport.Stdio` — newline-
      delimited JSON over stdin/stdout.

  ## Ownership

  Every transport handle has an *owner* process — the process that
  receives its inbound traffic. Constructors may leave the owner unset
  (`nil`) so a supervisor can create transports before the `Connection`
  process that will adopt them exists; call the concrete transport's
  `set_owner/2` (where implemented) to adopt a pre-created handle.

  ## Inbound delivery contract

  A transport delivers inbound frames to its owner as plain messages —
  never as a callback, since a transport does not know its owner's
  module. The owner should expect exactly these two message shapes:

    * `{:acp_transport, transport_ref, {:message, message}}` — one
      complete, decoded JSON-RPC frame (request, response, or
      notification) arrived from the peer. `message` is a map.
    * `{:acp_transport, transport_ref, {:closed, reason}}` — the
      transport will deliver no further messages. `reason` is an atom or
      term describing why (e.g. `:peer_closed`, `:local_close`,
      `{:error, term}`).

  `transport_ref` identifies *which* transport handle the message belongs
  to. It is opaque to the owner and should only be compared with `==/2`,
  never pattern-matched into — an owner that multiplexes several
  transports uses it to tell them apart.

  ## Delivery guarantees

  Implementations of this behaviour MUST provide:

    * **Ordering** — messages sent via consecutive `send_message/2` calls
      from a single caller process arrive at the peer's owner in the same
      order they were sent.
    * **Reliability** — `send_message/2` returning `{:ok, state}` means
      the transport has accepted the message for delivery; it does not
      guarantee the peer has *processed* it, but the transport must not
      silently drop an accepted message short of `close/1` or peer death.
    * **Duplex** — both ends may send at any time, independently and
      concurrently; a transport must not require request/response
      turn-taking.

  Implementations MAY be lossy or reorder frames only after `close/1` has
  been called on either end, at which point `{:error, :closed}` (or a
  `{:closed, reason}` delivery) is the expected observable behaviour
  instead of silent loss.
  """

  @typedoc "The process that receives a transport's inbound `{:acp_transport, ...}` messages."
  @type owner :: pid()

  @typedoc "Opaque identifier for a transport handle, included in every inbound delivery."
  @type transport_ref :: term()

  @typedoc "Transport-implementation-defined handle/state threaded through the callbacks."
  @type state :: term()

  @doc """
  Send one decoded JSON-RPC frame (a map) to the peer.

  Returns `{:ok, state}` (the possibly-updated transport state) on
  successful hand-off, or `{:error, reason}` if the transport cannot
  accept the message (e.g. `:closed`).
  """
  @callback send_message(state(), map()) :: {:ok, state()} | {:error, term()}

  @doc """
  Close the transport.

  Idempotent: closing an already-closed transport returns `:ok`. Must
  cause the peer's owner to eventually receive
  `{:acp_transport, transport_ref, {:closed, reason}}`.
  """
  @callback close(state()) :: :ok
end
