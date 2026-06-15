defmodule Raxol.Workflow.Execution.Scratchpad do
  @moduledoc """
  Per-task execution state for workflow runs that use interrupt / resume.

  The scratchpad holds a FIFO of resume values supplied by callers of
  `Raxol.Workflow.Compiled.resume/4`. When a node calls
  `Raxol.Workflow.interrupt/1`, that function inspects the scratchpad:

    * If the queue holds a value, the value is popped and returned;
      the node continues execution with that value (this is the resume
      path).
    * If the queue is empty, `interrupt/1` throws
      `{:__workflow_interrupt__, value}`, which the runtime catches and
      surfaces to the caller as `{:interrupted, run_id, state, value}`
      (this is the first-pause path).

  ## Storage

  Per-process storage uses the process dictionary under the
  `:raxol_workflow_scratchpad` key. This is one of the rare cases
  where the process dictionary is the right tool: the scratchpad is
  process-local by construction, lives only for the duration of one
  run's execution in one process, and must not leak between runs.
  `Runtime.invoke/3` clears the scratchpad on entry and exit so the
  ambient state is always either the current run's or absent.
  """

  @key :raxol_workflow_scratchpad

  @typedoc "Per-process scratchpad state. Opaque to callers."
  @type t :: %{run_id: binary() | nil, resume_queue: :queue.queue()}

  @doc """
  Initialize the scratchpad for `run_id`, optionally seeding the resume
  queue with the supplied list of values in order.

  Subsequent calls overwrite any prior scratchpad on the same process.
  """
  @spec init(binary(), [any()]) :: :ok
  def init(run_id, resume_values \\ []) when is_list(resume_values) do
    queue = Enum.reduce(resume_values, :queue.new(), &:queue.in/2)
    Process.put(@key, %{run_id: run_id, resume_queue: queue})
    :ok
  end

  @doc """
  Pop the head of the resume queue.

  Returns `{:ok, value}` if a value was available, `:empty` otherwise.
  Safe to call without `init/2`; treats the absence of a scratchpad as
  an empty queue.
  """
  @spec take_resume() :: {:ok, any()} | :empty
  def take_resume do
    case Process.get(@key) do
      %{resume_queue: queue} = scratchpad ->
        case :queue.out(queue) do
          {{:value, value}, new_queue} ->
            Process.put(@key, %{scratchpad | resume_queue: new_queue})
            {:ok, value}

          {:empty, _queue} ->
            :empty
        end

      _ ->
        :empty
    end
  end

  @doc "Return the current scratchpad, or `nil` if none is set."
  @spec get() :: t() | nil
  def get, do: Process.get(@key)

  @doc "Remove the scratchpad from the process dictionary."
  @spec clear() :: :ok
  def clear do
    Process.delete(@key)
    :ok
  end
end
