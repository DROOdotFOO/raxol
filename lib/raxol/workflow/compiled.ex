defmodule Raxol.Workflow.Compiled do
  @moduledoc """
  Frozen, validated workflow ready for execution.

  Returned by `Raxol.Workflow.Graph.compile/2`. The struct is opaque
  in the sense that consumers should not construct or pattern-match on
  its fields directly; the runtime API exposed here is the supported
  interface.

  ## Runtime entry points

    * `invoke/3` -- synchronous execution. Ships in this PR.
    * `async_invoke/3` -- spawn a run under a DynamicSupervisor. Follow-up PR.
    * `stream_events/3` -- lazy CloudEvent stream of run progress. Follow-up PR.
    * `resume/3` -- consume an interrupt, continue from the checkpointed step. Follow-up PR.
  """

  @type opts :: %{
          optional(:failure_policy) => :retry | :halt | :compensate,
          optional(:step_timeout_ms) => non_neg_integer(),
          optional(:run_timeout_ms) => non_neg_integer(),
          optional(:saver) => module()
        }

  @type t :: %__MODULE__{
          id: atom() | binary(),
          nodes: %{Raxol.Workflow.Node.id() => Raxol.Workflow.Node.t()},
          edges_by_source: %{
            Raxol.Workflow.Node.id() => [Raxol.Workflow.Edge.t()]
          },
          opts: opts()
        }

  @enforce_keys [:id, :nodes, :edges_by_source, :opts]
  defstruct [:id, :nodes, :edges_by_source, :opts]

  @doc """
  Run the compiled graph synchronously.

  Delegates to `Raxol.Workflow.Runtime.invoke/3`. See that module for
  the full result-tuple contract and the supported `opts`.
  """
  @spec invoke(t(), any(), keyword()) :: Raxol.Workflow.Runtime.result()
  def invoke(%__MODULE__{} = compiled, initial_state, opts \\ []) do
    Raxol.Workflow.Runtime.invoke(compiled, initial_state, opts)
  end
end
