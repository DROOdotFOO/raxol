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

  1. **Input always wins.** `decide/4,5` checks `input_pending?` first,
     before even asking whether the cadence window is open. A live
     agent session must never let a token flood delay keystroke
     handling -- not even by one scheduling decision.

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
  # frame interval.
  @input_yield_retry_ms 1

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

    1. `input_pending?` true -> `:yield_to_input`, unconditionally --
       input is always scheduled ahead of token flushes, even when the
       cadence gate is fully open or this is the very first delta.
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
    cond do
      input_pending? ->
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

  ## Options

    * `:max_drain_per_flush` -- override the module's default per-flush
      cap.
  """
  @spec drain_count(pending_count :: non_neg_integer(), opts :: keyword()) ::
          non_neg_integer()
  def drain_count(pending_count, opts \\ []) do
    max_drain = Keyword.get(opts, :max_drain_per_flush, @max_drain_per_flush)
    min(pending_count, max_drain)
  end
end
