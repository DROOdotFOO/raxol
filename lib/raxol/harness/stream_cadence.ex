defmodule Raxol.Harness.StreamCadence do
  @moduledoc """
  The streaming render cadence layer: decouples token *ingest* (network
  rate, unbounded) from render *egress* (cadence-throttled, bounded per
  flush) so a live agent's token stream never floods the terminal or
  starves input.

  ## 1. What this is

  When a live agent streams LLM tokens, `Raxol.Agent.Backend.HTTP.stream/2`
  produces text-chunk deltas at network rate -- bursts of hundreds per
  second are normal. Painting on every delta floods the terminal
  (redundant repaints of the same live tail) and starves input handling
  in whatever process applies the paint. This module sits between that
  producer and a `Raxol.Harness.Surface`-shaped consumer (apply deltas
  to the live tail, repaint the footer): unbounded ingest via
  `ingest/2` (the GenServer mailbox is the buffer -- it never blocks
  the producer; load-shedding, not backpressure: excess above
  `:max_pending` is dropped, not pushed back), cadence-throttled egress
  via `Raxol.Harness.CadencePolicy` (the pure decision function),
  bounded per-flush drain (`Raxol.Harness.CadencePolicy.drain_count/2`).

  To be plain about the flow-control model: this layer never applies
  backpressure toward the producer. It is a cadence + load-shedding
  layer -- ingest is always accepted, and excess above the watermark is
  shed per section 3. A supervision instrument must stay alive and
  current: the newest deltas ARE the live tail's value, and blocking
  (call-based) ingest would stall the SSE reader process and cascade
  into transport timeouts -- the wrong failure mode. Visibly lossy
  above the watermark beats dead.

  ## 2. The owner-consumption contract (the seam)

  **Out of the box this module enforces NO input priority.** The
  default `:input_check` always returns `false`, so the source-side
  hold described below is OFF until a caller wires a real check. The
  `:input_check` seam is MANDATORY, not optional, for the input-first
  behavior -- and the other mandatory half is the owner handling its
  input messages before `{:render_batch, ...}` messages in its own
  receive.

  Flush delivery is a **message** the owner consumes -- by default
  `{:render_batch, batch}` sent to the `:owner` pid -- never a blocking
  call into the owner. This server never forces the owner to handle a
  batch synchronously.

  Input priority is enforced in plain OTP terms, not by this module
  reaching into the owner's mailbox: the owner (the future live-session
  loop) is responsible for keeping input ahead of paints by handling
  its own input messages before `{:render_batch, ...}` messages --
  selective receive matching input patterns first, or draining pending
  input before applying a batch. Belt-and-suspenders: the `:input_check`
  option lets the cadence policy hold token flushes at the *source*
  (`:yield_to_input`) while input is pending, so batches don't even
  enter the owner's mailbox ahead of input in the common case.

  A custom `:sink` **must** preserve the non-blocking property (a
  `send`, never a `GenServer.call` into the owner) -- this server has
  no timeout protection against a slow sink.

  ## 3. Ordering / loss contract

  The guarantee is: **lossless below the `:max_pending` watermark;
  explicit, in-band loss above it.**

  Below the watermark, batches arrive in ingest order and the
  concatenation of every delivered batch equals the exact ingest
  sequence -- no delta dropped, duplicated, or reordered. Each batch
  carries at most `Raxol.Harness.CadencePolicy.max_drain_per_flush/0`
  deltas (or the configured override).

  At or above the watermark, the OLDEST pending deltas are shed
  (drop-oldest: the queue head is history, the queue tail is the live
  view). Each shed emits an `[:raxol, :harness, :stream_cadence,
  :overflow]` telemetry event at drop time (measurements
  `%{dropped, pending_count}`, metadata `%{max_pending}`), and the next
  flushed batch begins with a `{:cadence_dropped, n}` marker sitting
  exactly at the position of the loss (the dropped items were the queue
  head). The marker is NOT counted against the drain bound, so a batch
  carries at most `max_drain_per_flush + 1` elements when loss
  occurred. `{:cadence_dropped, non_neg_integer()}` is a documented
  RESERVED element type in the batch stream; consumers must handle it.
  A naive sink that assumes every batch element is a delta (say, one
  that joins binaries) will fail loudly at the first loss -- that is
  deliberate: in a supervision instrument, silently rendering a
  gapless stream over shed data is worse than a crash that names the
  unhandled loss.

  The pending queue is therefore always bounded.

  ## 4. Throughput ceiling (deliberate design point)

  Steady-state egress is bounded at `max_drain_per_flush` items per
  `flush_interval_ms` -- the shipped defaults put that at 32 items per
  16ms, i.e. 2,000 deltas/sec, comfortably above any real LLM token
  rate. This diverges from the Rust reference design, where message
  *application* and *painting* are decoupled (unbounded application,
  throttled paint): here the flush message itself IS the paint
  trigger, so the drain bound doubles as an application bound. An
  instantaneous 1,000-delta backlog drains in roughly 0.5s of bounded
  paints at the default cadence. Call `flush_now/1` at end-of-stream
  (the SSE `:sse_done` moment) to skip that wait and flush the tail
  immediately instead of leaving it up to 16ms stale.

  In the other direction, rendering waits on input for at most ~one
  frame interval: the consecutive-yield budget
  (`Raxol.Harness.CadencePolicy.max_consecutive_yields/0`) forces a
  flush through even under continuous input.

  ## 5. Not wired yet

  The live session loop that would own one of these servers, apply
  `{:render_batch, batch}` to a live tail, and repaint the footer does
  not exist yet. This module and the contract above ship standalone,
  ahead of that wiring.
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Harness.CadencePolicy

  @overflow_event [:raxol, :harness, :stream_cadence, :overflow]

  ## Client API

  @doc """
  Enqueues `delta` for eventual flush. Always a cast -- the unbounded
  mailbox is the buffer, so ingest never blocks the producer
  (load-shedding, not backpressure: excess above `:max_pending` is
  dropped, not pushed back -- see moduledoc section 3).
  """
  @spec ingest(GenServer.server(), term()) :: :ok
  def ingest(server, delta) do
    GenServer.cast(server, {:ingest, delta})
  end

  @doc """
  Forces an immediate full drain of everything currently pending,
  ignoring cadence and the input gate. Delivers all pending items now,
  as consecutive sink calls of at most `max_drain_per_flush` items
  each, in ingest order. Intended for the end-of-stream moment (SSE
  `:sse_done`) so the tail never sits cadence-stale.
  """
  @spec flush_now(GenServer.server()) :: :ok
  def flush_now(server) do
    GenServer.cast(server, :flush_now)
  end

  ## Server callbacks

  @impl true
  def init_manager(opts) do
    sink = build_sink!(opts)
    policy = Keyword.get(opts, :policy, CadencePolicy)

    clock =
      Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    input_check = Keyword.get(opts, :input_check, fn -> false end)

    input_yield_retry_ms =
      Keyword.get(
        opts,
        :input_yield_retry_ms,
        CadencePolicy.input_yield_retry_ms()
      )

    policy_opts =
      Keyword.take(opts, [
        :flush_interval_ms,
        :max_drain_per_flush,
        :max_pending,
        :max_consecutive_yields
      ])

    state = %{
      sink: sink,
      policy: policy,
      policy_opts: policy_opts,
      clock: clock,
      input_check: input_check,
      input_yield_retry_ms: input_yield_retry_ms,
      pending: :queue.new(),
      pending_count: 0,
      last_flush_ms: nil,
      timer_ref: nil,
      dropped_since_flush: 0,
      yields_since_flush: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_manager_cast({:ingest, delta}, state) do
    pending = :queue.in(delta, state.pending)

    state =
      %{state | pending: pending, pending_count: state.pending_count + 1}
      |> shed_overflow()

    state =
      if state.timer_ref do
        # A flush is already scheduled -- it will pick this delta up
        # along with whatever else lands before it fires. This is how
        # a burst coalesces into one batch instead of one timer reset
        # per delta.
        state
      else
        decide_and_act(state)
      end

    {:noreply, state}
  end

  def handle_manager_cast(:flush_now, state) do
    state =
      state
      |> cancel_timer()
      |> full_drain()

    {:noreply, state}
  end

  def handle_manager_cast(_other, state), do: {:noreply, state}

  @impl true
  def handle_manager_info(:flush_due, state) do
    state = %{state | timer_ref: nil}

    state =
      if state.pending_count == 0 do
        state
      else
        decide_and_act(state)
      end

    {:noreply, state}
  end

  def handle_manager_info(_other, state), do: {:noreply, state}

  ## Internal

  defp build_sink!(opts) do
    case {Keyword.get(opts, :sink), Keyword.get(opts, :owner)} do
      {sink, _owner} when is_function(sink, 1) ->
        sink

      {nil, owner} when is_pid(owner) ->
        fn batch ->
          send(owner, {:render_batch, batch})
          :ok
        end

      _ ->
        raise ArgumentError,
              "Raxol.Harness.StreamCadence requires :sink or :owner"
    end
  end

  # Drop-oldest load shedding at the :max_pending watermark: the queue
  # head is history, the queue tail is the live view. Loud, twice over
  # -- telemetry now, and an in-band {:cadence_dropped, n} marker at
  # the next flush (accumulated in dropped_since_flush).
  defp shed_overflow(state) do
    case state.policy.drop_count(state.pending_count, state.policy_opts) do
      0 ->
        state

      drop ->
        {_shed, rest} = :queue.split(drop, state.pending)
        new_count = state.pending_count - drop

        :telemetry.execute(
          @overflow_event,
          %{dropped: drop, pending_count: new_count},
          %{
            max_pending:
              Keyword.get(
                state.policy_opts,
                :max_pending,
                CadencePolicy.max_pending()
              )
          }
        )

        %{
          state
          | pending: rest,
            pending_count: new_count,
            dropped_since_flush: state.dropped_since_flush + drop
        }
    end
  end

  # Consults the policy for the current instant and either flushes now
  # (draining a bounded batch, then re-consulting for any remainder),
  # or schedules a `:flush_due` timer per the verdict. The
  # yields_since_flush counter is caller state the policy needs, passed
  # per call (never stored inside policy_opts) and reset by every
  # flushed batch.
  defp decide_and_act(state) do
    now = state.clock.()

    opts =
      Keyword.put(
        state.policy_opts,
        :yields_since_flush,
        state.yields_since_flush
      )

    verdict =
      state.policy.decide(
        now,
        state.last_flush_ms,
        state.pending_count,
        state.input_check.(),
        opts
      )

    case verdict do
      :flush_now ->
        flush_one_batch(state, now)

      {:defer, ms} ->
        schedule_flush(state, ms)

      :yield_to_input ->
        state = %{state | yields_since_flush: state.yields_since_flush + 1}
        schedule_flush(state, state.input_yield_retry_ms)
    end
  end

  # The one shared drain body (the cadence path and the forced path
  # both use it): split off one bounded batch, prepend the loss marker
  # if any deltas were shed since the last flush, sink it, and reset
  # the per-flush counters. The marker is NOT counted against the
  # drain bound -- a marker-bearing batch is max_drain + 1 elements,
  # so no delta is displaced by the report of the loss.
  defp drain_one_batch(state, now) do
    drain = state.policy.drain_count(state.pending_count, state.policy_opts)
    {batch_queue, rest_queue} = :queue.split(drain, state.pending)
    deltas = :queue.to_list(batch_queue)

    batch =
      case state.dropped_since_flush do
        0 -> deltas
        n -> [{:cadence_dropped, n} | deltas]
      end

    state.sink.(batch)

    %{
      state
      | pending: rest_queue,
        pending_count: state.pending_count - drain,
        last_flush_ms: now,
        dropped_since_flush: 0,
        yields_since_flush: 0
    }
  end

  # Cadence-path flush: one bounded batch, then -- if anything remains
  # -- re-consult the policy with the fresh `last_flush_ms`.
  # Immediately after a flush, elapsed time against that fresh
  # timestamp is ~0, so the policy will defer the remainder by a full
  # cadence interval (or yield to input, if input became pending in
  # the meantime).
  defp flush_one_batch(state, now) do
    state = drain_one_batch(state, now)

    if state.pending_count > 0 do
      decide_and_act(state)
    else
      state
    end
  end

  # Forced full drain (`flush_now/1`): ignores cadence and the input
  # gate entirely, delivering everything pending now in consecutive
  # bounded batches.
  defp full_drain(%{pending_count: 0} = state), do: state

  defp full_drain(state) do
    now = state.clock.()
    full_drain_loop(state, now)
  end

  defp full_drain_loop(%{pending_count: 0} = state, _now), do: state

  defp full_drain_loop(state, now) do
    state
    |> drain_one_batch(now)
    |> full_drain_loop(now)
  end

  defp schedule_flush(state, ms) do
    ref = Process.send_after(self(), :flush_due, ms)
    %{state | timer_ref: ref}
  end

  defp cancel_timer(%{timer_ref: nil} = state), do: state

  defp cancel_timer(%{timer_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | timer_ref: nil}
  end
end
