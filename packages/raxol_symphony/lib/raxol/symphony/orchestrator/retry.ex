defmodule Raxol.Symphony.Orchestrator.Retry do
  @moduledoc """
  Retry timing math.

  Implements SPEC s8.4 (Retry and Backoff):

  - **Continuation retries** -- after a clean worker exit. A short fixed delay
    (`1000 ms`) so the orchestrator can re-check whether the issue is still
    in an active state and needs another worker session.
  - **Failure-driven retries** -- exponential backoff:
      `delay = min(10000 * 2^(step - 1), max_retry_backoff_ms)`

  `step` is whichever counter the caller is escalating on. The orchestrator has
  two, and they are not interchangeable: `attempt` counts executions and reaches
  the prompt template and the cast filename, while `requeues` counts consecutive
  tracker outages a retry has waited out. A tracker outage escalates the second,
  so the backoff grows without telling an agent it is on attempt 47 of a run
  that never executed.
  """

  @continuation_delay_ms 1_000
  @failure_base_delay_ms 10_000

  @doc """
  Delay for a continuation retry (clean worker exit).
  """
  @spec continuation_delay_ms() :: pos_integer()
  def continuation_delay_ms, do: @continuation_delay_ms

  @doc """
  Delay for a failure-driven retry on the given step number (1-based).

  `max_retry_backoff_ms` caps the result.
  """
  @spec failure_delay_ms(pos_integer(), pos_integer()) :: pos_integer()
  def failure_delay_ms(step, max_retry_backoff_ms)
      when is_integer(step) and step >= 1 and is_integer(max_retry_backoff_ms) and
             max_retry_backoff_ms > 0 do
    raw = @failure_base_delay_ms * Bitwise.bsl(1, step - 1)
    min(raw, max_retry_backoff_ms)
  end
end
