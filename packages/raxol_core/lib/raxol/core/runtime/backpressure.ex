defmodule Raxol.Core.Runtime.Backpressure do
  @moduledoc """
  Adaptive backpressure for hot-path `GenServer.cast`.

  Probes the target mailbox depth via `Process.info(pid, :message_queue_len)`
  and switches behaviour when the queue crosses a watermark. See
  `docs/adr/0013-event-dispatch-backpressure.md` for the design rationale.

  ## Policies

    * `:call_when_full` -- escalate to a synchronous `GenServer.call/3`,
      applying backpressure to the caller. Use when message loss is
      unacceptable (input dispatch, test determinism).
    * `:drop_when_full` -- drop the message and return
      `{:dropped, :overflow}`. Use when the consumer naturally recovers
      from drops (frame batching, idempotent updates).
    * `:fail_when_full` -- same return shape as `:drop_when_full`; the
      `policy` field in telemetry metadata distinguishes "expected drop"
      from "explicit failure" for handler-side severity routing.

  ## Telemetry

  Emits `[:raxol, :runtime, :backpressure]` on every invocation.

    * Measurements: `%{queue_len: non_neg_integer()}`
    * Metadata: `%{label, policy, decision, target}` where `decision` is
      one of `:cast`, `:call`, `:drop`, `:no_proc`.

  ## Examples

      Backpressure.cast(MyDispatcher, {:dispatch, event},
        label: :dispatcher_input,
        policy: :call_when_full,
        watermark: 1_000
      )
  """

  @type policy :: :call_when_full | :drop_when_full | :fail_when_full
  @type decision :: :cast | :call | :drop | :no_proc
  @type result :: :ok | {:dropped, :overflow | :no_proc}

  @default_watermark 1_000
  @default_timeout 5_000
  @telemetry_event [:raxol, :runtime, :backpressure]

  @doc """
  Send `message` to `target` with backpressure-aware delivery.

  Required opts: `:label` (atom for telemetry), `:policy`.
  Optional opts: `:watermark` (default #{@default_watermark}),
  `:timeout` (default #{@default_timeout}, only used for `:call_when_full`).
  """
  @spec cast(GenServer.server(), term(), keyword()) :: result()
  def cast(target, message, opts) do
    label = Keyword.fetch!(opts, :label)
    policy = Keyword.fetch!(opts, :policy)
    watermark = Keyword.get(opts, :watermark, @default_watermark)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case mailbox_len(target) do
      nil ->
        emit(0, label, policy, :no_proc, target)
        {:dropped, :no_proc}

      n when n <= watermark ->
        :ok = GenServer.cast(target, message)
        emit(n, label, policy, :cast, target)
        :ok

      n when policy == :call_when_full ->
        _ = GenServer.call(target, message, timeout)
        emit(n, label, policy, :call, target)
        :ok

      n ->
        emit(n, label, policy, :drop, target)
        {:dropped, :overflow}
    end
  end

  defp mailbox_len(target) do
    with pid when is_pid(pid) <- resolve(target),
         {:message_queue_len, n} <- Process.info(pid, :message_queue_len) do
      n
    else
      _ -> nil
    end
  end

  defp resolve(target) do
    case GenServer.whereis(target) do
      pid when is_pid(pid) -> if Process.alive?(pid), do: pid
      _ -> nil
    end
  end

  defp emit(queue_len, label, policy, decision, target) do
    :telemetry.execute(
      @telemetry_event,
      %{queue_len: queue_len},
      %{label: label, policy: policy, decision: decision, target: target}
    )
  end
end
