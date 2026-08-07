defmodule Raxol.Harness.CadencePolicy do
  @moduledoc """
  The streaming-flush cadence policy: a pure decision function that
  tells a caller whether to paint now, wait, or stand aside for input.

  ## Design laws

  Same discipline as `Raxol.Harness.StallDetector`: this module owns no
  processes, no timers, no clocks. The caller passes timestamps in
  (`decide/4,5`) and owns the actual scheduling (`Process.send_after/3`
  or equivalent) -- identical inputs always produce identical outputs,
  which is what makes this testable with plain integers instead of
  `Process.sleep/1`.

  1. **Input wins, within a budget.** `decide/4,5` checks
     `input_pending?` first, before even asking whether the cadence
     window is open -- a live agent session must never let a token
     flood delay keystroke handling. But the win is bounded: after
     `max_consecutive_yields/0` consecutive yields (~one frame at the
     1ms retry) the decision falls through to the cadence rules, so
     continuous input can never starve rendering indefinitely either.

  2. **First paint is unconditional.** A stream's first delta
     (`last_flush_ms == nil`) flushes immediately. Perceived latency
     matters most at the start of a response; there is no prior cadence
     to respect yet.

  3. **Deterministic coalescing.** Every decision inside the same
     cadence window derefs to the *same* deadline
     (`last_flush_ms + interval`), not to "interval from now". This is
     what lets a burst of hundreds of deltas collapse into one scheduled
     flush instead of one timer reset per delta.
  """

  # One 60fps frame budget. The terminal cannot usefully repaint faster
  # than this, and per-token paints below this interval only burn CPU
  # and starve input handling. Matches the proven reference
  # implementation's minimum draw interval.
  @flush_interval_ms 16

  # Bounds one flush batch so the consumer's per-message work is
  # bounded: an input event waits at most one bounded batch behind a
  # token flood, never behind the whole flood. Large enough that a
  # hundreds-buffered burst still moves in big batches.
  @max_drain_per_flush 32

  # Recheck delay after yielding to input. Input dispatch is cheap, so
  # retry nearly immediately rather than busy-looping or waiting a full
  # frame interval. This is a ~1kHz wakeup loop while input stays
  # pending and deltas are buffered; it is acceptable only because
  # @max_consecutive_yields bounds it to at most 16 consecutive wakeups
  # (~one frame) before a flush or cadence defer takes over.
  @input_yield_retry_ms 1

  # Bounds the pending backlog. 10_000 items is 5 seconds of
  # maximum-rate egress (10_000 / 2_000 per sec at the shipped
  # defaults); pending older than that is history, not a live tail, and
  # shedding it bounds the heap no matter how fast the producer floods.
  @default_max_pending 10_000

  # Bounds consecutive :yield_to_input verdicts between flushes.
  # 16 yields x the 1ms retry = one full frame interval -- continuous
  # input may hold a token flush for at most ~one extra frame before
  # the cadence forces forward progress. This also terminates the 1ms
  # repoll loop (bounded wakeups per flush window).
  @max_consecutive_yields 16

  @type verdict :: :flush_now | {:defer, pos_integer()} | :yield_to_input

  @doc "The minimum interval between token flushes, in milliseconds."
  @spec flush_interval_ms() :: pos_integer()
  def flush_interval_ms, do: @flush_interval_ms

  @doc "The maximum number of pending items drained into a single flush batch."
  @spec max_drain_per_flush() :: pos_integer()
  def max_drain_per_flush, do: @max_drain_per_flush

  @doc "The recheck delay, in milliseconds, after yielding to pending input."
  @spec input_yield_retry_ms() :: pos_integer()
  def input_yield_retry_ms, do: @input_yield_retry_ms

  @doc "The default pending-queue watermark above which the oldest deltas are shed."
  @spec max_pending() :: pos_integer()
  def max_pending, do: @default_max_pending

  @doc "The maximum consecutive `:yield_to_input` verdicts between flushes."
  @spec max_consecutive_yields() :: pos_integer()
  def max_consecutive_yields, do: @max_consecutive_yields

  @doc """
  Decides what a caller holding `pending_count` buffered deltas should
  do right now.

  `now_ms` and `last_flush_ms` are caller-supplied timestamps on the
  same clock (`last_flush_ms` is `nil` when nothing has flushed yet).
  `pending_count` must be positive -- calling this with nothing pending
  is a caller bug and crashes loudly via `FunctionClauseError` rather
  than silently returning a no-op verdict.

  Decision order (the order IS the design, not an implementation
  detail):

    1. `input_pending?` true AND `yields_since_flush <
       max_consecutive_yields` -> `:yield_to_input` -- input is
       scheduled ahead of token flushes, even when the cadence gate is
       fully open or this is the very first delta. Once the yield
       budget is exhausted, the decision FALLS THROUGH to the cadence
       rules below (so continuous input holds a flush for at most
       `max_consecutive_yields x input_yield_retry_ms` ~= one frame
       before forward progress is forced; a defer landing with the
       budget still exhausted falls through again and flushes at the
       window edge).
    2. `last_flush_ms` is `nil` -> `:flush_now` -- the first delta of a
       stream paints immediately.
    3. `now_ms - last_flush_ms >= interval` -> `:flush_now`.
    4. otherwise -> `{:defer, remaining_ms}`, where `remaining_ms` is
       always `>= 1` by construction (case 3 already claimed the `>=
       interval` region).

  ## Options

    * `:flush_interval_ms` -- override the module's default cadence
      interval. This is both the deterministic-test seam (set it to
      `0` to force `:flush_now` on every decision) and the per-instance
      config seam.
    * `:yields_since_flush` (default `0`) -- how many consecutive
      `:yield_to_input` verdicts the caller has already acted on since
      its last flush. This is one piece of CALLER STATE deliberately
      carried in opts to preserve the positional-arg shape of this
      function; the policy itself stays stateless. Callers reset their
      counter to `0` on every flushed batch.
    * `:max_consecutive_yields` -- override the module's default yield
      budget.
  """
  @spec decide(
          now_ms :: integer(),
          last_flush_ms :: integer() | nil,
          pending_count :: pos_integer(),
          input_pending? :: boolean(),
          opts :: keyword()
        ) :: verdict()
  def decide(now_ms, last_flush_ms, pending_count, input_pending?, opts \\ [])
      when is_integer(now_ms) and pending_count > 0 do
    yields_since_flush = Keyword.get(opts, :yields_since_flush, 0)

    max_yields =
      Keyword.get(opts, :max_consecutive_yields, @max_consecutive_yields)

    cond do
      input_pending? and yields_since_flush < max_yields ->
        :yield_to_input

      is_nil(last_flush_ms) ->
        :flush_now

      true ->
        interval = Keyword.get(opts, :flush_interval_ms, @flush_interval_ms)
        elapsed = now_ms - last_flush_ms

        if elapsed >= interval do
          :flush_now
        else
          {:defer, interval - elapsed}
        end
    end
  end

  @doc """
  The number of pending items to drain into a single flush batch: the
  lesser of `pending_count` and the configured max drain.

  The configured cap is clamped to at least 1: a batch that drains
  nothing makes no forward progress, and `StreamCadence`'s forced full
  drain loops until pending hits zero -- a zero cap would spin it
  forever. Zero pending still drains zero; only the cap has a floor.

  ## Options

    * `:max_drain_per_flush` -- override the module's default per-flush
      cap (clamped to a minimum of 1).
  """
  @spec drain_count(pending_count :: non_neg_integer(), opts :: keyword()) ::
          non_neg_integer()
  def drain_count(pending_count, opts \\ []) do
    max_drain =
      opts
      |> Keyword.get(:max_drain_per_flush, @max_drain_per_flush)
      |> max(1)

    min(pending_count, max_drain)
  end

  @doc """
  The number of pending items a caller must shed (from the OLDEST end)
  to get back under the `:max_pending` watermark: `max(pending_count -
  max_pending, 0)`.

  Zero at or below the watermark. Callers drop from the queue front --
  the newest deltas are the live tail's value; the oldest are already
  history.

  ## Options

    * `:max_pending` -- override the module's default watermark.
  """
  @spec drop_count(pending_count :: non_neg_integer(), opts :: keyword()) ::
          non_neg_integer()
  def drop_count(pending_count, opts \\ []) do
    max_pending = Keyword.get(opts, :max_pending, @default_max_pending)
    max(pending_count - max_pending, 0)
  end
end
