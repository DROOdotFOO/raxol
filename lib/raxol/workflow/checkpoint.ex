defmodule Raxol.Workflow.Checkpoint do
  @moduledoc """
  An append-only snapshot of a workflow run's state at a specific step.

  Each successful node completion produces one checkpoint when a
  `Raxol.Workflow.Checkpoint.Saver` is configured on the compiled
  graph's opts. Checkpoints are keyed by `(thread_id, step)`:

    * `thread_id` -- the run id; one workflow execution corresponds
      to one thread. Resuming an interrupted run reuses the same
      thread_id so the new checkpoints chain onto the existing series.
    * `step` -- a monotonic counter starting at 0 for the first
      checkpoint of a thread.
    * `state` -- the workflow state immediately after the node ran.
    * `metadata` -- arbitrary map; the runtime stores
      `%{node_id, run_id, graph_id}`.
    * `parent_step` -- the previous step in the same thread, or `nil`
      for the first checkpoint.
    * `created_at` -- `DateTime` in UTC when the runtime wrote this
      record.

  Append-only semantics: `Saver.put/3` never overwrites a prior
  checkpoint with the same `(thread_id, step)`; time-travel
  (replay from a prior step) is a property of the data model, not a
  feature flag.
  """

  @type thread_id :: binary()
  @type step :: non_neg_integer()

  @type t :: %__MODULE__{
          thread_id: thread_id(),
          step: step(),
          state: any(),
          metadata: map(),
          parent_step: step() | nil,
          created_at: DateTime.t()
        }

  @enforce_keys [:thread_id, :step, :state, :created_at]
  defstruct [
    :thread_id,
    :step,
    :state,
    :parent_step,
    :created_at,
    metadata: %{}
  ]

  @doc "Construct a checkpoint. `created_at` defaults to `DateTime.utc_now/0`."
  @spec new(keyword()) :: t()
  def new(opts) do
    %__MODULE__{
      thread_id: Keyword.fetch!(opts, :thread_id),
      step: Keyword.fetch!(opts, :step),
      state: Keyword.fetch!(opts, :state),
      metadata: Keyword.get(opts, :metadata, %{}),
      parent_step: Keyword.get(opts, :parent_step),
      created_at: Keyword.get_lazy(opts, :created_at, &DateTime.utc_now/0)
    }
  end
end
