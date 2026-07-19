defmodule Raxol.AgentClientProtocol.Transport.Reassembly do
  @moduledoc """
  A pure, process-free reorder buffer for **unordered-carrier** transports
  (design-stub — pairs with `Raxol.AgentClientProtocol.Transport.Envelope`
  on the send side; no shipped transport uses this yet).

  Shaped exactly like `Transport.Framer`: no process, no mailbox, no I/O —
  a caller (a transport's single reader) threads `t()` through successive
  `push/3` calls as enveloped frames arrive off the wire, in *whatever*
  order the carrier delivers them, and gets back the frames that are now
  releasable *in original send order*.

  ## Scope: reliable-unordered, not lossy

  This module targets carriers that reorder frames but never lose them
  (e.g. frames fanned out over several independently-ordered streams, a
  bus with per-partition-only ordering, or a datagram carrier with its
  own retransmit below this layer). It restores order; it does not
  detect or recover from loss. A missing `tseq` and a merely-delayed
  `tseq` are indistinguishable to this module — both simply hold up
  release until either the gap arrives or the watermark is crossed. A
  *lossy* carrier needs its own ARQ (ack/retransmit) underneath this
  layer to turn itself into a reliable-unordered one; that is a transport
  concern, not an ordering one, and is out of scope here.

  ## Semantics

    * `next_expected` starts at `1` (or `:start`, see `new/1`).
    * `tseq == next_expected` — release that frame, then cascade: release
      every already-buffered contiguous successor (`next_expected + 1`,
      `+2`, ...) in one `push/3` call, advancing `next_expected` past all
      of them.
    * `tseq > next_expected` — buffer it (keyed by `tseq`); nothing is
      released.
    * `tseq < next_expected` — a duplicate of an already-released frame;
      dropped silently (idempotent under carrier-level retransmit).
    * a duplicate of an already-*buffered* (not yet released) `tseq` —
      also dropped silently; the buffer keeps the first copy.
    * the buffer crossing either watermark (`:max_buffered_frames`,
      default `#{inspect(1024)}`; `:max_buffered_bytes`, default 16 MiB)
      returns `{:closed, {:transport, :reassembly_overflow}}` — the
      **only** failure mode. There is no other way this module ever
      reports a problem.

  ## Overflow-bounded, never timer-bounded

  There is no wall clock anywhere in this module — no timer, no
  `Process.send_after`, no deadline. While under the watermark, an
  out-of-order frame is held indefinitely, waiting for its missing
  predecessor; the only two resolutions are the predecessor's arrival or
  the watermark closing the stream. A carrier that wants liveness
  detection (peer silently vanished, nothing further will ever arrive)
  implements its own keepalive below this layer and calls `close/1` (or
  simply stops calling `push/3` and tears down its own state) — that is
  the carrier's reliability concern, not this buffer's ordering concern.

  ## Usage

      buf = Reassembly.new()
      {:ok, [], buf} = Reassembly.push(buf, 2, %{"b" => 2})   # buffered, nothing releasable yet
      {:ok, released, buf} = Reassembly.push(buf, 1, %{"a" => 1})
      # released == [%{"a" => 1}, %{"b" => 2}]  -- 1 releases, then 2 cascades
  """

  @default_max_buffered_frames 1_024
  @default_max_buffered_bytes 16 * 1024 * 1024

  @enforce_keys [:next_expected, :max_buffered_frames, :max_buffered_bytes]
  defstruct next_expected: 1,
            buffer: %{},
            buffered_bytes: 0,
            max_buffered_frames: @default_max_buffered_frames,
            max_buffered_bytes: @default_max_buffered_bytes

  @typedoc "One JSON-RPC frame (a decoded map), as delivered by `Envelope.unwrap/1`."
  @type frame :: map()

  @typedoc "Sender-assigned monotone sequence number (see `Envelope`)."
  @type tseq :: pos_integer()

  @type t :: %__MODULE__{
          next_expected: pos_integer(),
          buffer: %{optional(tseq()) => frame()},
          buffered_bytes: non_neg_integer(),
          max_buffered_frames: pos_integer(),
          max_buffered_bytes: pos_integer()
        }

  @typedoc "The sole failure this module ever produces: the watermark was crossed."
  @type overflow_reason :: {:transport, :reassembly_overflow}

  @doc """
  Create a fresh reassembly buffer.

  Options:

    * `:start` — the first `tseq` this buffer expects (default `1`,
      matching `Envelope`'s counter start). Must be a positive integer.
    * `:max_buffered_frames` — maximum number of not-yet-releasable
      frames held at once before overflow (default
      `#{@default_max_buffered_frames}`). Must be a positive integer.
    * `:max_buffered_bytes` — maximum approximate total size (in bytes,
      via `:erlang.external_size/1` on each buffered frame) of buffered
      frames before overflow (default #{@default_max_buffered_bytes}
      = 16 MiB). Must be a positive integer.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    start = Keyword.get(opts, :start, 1)
    max_frames = Keyword.get(opts, :max_buffered_frames, @default_max_buffered_frames)
    max_bytes = Keyword.get(opts, :max_buffered_bytes, @default_max_buffered_bytes)

    unless is_integer(start) and start > 0 do
      raise ArgumentError, "start must be a positive integer, got: #{inspect(start)}"
    end

    unless is_integer(max_frames) and max_frames > 0 do
      raise ArgumentError,
            "max_buffered_frames must be a positive integer, got: #{inspect(max_frames)}"
    end

    unless is_integer(max_bytes) and max_bytes > 0 do
      raise ArgumentError,
            "max_buffered_bytes must be a positive integer, got: #{inspect(max_bytes)}"
    end

    %__MODULE__{
      next_expected: start,
      max_buffered_frames: max_frames,
      max_buffered_bytes: max_bytes
    }
  end

  @doc """
  Feed one arrived (already-unwrapped) `{tseq, frame}` pair into the
  buffer.

  Returns `{:ok, released, buffer}` where `released` is the (possibly
  empty) list of frames now releasable, in original send order — or
  `{:closed, {:transport, :reassembly_overflow}}` if admitting this frame
  would cross either watermark. Once `:closed` is returned the caller
  MUST stop calling `push/3` (mirroring `T-TERM`: nothing is delivered
  after a close) and deliver
  `{:acp_transport, ref, {:closed, {:transport, :reassembly_overflow}}}`
  to its owner; this module holds no further state for that stream.
  """
  @spec push(t(), tseq(), frame()) ::
          {:ok, [frame()], t()} | {:closed, overflow_reason()}
  def push(%__MODULE__{} = t, tseq, frame)
      when is_integer(tseq) and tseq > 0 and is_map(frame) do
    cond do
      tseq < t.next_expected ->
        # Already released. Idempotent drop under carrier-level retransmit.
        {:ok, [], t}

      tseq == t.next_expected ->
        {released, t} = release_cascade(t, frame)
        {:ok, released, t}

      Map.has_key?(t.buffer, tseq) ->
        # Already buffered, not yet released. Idempotent drop.
        {:ok, [], t}

      true ->
        admit(t, tseq, frame)
    end
  end

  # -- Internal -----------------------------------------------------------

  # tseq == next_expected: release it, then walk forward releasing every
  # already-buffered contiguous successor.
  @spec release_cascade(t(), frame()) :: {[frame()], t()}
  defp release_cascade(%__MODULE__{} = t, frame) do
    t = %{t | next_expected: t.next_expected + 1}
    cascade(t, [frame])
  end

  @spec cascade(t(), [frame(), ...]) :: {[frame()], t()}
  defp cascade(%__MODULE__{} = t, acc) do
    case Map.pop(t.buffer, t.next_expected) do
      {nil, _same_buffer} ->
        {Enum.reverse(acc), t}

      {buffered_frame, rest} ->
        t = %{
          t
          | buffer: rest,
            buffered_bytes: t.buffered_bytes - frame_size(buffered_frame),
            next_expected: t.next_expected + 1
        }

        cascade(t, [buffered_frame | acc])
    end
  end

  # tseq > next_expected and not already buffered: admit into the buffer
  # unless doing so would cross either watermark.
  @spec admit(t(), tseq(), frame()) :: {:ok, [frame()], t()} | {:closed, overflow_reason()}
  defp admit(%__MODULE__{} = t, tseq, frame) do
    size = frame_size(frame)
    new_buffer = Map.put(t.buffer, tseq, frame)
    new_bytes = t.buffered_bytes + size

    if map_size(new_buffer) > t.max_buffered_frames or new_bytes > t.max_buffered_bytes do
      {:closed, {:transport, :reassembly_overflow}}
    else
      {:ok, [], %{t | buffer: new_buffer, buffered_bytes: new_bytes}}
    end
  end

  # Approximate wire footprint of a buffered frame, for the byte watermark.
  # Deterministic and pure (no encode/decode round trip needed); the exact
  # figure isn't load-bearing, only that it monotonically reflects size.
  @spec frame_size(frame()) :: non_neg_integer()
  defp frame_size(frame), do: :erlang.external_size(frame)
end
