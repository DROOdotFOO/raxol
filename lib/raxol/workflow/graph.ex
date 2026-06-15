defmodule Raxol.Workflow.Graph do
  @moduledoc """
  Immutable graph builder for `Raxol.Workflow`.

  Build a graph by piping `add_node/3`, `add_edge/3`,
  `add_guarded_edge/4`, `add_conditional_edge/4` (and the upcoming
  `add_join/4` / `add_channel/4`) onto a `new/1` seed, then freeze with
  `compile/2`.

  ## Example

      alias Raxol.Workflow.Graph

      {:ok, compiled} =
        Graph.new(:summarizer)
        |> Graph.add_node(:fetch, fn s -> {:ok, Map.put(s, :data, "x")} end)
        |> Graph.add_node(:render, fn s -> {:ok, Map.put(s, :rendered, true)} end)
        |> Graph.add_edge(:__start__, :fetch)
        |> Graph.add_edge(:fetch, :render)
        |> Graph.add_edge(:render, :__end__)
        |> Graph.compile()

  ## Reserved node ids

  - `:__start__` -- virtual entry node, present in every graph
  - `:__end__` -- virtual exit node, present in every graph

  Authors must add at least one edge from `:__start__` and at least
  one edge into `:__end__`. `compile/2` enforces these rules along
  with reachability and absence-of-orphans.
  """

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Edge
  alias Raxol.Workflow.Edge.ConditionalEdge
  alias Raxol.Workflow.Edge.Edge, as: StaticEdge
  alias Raxol.Workflow.Edge.GuardedEdge
  alias Raxol.Workflow.Node

  @type t :: %__MODULE__{
          id: atom() | binary(),
          nodes: %{Node.id() => Node.t()},
          edges: [Edge.t()]
        }

  defstruct id: nil, nodes: %{}, edges: []

  @start :__start__
  @end_ :__end__

  @doc "Construct a new, empty graph with the given id."
  @spec new(atom() | binary()) :: t()
  def new(id) when is_atom(id) or is_binary(id), do: %__MODULE__{id: id}

  @doc """
  Add a node to the graph. The `body` argument selects the node shape:

  - A 1-arity function builds a `FunctionNode`.
  - A `{module, opts}` tuple builds a `BehaviourNode`.
  - A struct builds a `TypedNode`.
  """
  @spec add_node(t(), Node.id(), term()) :: t()
  def add_node(%__MODULE__{} = graph, id, body) do
    node = build_node(id, body)
    put_node(graph, node)
  end

  @doc "Add a static edge from `from` to `to`."
  @spec add_edge(t(), Node.id(), Node.id()) :: t()
  def add_edge(%__MODULE__{} = graph, from, to)
      when is_atom(from) or is_binary(from) do
    put_edge(graph, %StaticEdge{from: from, to: to})
  end

  @doc """
  Add a guarded edge from `from` to `to`. The guard receives the
  workflow state; the edge is taken only when the guard returns truthy.
  """
  @spec add_guarded_edge(t(), Node.id(), Node.id(), (any() -> any())) :: t()
  def add_guarded_edge(%__MODULE__{} = graph, from, to, guard)
      when is_function(guard, 1) do
    put_edge(graph, %GuardedEdge{from: from, to: to, guard: guard})
  end

  @doc """
  Add a conditional fan-out edge from `from`. The `chooser` receives
  the state and returns the next node id (or a list of ids for
  parallel fan-out). `candidates` declares the set of possible
  destinations so `compile/2` can validate them.
  """
  @spec add_conditional_edge(t(), Node.id(), [Node.id()], (any() -> any())) ::
          t()
  def add_conditional_edge(%__MODULE__{} = graph, from, candidates, chooser)
      when is_list(candidates) and candidates != [] and is_function(chooser, 1) do
    put_edge(graph, %ConditionalEdge{
      from: from,
      candidates: candidates,
      chooser: chooser
    })
  end

  @doc """
  Freeze the graph for execution.

  Runs the full validation pipeline (no orphan nodes, every node
  reachable from `:__start__`, every node has a path to `:__end__`,
  conditional candidates exist in the graph) and returns a
  `Raxol.Workflow.Compiled` struct or a structured error.

  ## Options

    * `:failure_policy` -- one of `:retry`, `:halt`, `:compensate` (default `:halt`)
    * `:max_attempts` -- when `:failure_policy` is `:retry`, the
      maximum number of attempts per node (default `3`). Includes the
      initial attempt; `1` disables retries.
    * `:retry_backoff_ms` -- base backoff delay between retries; each
      subsequent retry doubles (default `100`).
    * `:step_timeout_ms` -- per-node timeout (default `60_000`)
    * `:run_timeout_ms` -- total run timeout (default `3_600_000`)
    * `:saver` -- `Raxol.Workflow.Checkpoint.Saver` module (defaults to `Ets`)

  These options are stored on `Compiled` and consumed by the runtime.
  """
  @spec compile(t(), keyword()) ::
          {:ok, Compiled.t()}
          | {:error, validation_error()}
  def compile(%__MODULE__{} = graph, opts \\ []) do
    with :ok <- validate_has_start_edge(graph),
         :ok <- validate_has_end_edge(graph),
         :ok <- validate_edges_reference_known_nodes(graph),
         :ok <- validate_no_orphans(graph),
         :ok <- validate_reachable_from_start(graph),
         :ok <- validate_paths_to_end(graph) do
      {:ok,
       %Compiled{
         id: graph.id,
         nodes: graph.nodes,
         edges_by_source: index_edges_by_source(graph.edges),
         opts:
           opts
           |> Keyword.take(
             ~w(failure_policy max_attempts retry_backoff_ms step_timeout_ms run_timeout_ms saver)a
           )
           |> Map.new()
       }}
    end
  end

  @type validation_error ::
          {:missing_start_edge, atom()}
          | {:missing_end_edge, atom()}
          | {:unknown_node, [Node.id()]}
          | {:orphan_nodes, [Node.id()]}
          | {:unreachable_from_start, [Node.id()]}
          | {:cannot_reach_end, [Node.id()]}

  # --- Builder helpers ---

  defp build_node(id, fun) when is_function(fun, 1), do: Node.function(id, fun)

  defp build_node(id, {module, opts}) when is_atom(module),
    do: Node.behaviour(id, module, opts)

  defp build_node(id, %_{} = struct), do: Node.typed(id, struct)

  defp build_node(_id, other) do
    raise ArgumentError,
          "node body must be a 1-arity function, {module, opts} tuple, " <>
            "or struct; got: #{inspect(other)}"
  end

  defp put_node(%__MODULE__{nodes: nodes} = graph, node) do
    %{graph | nodes: Map.put(nodes, Node.id(node), node)}
  end

  defp put_edge(%__MODULE__{edges: edges} = graph, edge) do
    # Graphs are small (typically <100 edges); insertion-order storage
    # is more readable than reversed-list + Enum.reverse on read.
    # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
    %{graph | edges: edges ++ [edge]}
  end

  defp index_edges_by_source(edges) do
    Enum.group_by(edges, &Edge.from/1)
  end

  # --- Validation ---

  defp validate_has_start_edge(%__MODULE__{edges: edges}) do
    if Enum.any?(edges, fn e -> Edge.from(e) == @start end) do
      :ok
    else
      {:error, {:missing_start_edge, @start}}
    end
  end

  defp validate_has_end_edge(%__MODULE__{edges: edges}) do
    if Enum.any?(edges, fn e -> @end_ in Edge.targets(e) end) do
      :ok
    else
      {:error, {:missing_end_edge, @end_}}
    end
  end

  defp validate_edges_reference_known_nodes(%__MODULE__{
         nodes: nodes,
         edges: edges
       }) do
    known =
      nodes
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.put(@start)
      |> MapSet.put(@end_)

    referenced =
      edges
      |> Enum.flat_map(fn e -> [Edge.from(e) | Edge.targets(e)] end)
      |> MapSet.new()

    unknown = MapSet.difference(referenced, known) |> MapSet.to_list()

    if unknown == [] do
      :ok
    else
      {:error, {:unknown_node, Enum.sort(unknown)}}
    end
  end

  defp validate_no_orphans(%__MODULE__{nodes: nodes, edges: edges}) do
    in_play =
      edges
      |> Enum.flat_map(fn e -> [Edge.from(e) | Edge.targets(e)] end)
      |> MapSet.new()

    orphans =
      nodes
      |> Map.keys()
      |> Enum.reject(&MapSet.member?(in_play, &1))

    if orphans == [] do
      :ok
    else
      {:error, {:orphan_nodes, Enum.sort(orphans)}}
    end
  end

  defp validate_reachable_from_start(%__MODULE__{nodes: nodes, edges: edges}) do
    forward = adjacency(edges)
    reachable = bfs(@start, forward)
    declared = MapSet.new(Map.keys(nodes))
    missing = MapSet.difference(declared, reachable) |> MapSet.to_list()

    if missing == [] do
      :ok
    else
      {:error, {:unreachable_from_start, Enum.sort(missing)}}
    end
  end

  defp validate_paths_to_end(%__MODULE__{nodes: nodes, edges: edges}) do
    backward = adjacency_reversed(edges)
    can_reach_end = bfs(@end_, backward)
    declared = MapSet.new(Map.keys(nodes))
    cannot = MapSet.difference(declared, can_reach_end) |> MapSet.to_list()

    if cannot == [] do
      :ok
    else
      {:error, {:cannot_reach_end, Enum.sort(cannot)}}
    end
  end

  defp adjacency(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      from = Edge.from(edge)

      Enum.reduce(Edge.targets(edge), acc, fn to, inner ->
        Map.update(inner, from, [to], fn existing -> [to | existing] end)
      end)
    end)
  end

  defp adjacency_reversed(edges) do
    Enum.reduce(edges, %{}, fn edge, acc ->
      from = Edge.from(edge)

      Enum.reduce(Edge.targets(edge), acc, fn to, inner ->
        Map.update(inner, to, [from], fn existing -> [from | existing] end)
      end)
    end)
  end

  defp bfs(start, adjacency) do
    do_bfs([start], MapSet.new([start]), adjacency)
  end

  defp do_bfs([], visited, _adj), do: visited

  defp do_bfs([node | rest], visited, adj) do
    neighbors = Map.get(adj, node, [])
    new_neighbors = Enum.reject(neighbors, &MapSet.member?(visited, &1))
    visited2 = Enum.reduce(new_neighbors, visited, &MapSet.put(&2, &1))
    do_bfs(rest ++ new_neighbors, visited2, adj)
  end
end
