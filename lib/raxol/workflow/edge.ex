defmodule Raxol.Workflow.Edge do
  @moduledoc """
  Edge descriptors for `Raxol.Workflow.Graph`.

  Three shapes:

    * `Edge` -- static edge from `from` to `to`
    * `GuardedEdge` -- static edge guarded by a predicate
    * `ConditionalEdge` -- fan-out edge whose `chooser` returns the
      next node id (or a list of ids for parallel fan-out) based on state

  The two terminal node ids are `:__start__` and `:__end__`. Every
  graph must have at least one edge from `:__start__` to a node and at
  least one edge to `:__end__`.
  """

  @start :__start__
  @end_ :__end__

  defmodule Edge do
    @moduledoc "Static edge from `from` to `to`."

    @type t :: %__MODULE__{
            from: Raxol.Workflow.Node.id(),
            to: Raxol.Workflow.Node.id()
          }

    @enforce_keys [:from, :to]
    defstruct [:from, :to]
  end

  defmodule GuardedEdge do
    @moduledoc """
    Edge that is taken only when `guard.(state)` returns truthy.

    The runtime evaluates guards in the order edges were added. The
    first matching guard wins; if no guard matches, the next outgoing
    edge (static or conditional) is consulted.
    """

    @type t :: %__MODULE__{
            from: Raxol.Workflow.Node.id(),
            to: Raxol.Workflow.Node.id(),
            guard: (any() -> any())
          }

    @enforce_keys [:from, :to, :guard]
    defstruct [:from, :to, :guard]
  end

  defmodule ConditionalEdge do
    @moduledoc """
    Edge whose `chooser.(state)` returns the next node id, or a list
    of node ids for parallel fan-out.

    The chooser must return either an atom (single next node) or a
    non-empty list of atoms (parallel fan-out). The compiler verifies
    that every possible return value is a node in the graph; runtime
    re-checks if the chooser is opaque.
    """

    @type chooser_result ::
            Raxol.Workflow.Node.id() | [Raxol.Workflow.Node.id()]

    @type t :: %__MODULE__{
            from: Raxol.Workflow.Node.id(),
            chooser: (any() -> chooser_result()),
            candidates: [Raxol.Workflow.Node.id()]
          }

    @enforce_keys [:from, :chooser, :candidates]
    defstruct [:from, :chooser, :candidates]
  end

  defmodule JoinEdge do
    @moduledoc """
    Barrier descriptor for a join node.

    Created by `Raxol.Workflow.Graph.add_join/4`. The runtime treats
    the `target` node as a barrier: it executes the target's body once,
    with a merged state built from each upstream branch's terminal
    state. Upstream completions are tracked per-run; the join fires
    when every `upstream` id has committed.

    `from/1` returns the `target` (the join's own node id, where the
    edge "lives" in the source-keyed index); `targets/1` returns
    `[target]` -- the join has no outgoing destination of its own,
    static or guarded edges from `target` carry the run forward.
    """

    @type t :: %__MODULE__{
            target: Raxol.Workflow.Node.id(),
            upstream: [Raxol.Workflow.Node.id()],
            reducer: (([map()]) -> map()) | nil,
            timeout_ms: pos_integer() | nil,
            parallelism: pos_integer() | :branches
          }

    @enforce_keys [:target, :upstream]
    defstruct [
      :target,
      :upstream,
      reducer: nil,
      timeout_ms: nil,
      parallelism: :branches
    ]
  end

  @type t :: Edge.t() | GuardedEdge.t() | ConditionalEdge.t() | JoinEdge.t()

  @doc "Return the source node id of any edge type."
  @spec from(t()) :: Raxol.Workflow.Node.id()
  def from(%Edge{from: f}), do: f
  def from(%GuardedEdge{from: f}), do: f
  def from(%ConditionalEdge{from: f}), do: f
  def from(%JoinEdge{target: t}), do: t

  @doc """
  Return the list of possible target node ids for any edge type.
  `ConditionalEdge` returns its declared candidate set. `JoinEdge`
  returns the join's own node id -- consumed by `compile/2`'s
  reachability validation, which treats the join as a sink for its
  upstream branches.
  """
  @spec targets(t()) :: [Raxol.Workflow.Node.id()]
  def targets(%Edge{to: t}), do: [t]
  def targets(%GuardedEdge{to: t}), do: [t]
  def targets(%ConditionalEdge{candidates: cs}), do: cs
  def targets(%JoinEdge{target: t}), do: [t]

  @doc "The reserved start-node id."
  @spec start_id() :: atom()
  def start_id, do: @start

  @doc "The reserved end-node id."
  @spec end_id() :: atom()
  def end_id, do: @end_
end
