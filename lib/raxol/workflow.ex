defmodule Raxol.Workflow do
  @moduledoc """
  Top-level interrupt/resume API for `Raxol.Workflow.*`.

  The graph builder, compile pipeline, and runtime entry points live
  in their dedicated submodules (`Graph`, `Compiled`, `Runtime`,
  `Async`). This module exposes the small surface that node code
  needs during execution: `interrupt/1`.

  ## Pausing a run for human input

      defmodule MyNodes do
        def approve_release(state) do
          decision = Raxol.Workflow.interrupt(:awaiting_approval)

          case decision do
            :approved -> {:ok, Map.put(state, :status, :released)}
            :rejected -> {:ok, Map.put(state, :status, :rejected)}
          end
        end
      end

  On the first execution the runtime catches the throw raised by
  `interrupt/1` and returns
  `{:interrupted, run_id, state_before_node, :awaiting_approval}`. The
  caller (human, MCP tool, scheduled job) eventually calls
  `Compiled.resume(compiled, run_id, :approved)`. The runtime
  rehydrates the latest checkpoint, seeds the scratchpad with
  `:approved`, and re-runs the node; this time `interrupt/1` finds the
  value in the queue and returns it.
  """

  alias Raxol.Workflow.Execution.Scratchpad

  @doc """
  Pause the current run, or consume a previously-supplied resume value.

  - If the scratchpad's resume queue holds a value, returns
    `{:ok, value}`'s value (i.e. just the value, unwrapped). Execution
    continues normally.
  - If the queue is empty, throws
    `{:__workflow_interrupt__, interrupt_value}`. The runtime catches
    this and surfaces it to the caller as
    `{:interrupted, run_id, state, interrupt_value}`.

  `interrupt_value` is opaque to the runtime; it is forwarded verbatim
  to the caller and is intended to carry whatever context the caller
  needs to make a decision (e.g. an approval request, a question,
  a payload for downstream tooling).
  """
  @spec interrupt(any()) :: any() | no_return()
  def interrupt(interrupt_value) do
    case Scratchpad.take_resume() do
      {:ok, resume_value} -> resume_value
      :empty -> throw({:__workflow_interrupt__, interrupt_value})
    end
  end
end
