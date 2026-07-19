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
  module. The owner should expect these message shapes:

    * `{:acp_transport, transport_ref, {:message, message}}` — one
      complete, decoded JSON-RPC frame (request, response, or
      notification) arrived from the peer. `message` is a map.
    * `{:acp_transport, transport_ref, {:closed, reason}}` — the
      transport will deliver no further messages. `reason` is an atom or
      term describing why (e.g. `:peer_closed`, `:local_close`,
      `{:error, term}`).
    * `{:acp_transport, transport_ref, {:decode_error, reason, raw}}` —
      OPTIONAL third shape for byte-level transports only. Emitted when
      one unit of wire input (e.g. one NDJSON line) fails to decode into
      a JSON-RPC frame at all. `reason` is a term describing why (e.g. a
      `Jason.DecodeError` struct, or `{:not_an_object, term}` when the
      input decoded to valid JSON that isn't an object); `raw` is the
      raw, undecoded input that produced the failure. In-process
      transports with no serialization step (`Transport.Paired`) never
      emit this shape — there is no wire to fail to decode.
      `Transport.Stdio` does emit it. When emitted, the decode error
      occupies exactly the stream position the failed frame would have
      taken: it never reorders the `{:message, _}` frames around it (see
      T-ORD below — this shape participates in the same ordered stream).

  `transport_ref` identifies *which* transport handle the message belongs
  to. It is opaque to the owner and should only be compared with `==/2`,
  never pattern-matched into — an owner that multiplexes several
  transports uses it to tell them apart.

  ## Delivery guarantees

  Implementations of this behaviour MUST satisfy the following four
  named clauses. They are MANDATED, not negotiated — there is no
  `ordered?`-style capability flag, and no callback exists to query one.
  A carrier whose underlying medium does not preserve order (e.g. frames
  fanned over multiple independent streams/paths) MUST restore order
  internally — a private sequencing envelope plus a bounded reassembly
  buffer, invisible above this behaviour — before it ever emits
  `{:message, _}` to the owner. From the owner's perspective every
  conforming transport is indistinguishable from an already-ordered one:
  ordering is a transport property, never a field on the ACP wire.

    * **T-ORD (ordered inbound delivery).** Per direction, the sequence
      of frames delivered to the owner as `{:message, frame}` (and, in
      its stream position, `{:decode_error, _, _}` where emitted) is
      EXACTLY the sequence the peer's send path accepted, in acceptance
      order. "Acceptance order" is the serialization order of the peer
      transport's single-writer send path: every transport this package
      ships funnels concurrent `send_message/2` callers through one
      process before anything leaves for the peer (`Transport.Stdio`
      serializes writes through its owning `GenServer`'s mailbox;
      `Transport.Paired` serializes through a `GenServer.call` into the
      sending side before the peer-side `cast`), so "acceptance order"
      is well-defined even when multiple local processes call
      `send_message/2` concurrently. Consequence for callers: a receiver
      that stamps an ordinal at the single sequential point where it
      processes inbound `{:acp_transport, ...}` messages gets a faithful
      ordering key for free — no reorder buffer is required above this
      layer for an ordered transport.
    * **T-REL (no silent drop; accepted implies delivered-or-closed).** A
      frame accepted by `send_message/2` (`{:ok, state}`) is either
      eventually delivered to the peer's owner, or the stream terminates
      with `{:closed, reason}` — a transport never drops an accepted
      frame and then keeps delivering later ones. `send_message/2`
      returning `{:ok, state}` does not guarantee the peer has
      *processed* the message, only that the transport has accepted it
      for delivery.
    * **T-DUP (no duplication, and duplex).** A transport delivers each
      accepted frame to the owner AT MOST once (combined with T-REL: an
      accepted frame not preceded by a terminal `{:closed, _}` is
      delivered EXACTLY once). Independently, both ends may send at any
      time, concurrently; a transport must not require request/response
      turn-taking.
    * **T-TERM (terminal close).** `{:closed, reason}` is delivered to
      the owner at most once, and nothing — no `{:message, _}`, no
      `{:decode_error, _, _}`, no second `{:closed, _}` — is delivered
      after it.

  Implementations MAY be lossy or reorder frames only strictly AFTER
  `close/1` has been called on either end, or a `{:closed, reason}` has
  already been delivered — at which point `{:error, :closed}` (or simply
  no further delivery) is the expected observable behaviour instead of
  silent loss or reorder.
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
