defmodule Raxol.Workflow.Compiled do
  @moduledoc """
  Frozen, validated workflow ready for execution.

  Returned by `Raxol.Workflow.Graph.compile/2`. The struct is opaque
  in the sense that consumers should not construct or pattern-match on
  its fields directly; the runtime API
  (`invoke/3`, `async_invoke/3`, `stream_events/3`, `resume/3`) is
  added in a follow-up PR and will be the only supported interface.

  The current PR ships the container only so the `Graph.compile/2`
  return type is stable and the surface area can be reviewed
  separately from the runtime implementation.
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
end
