defmodule Raxol.AgentClientProtocol.Transport.Envelope do
  @moduledoc """
  A pure, process-free sequencing envelope for **unordered-carrier**
  transports (design-stub — no shipped transport uses this yet; see
  `Raxol.AgentClientProtocol.Transport.Reassembly` for the receive-side
  counterpart).

  Every shipped transport (stdio, `Transport.Paired`, a future WebSocket)
  is already an ordered carrier: frames arrive at the owner in exactly the
  order the peer sent them, so no sequencing is needed. A future carrier
  that reorders frames in flight (e.g. frames fanned over several ordered
  streams, or datagrams with app-level retransmit below this layer) can
  satisfy the same ordered-delivery contract by wrapping each frame with a
  sender-assigned, per-connection, per-direction monotone counter (`tseq`)
  before handing it to the carrier, and unwrapping + reassembling
  (`Reassembly`) on receipt — restoring order *before* the frame is ever
  handed to the owner. The Connection, the Session, the Client, and the
  ACP wire never observe `tseq`; it lives and dies entirely inside the
  transport.

  ## Wire shape

  The envelope wraps a frame map with two extra top-level fields:

      %{"acpenv" => 1, "s" => tseq, "f" => frame}

    * `"acpenv"` — envelope format version (currently always `1`).
    * `"s"` — the sender-assigned `tseq`, a positive integer, monotone
      per connection per direction. This is transport-internal framing,
      never ACP protocol content: it is stripped by `unwrap/1` before the
      frame reaches anything above the transport, and it must never be
      threaded through `_meta` or any other ACP-visible location (that
      was precisely the trust-boundary mistake this design corrects one
      layer up, in the Connection's receiver-assigned delivery stamp).
    * `"f"` — the original JSON-RPC frame (request, response, or
      notification map), untouched.

  A concrete carrier may re-encode this shape however its wire format
  requires (e.g. as a binary header instead of JSON keys); the three
  *fields* — version, sequence, frame — are what's normative, and this
  module's `wrap/2` / `unwrap/1` give the reference (map-shaped)
  implementation used by pure tests and by any carrier happy to use JSON
  maps directly.

  ## Purity

  Both functions are total, deterministic, and side-effect-free: no
  process, no I/O, no shared state. The caller (a transport's
  single-writer send path, mirroring the `Framer`'s threading pattern) is
  responsible for minting successive `tseq` values and for threading
  `Reassembly` state across `push/3` calls on receipt.
  """

  @acpenv_version 1

  @typedoc "One JSON-RPC frame (a decoded map), unmodified by the envelope."
  @type frame :: map()

  @typedoc "Sender-assigned, per-connection, per-direction monotone sequence number (starts at 1)."
  @type tseq :: pos_integer()

  @typedoc "The wire-shaped envelope map produced by `wrap/2`."
  @type envelope :: %{required(String.t()) => term()}

  @doc """
  Wrap `frame` with sequencing metadata for `tseq`.

  `frame` must be a map (a decoded JSON-RPC frame); `tseq` must be a
  positive integer. Returns the envelope map
  `%{"acpenv" => 1, "s" => tseq, "f" => frame}`.
  """
  @spec wrap(frame(), tseq()) :: envelope()
  def wrap(frame, tseq) when is_map(frame) and is_integer(tseq) and tseq > 0 do
    %{"acpenv" => @acpenv_version, "s" => tseq, "f" => frame}
  end

  @doc """
  Unwrap an enveloped map, returning its `tseq` and inner frame.

  Succeeds only for a map with the exact envelope shape — the current
  `"acpenv"` version, an `"s"` that is a positive integer, and an `"f"`
  that is a map. Anything else (a bare un-enveloped frame, a future/past
  envelope version, a malformed `"s"`/`"f"`) yields
  `{:error, :not_enveloped}` rather than raising: the caller (the
  receiving carrier) decides whether that is a protocol violation or
  simply "not this envelope version" — this module only recognizes its
  own shape.

  Round-trips with `wrap/2`: `unwrap(wrap(frame, tseq)) == {:ok, tseq, frame}`
  for every valid `frame`/`tseq` pair. The returned frame is
  byte-for-byte (term-for-term) identical to the wrapped input — the
  envelope carries no rider that survives into it.
  """
  @spec unwrap(map()) :: {:ok, tseq(), frame()} | {:error, :not_enveloped}
  def unwrap(%{"acpenv" => @acpenv_version, "s" => tseq, "f" => frame})
      when is_integer(tseq) and tseq > 0 and is_map(frame) do
    {:ok, tseq, frame}
  end

  def unwrap(_other), do: {:error, :not_enveloped}
end
