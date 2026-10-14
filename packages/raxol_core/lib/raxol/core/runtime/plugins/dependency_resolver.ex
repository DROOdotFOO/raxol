defmodule Raxol.Core.Runtime.Plugins.DependencyResolver do
  @moduledoc """
  Install-time and load-time dependency resolution for plugins.

  Uses Kahn's algorithm for topological sort with cycle detection,
  conflict checking, and capability matching. The sort is stable: plugins
  that are ready at the same time keep their input order, so the result is
  deterministic for a given manifest list.

  `Raxol.Plugins.Lifecycle.Dependencies` delegates its ordering and cycle
  detection here; this module is the only Kahn/DFS implementation.
  """

  alias Raxol.Core.Runtime.Plugins.Manifest

  @type resolution :: {:ok, load_order :: [atom()]} | {:error, reason()}
  @type reason ::
          {:cycle, [atom()]}
          | {:missing, plugin :: atom(), dependency :: atom()}
          | {:conflict, atom(), atom()}
          | {:unmet_capability, plugin :: atom(), capability :: atom()}

  @doc """
  Resolves load order for a set of manifests using topological sort.

  Returns `{:ok, [plugin_id]}` in dependency order (dependencies first),
  or `{:error, reason}` on failure.
  """
  @spec resolve([Manifest.t()]) :: resolution()
  def resolve(manifests) when is_list(manifests) do
    with :ok <- check_conflicts(manifests),
         :ok <- satisfy_capabilities(manifests),
         :ok <- check_missing_deps(manifests) do
      topo_sort(manifests)
    end
  end

  @doc """
  Resolves load order for new manifests given already-loaded plugin ids.

  Treats `already_loaded` as satisfied dependencies that don't need ordering.
  """
  @spec resolve_incremental([Manifest.t()], already_loaded :: [atom()]) ::
          resolution()
  def resolve_incremental(manifests, already_loaded) when is_list(manifests) do
    loaded_set = MapSet.new(already_loaded)
    all_ids = MapSet.union(loaded_set, MapSet.new(Enum.map(manifests, & &1.id)))

    missing =
      for m <- manifests,
          {dep_id, _} <- m.depends_on,
          dep_id not in all_ids,
          do: {m.id, dep_id}

    case missing do
      [] ->
        # Strip deps that are already loaded so topo_sort only sees new plugins
        stripped =
          Enum.map(manifests, fn m ->
            filtered_deps =
              Enum.reject(m.depends_on, fn {dep_id, _} ->
                dep_id in loaded_set
              end)

            %{m | depends_on: filtered_deps}
          end)

        topo_sort(stripped)

      [{plugin, dep} | _] ->
        {:error, {:missing, plugin, dep}}
    end
  end

  @doc """
  Checks for conflicts between manifests.
  """
  @spec check_conflicts([Manifest.t()]) ::
          :ok | {:error, {:conflict, atom(), atom()}}
  def check_conflicts(manifests) do
    id_set = MapSet.new(Enum.map(manifests, & &1.id))

    conflict =
      Enum.find_value(manifests, fn m ->
        Enum.find_value(m.conflicts_with, fn cid ->
          if cid in id_set, do: {m.id, cid}
        end)
      end)

    case conflict do
      nil -> :ok
      {a, b} -> {:error, {:conflict, a, b}}
    end
  end

  @doc """
  Checks that all `requires` capabilities are satisfied by some plugin's `provides`.
  """
  @spec satisfy_capabilities([Manifest.t()]) ::
          :ok | {:error, {:unmet_capability, atom(), atom()}}
  def satisfy_capabilities(manifests) do
    provided =
      manifests
      |> Enum.flat_map(& &1.provides)
      |> MapSet.new()

    unmet =
      Enum.find_value(manifests, fn m ->
        Enum.find_value(m.requires, fn cap ->
          if cap not in provided, do: {m.id, cap}
        end)
      end)

    case unmet do
      nil -> :ok
      {plugin, cap} -> {:error, {:unmet_capability, plugin, cap}}
    end
  end

  @doc """
  Depth-first walk of `graph` (`%{node => [successor]}`) from `start`.

  Returns the cycle path as a list starting and ending with the same node
  (`[:a, :b, :a]`), or `nil` when no cycle is reachable from `start`.
  """
  @spec find_cycle(term(), %{term() => [term()]}) :: [term()] | nil
  def find_cycle(start, graph), do: find_cycle(start, graph, [], MapSet.new())

  defp find_cycle(node, graph, stack, seen) do
    cond do
      node in stack ->
        path = stack |> Enum.take_while(&(&1 != node)) |> Enum.reverse()
        [node | path] ++ [node]

      MapSet.member?(seen, node) ->
        nil

      true ->
        graph
        |> Map.get(node, [])
        |> Enum.find_value(fn next ->
          find_cycle(next, graph, [node | stack], MapSet.put(seen, node))
        end)
    end
  end

  # -- Private: Kahn's algorithm --------------------------------------------

  defp check_missing_deps(manifests) do
    id_set = MapSet.new(Enum.map(manifests, & &1.id))

    missing =
      Enum.find_value(manifests, fn m ->
        Enum.find_value(m.depends_on, fn {dep_id, _} ->
          if dep_id not in id_set, do: {m.id, dep_id}
        end)
      end)

    case missing do
      nil -> :ok
      {plugin, dep} -> {:error, {:missing, plugin, dep}}
    end
  end

  defp topo_sort(manifests) do
    order = Enum.map(manifests, & &1.id)
    graph = build_graph(manifests)
    in_degrees = compute_in_degrees(manifests)
    ready = Enum.filter(order, &(Map.get(in_degrees, &1, 0) == 0))

    case kahn_loop(ready, order, graph, in_degrees, []) do
      {:ok, sorted} -> {:ok, sorted}
      {:error, remaining} -> {:error, {:cycle, extract_cycle(remaining, graph)}}
    end
  end

  # edges point dependency -> dependent
  defp build_graph(manifests) do
    for m <- manifests, dep_id <- dep_ids(m), reduce: %{} do
      acc -> Map.update(acc, dep_id, [m.id], &[m.id | &1])
    end
  end

  defp compute_in_degrees(manifests) do
    for m <- manifests,
        _dep_id <- dep_ids(m),
        reduce: Map.new(manifests, fn m -> {m.id, 0} end) do
      acc -> Map.update(acc, m.id, 1, &(&1 + 1))
    end
  end

  defp dep_ids(manifest) do
    manifest.depends_on |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
  end

  defp kahn_loop([], order, _graph, in_degrees, acc) do
    case Enum.filter(order, &(Map.get(in_degrees, &1, 0) > 0)) do
      [] -> {:ok, Enum.reverse(acc)}
      remaining -> {:error, remaining}
    end
  end

  defp kahn_loop([node | rest], order, graph, in_degrees, acc) do
    {next_ready, in_degrees} =
      graph
      |> Map.get(node, [])
      |> Enum.reduce({[], in_degrees}, fn dependent, {ready, degs} ->
        degs = Map.update(degs, dependent, 0, &(&1 - 1))

        case Map.get(degs, dependent) do
          0 -> {[dependent | ready], degs}
          _ -> {ready, degs}
        end
      end)

    # keep input order among newly-ready nodes
    queued = rest ++ Enum.filter(order, &(&1 in next_ready))
    kahn_loop(queued, order, graph, in_degrees, [node | acc])
  end

  # Name the actual cycle rather than every node stuck behind it.
  defp extract_cycle(remaining, graph) do
    subgraph = Map.new(remaining, &{&1, Map.get(graph, &1, [])})

    Enum.find_value(remaining, &find_cycle(&1, subgraph)) || remaining
  end
end
