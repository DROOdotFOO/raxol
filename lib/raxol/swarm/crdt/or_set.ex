defmodule Raxol.Swarm.CRDT.ORSet do
  @moduledoc """
  Observed-Remove Set CRDT.

  Add-wins semantics: concurrent add and remove of the same element
  results in the element being present. Each add generates a unique dot
  (node + counter). Remove records all observed dots for that element.
  An element is present if it has any dot not in the remove set.
  """

  @behaviour Raxol.Swarm.CRDT

  @type dot :: {node(), pos_integer()}

  @type t :: %__MODULE__{
          entries: %{term() => MapSet.t(dot())},
          removed: MapSet.t(dot()),
          clock: %{node() => non_neg_integer()}
        }

  defstruct entries: %{}, removed: MapSet.new(), clock: %{}

  @doc "Creates an empty OR-Set."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Adds an element to the set, generating a unique dot."
  @spec add(t(), term(), node()) :: t()
  def add(%__MODULE__{} = set, element, node \\ Node.self()) do
    counter = Map.get(set.clock, node, 0) + 1
    dot = {node, counter}
    clock = Map.put(set.clock, node, counter)

    existing_dots = Map.get(set.entries, element, MapSet.new())
    entries = Map.put(set.entries, element, MapSet.put(existing_dots, dot))

    %__MODULE__{set | entries: entries, clock: clock}
  end

  @doc """
  Removes an element from the set by recording all its current dots
  as removed. Only dots observed at this point are removed -- concurrent
  adds with new dots will survive.
  """
  @spec remove(t(), term()) :: t()
  def remove(%__MODULE__{} = set, element) do
    case Map.get(set.entries, element) do
      nil ->
        set

      dots ->
        removed = MapSet.union(set.removed, dots)
        entries = Map.delete(set.entries, element)
        %__MODULE__{set | entries: entries, removed: removed}
    end
  end

  @doc "Returns true if the element is in the set."
  @spec member?(t(), term()) :: boolean()
  def member?(%__MODULE__{} = set, element) do
    case Map.get(set.entries, element) do
      nil -> false
      dots -> present?(dots, set.removed)
    end
  end

  @doc "Returns all elements currently in the set."
  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{} = set) do
    set.entries
    |> Enum.filter(fn {_elem, dots} -> present?(dots, set.removed) end)
    |> Enum.map(fn {elem, _dots} -> elem end)
  end

  @doc "Returns the number of elements in the set."
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{} = set) do
    Enum.count(set.entries, fn {_elem, dots} -> present?(dots, set.removed) end)
  end

  @doc """
  Merges two OR-Sets. For each element, union the dots. Union the
  removed sets. An element survives if it has any dot not in the
  merged removed set.
  """
  @impl Raxol.Swarm.CRDT
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    clock =
      Map.merge(a.clock, b.clock, fn _node, ca, cb -> max(ca, cb) end)

    removed = MapSet.union(a.removed, b.removed)

    entries =
      Map.merge(a.entries, b.entries, fn _key, dots_a, dots_b ->
        MapSet.union(dots_a, dots_b)
      end)

    # Prune entries where all dots are removed
    entries =
      Map.reject(entries, fn {_key, dots} -> MapSet.subset?(dots, removed) end)

    %__MODULE__{entries: entries, removed: removed, clock: clock}
  end

  # An element survives (add-wins) if it has any dot not observed-removed.
  @spec present?(MapSet.t(dot()), MapSet.t(dot())) :: boolean()
  defp present?(dots, removed), do: not MapSet.subset?(dots, removed)
end
