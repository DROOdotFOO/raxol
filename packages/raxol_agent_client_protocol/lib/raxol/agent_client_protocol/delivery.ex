defmodule Raxol.AgentClientProtocol.Delivery do
  @moduledoc """
  Delivery vocabulary shared by `Connection` (stamping + direct turn
  delivery) and `Client` (turn consumption) — the transport-ordering design
  (`TRANSPORT_ORDERING_DESIGN.md` §4, ADR-0030 clauses 1/2/5).

  ## Message shapes (the direct turn-delivery channel)

  For a turn opened by a `session/prompt` submitted via
  `Connection.async_request/6` (`reply_to = {:owner, owner, tag}`), the
  Connection sends `owner` three message shapes directly, ALL from the
  Connection process itself — the same single-sender operation
  `deliver_outcome/2` already uses for the terminal result — so BEAM's
  per-sender-per-receiver FIFO guarantees the owner's mailbox order equals
  demux order equals wire order:

    * `{:acp_turn_update, tag, ordinal, notification}` — one per
      `session/update` notification belonging to the turn's session,
      stamped with a contiguous per-turn ordinal starting at 0.
    * `{:acp_turn_end, tag, count}` — sent exactly once, immediately before
      the terminal `{:acp_result, tag, outcome}`; `count` is the number of
      `:acp_turn_update` messages the owner should have received (ordinals
      `0..count-1`).
    * `{:acp_result, tag, outcome}` — the existing terminal delivery
      (`Connection.async_request/6`'s IC-3 contract), unchanged.

  Because the Connection is the single sender of all three shapes, a
  consumer needs no settle timer and no reorder buffer on this path:
  `delivered < count` observed at the terminal result is a definite,
  synchronous signal of dropped updates, never a race.

  ## The stamp (broadcast path)

  `t:t/0` is the per-notification ordering key threaded onto
  `Connection.Ctx.delivery_stamp` for every `session/update` dispatch
  (`nil` for anything else) — for the multi-sender broadcast path
  (`subscribe/3`, custom `session_update/2` overrides) that still fans out
  through per-notification dispatch tasks and therefore needs an explicit
  key to reconstruct order. `turn` is the receiver-minted turn token (`nil`
  when the update is out-of-turn — no open prompt turn for the session on
  this connection); `ordinal` is the contiguous per-(session, namespace)
  stamp assigned at the demux point; `rx_seq` is the connection-wide
  monotone frame stamp (kept for the unrelated cancel/prompt wire-order
  latch, IC-5c — untouched by this design).
  """

  @typedoc "Per-notification ordering key, receiver-assigned at the demux point (clause 1)."
  @type t :: %__MODULE__{
          turn: reference() | nil,
          ordinal: non_neg_integer(),
          rx_seq: non_neg_integer()
        }

  @enforce_keys [:ordinal, :rx_seq]
  defstruct turn: nil, ordinal: 0, rx_seq: 0

  @doc "Build a Stamp."
  @spec new(reference() | nil, non_neg_integer(), non_neg_integer()) :: t()
  def new(turn, ordinal, rx_seq) when is_integer(ordinal) and is_integer(rx_seq) do
    %__MODULE__{turn: turn, ordinal: ordinal, rx_seq: rx_seq}
  end

  @doc """
  Emit the `[:raxol, :acp, :delivery]` telemetry event (clauses 2/9) when
  `:telemetry` is loaded; a silent no-op otherwise (this package does not
  depend on `:telemetry`, matching `Connection`'s own optional-telemetry
  guard). `metadata` should include `:decision` — one of
  `:emit | :buffer | :gap | :fail` — plus whichever of `:session`, `:turn`,
  `:buffered`, `:ordinal` apply at the call site.
  """
  @spec emit(map()) :: :ok
  def emit(metadata) when is_map(metadata) do
    if Code.ensure_loaded?(:telemetry) and function_exported?(:telemetry, :execute, 3) do
      apply(:telemetry, :execute, [[:raxol, :acp, :delivery], %{count: 1}, metadata])
    end

    :ok
  end
end
