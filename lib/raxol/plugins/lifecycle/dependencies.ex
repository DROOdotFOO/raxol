defmodule Raxol.Plugins.Lifecycle.Dependencies do
  @moduledoc """
  Dependency validation, cycle detection, and load-order resolution for plugins.

  A declared dependency is either a bare name (atom or string) or a
  `{name, requirement}` tuple whose requirement is a `Version` requirement
  string such as `">= 1.0.0"` or `"~> 2.1"`. Names normalize to strings.

  Three guarantees:

  * `resolve_plugin_order/1` returns a topological order, so a plugin is never
    loaded before something it depends on.
  * `check_for_circular_dependency/2` walks the transitive graph, so an
    indirect cycle (`a -> b -> a`) is rejected, not just self-reference.
  * `check_dependencies/2` honours the requirement half of a dependency tuple,
    so a plugin cannot be satisfied by an incompatible version.
  """

  @type dep :: {String.t(), String.t() | nil, term()}

  # ---------------------------------------------------------------- public API

  def validate_plugin_dependencies(plugin, manager) do
    case check_for_circular_dependency(plugin, manager) do
      :ok -> check_dependencies(plugin, manager)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies every declared dependency is loaded and version-compatible.

  Returns `:ok`, `{:error, :missing_dependencies, missing, chain}`, or
  `{:error, :version_mismatch, mismatches, chain}`.
  """
  def check_dependencies(plugin, manager) do
    loaded = loaded_by_name(manager)
    chain = [normalize_plugin_key(plugin.name)]

    {present, missing} =
      plugin
      |> dependencies()
      |> Enum.split_with(fn {name, _req, _orig} ->
        Map.has_key?(loaded, name)
      end)

    case missing do
      [] ->
        check_versions(present, loaded, chain)

      _ ->
        {:error, :missing_dependencies, Enum.map(missing, &elem(&1, 2)), chain}
    end
  end

  @doc """
  Orders plugins so each one follows every dependency it declares.

  Dependencies outside the given batch are assumed already loaded and place no
  constraint on this ordering. Returns `{:ok, names}` or
  `{:error, :circular_dependency, cycle, []}`.
  """
  def resolve_plugin_order(initialized_plugins) do
    order = Enum.map(initialized_plugins, &normalize_plugin_key(&1.name))
    in_batch = MapSet.new(order)

    # edges: dependency -> dependent, restricted to plugins in this batch
    edges =
      Enum.reduce(initialized_plugins, %{}, fn plugin, acc ->
        name = normalize_plugin_key(plugin.name)

        plugin
        |> dependencies()
        |> Enum.map(fn {dep, _req, _orig} -> dep end)
        |> Enum.filter(&MapSet.member?(in_batch, &1))
        |> Enum.reduce(acc, fn dep, inner ->
          Map.update(inner, dep, [name], &[name | &1])
        end)
      end)

    indegree =
      Enum.reduce(initialized_plugins, %{}, fn plugin, acc ->
        name = normalize_plugin_key(plugin.name)

        count =
          plugin
          |> dependencies()
          |> Enum.map(fn {dep, _req, _orig} -> dep end)
          |> Enum.filter(&MapSet.member?(in_batch, &1))
          |> Enum.uniq()
          |> length()

        Map.put(acc, name, count)
      end)

    case kahn(order, edges, indegree) do
      {:ok, sorted} ->
        {:ok, sorted}

      {:error, remaining} ->
        {:error, :circular_dependency, extract_cycle(remaining, edges), []}
    end
  end

  @doc """
  Rejects a plugin whose dependencies close a cycle, directly or transitively.
  """
  def check_for_circular_dependency(plugin, manager) do
    name = normalize_plugin_key(plugin.name)
    graph = dependency_graph(plugin, manager)

    case find_cycle(name, graph, [], MapSet.new()) do
      nil -> :ok
      cycle -> {:error, {:circular_dependency, cycle}}
    end
  end

  def normalize_plugin_key(key) when is_atom(key), do: Atom.to_string(key)
  def normalize_plugin_key(key) when is_binary(key), do: key
  def normalize_plugin_key(key), do: inspect(key)

  # ------------------------------------------------------------------ versions

  defp check_versions(present, loaded, chain) do
    mismatches =
      present
      |> Enum.filter(fn {name, req, _orig} ->
        req != nil and not version_ok?(Map.get(loaded, name), req)
      end)
      |> Enum.map(fn {name, req, _orig} ->
        {name, req, version_of(Map.get(loaded, name))}
      end)

    case mismatches do
      [] -> :ok
      _ -> {:error, :version_mismatch, mismatches, chain}
    end
  end

  defp version_ok?(loaded_plugin, requirement) do
    with version when is_binary(version) <- version_of(loaded_plugin),
         {:ok, parsed} <- Version.parse(version),
         {:ok, req} <- Version.parse_requirement(requirement) do
      Version.match?(parsed, req)
    else
      _ -> false
    end
  end

  defp version_of(nil), do: nil
  defp version_of(%{version: version}), do: version
  defp version_of(_), do: nil

  # -------------------------------------------------------------------- graphs

  # %{name => [dependency_name]} over everything the manager knows plus the
  # candidate plugin, which may not be registered yet.
  defp dependency_graph(plugin, manager) do
    manager.plugins
    |> Enum.reduce(%{}, fn {key, loaded}, acc ->
      Map.put(acc, normalize_plugin_key(key), dependency_names(loaded))
    end)
    |> Map.put(normalize_plugin_key(plugin.name), dependency_names(plugin))
  end

  defp dependency_names(plugin) do
    plugin |> dependencies() |> Enum.map(fn {name, _req, _orig} -> name end)
  end

  # Depth-first walk returning the cycle path if one closes back on a node
  # already on the current stack.
  defp find_cycle(node, graph, stack, seen) do
    cond do
      node in stack ->
        Enum.reverse([node | Enum.take_while(stack, &(&1 != node))]) ++ [node]

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

  # Kahn's algorithm, preserving input order among equally-ready nodes so the
  # result is deterministic.
  defp kahn(order, edges, indegree) do
    ready = Enum.filter(order, &(Map.get(indegree, &1, 0) == 0))
    kahn_loop(ready, order, edges, indegree, [])
  end

  defp kahn_loop([], order, _edges, indegree, acc) do
    remaining = Enum.filter(order, &(Map.get(indegree, &1, 0) > 0))

    case remaining do
      [] -> {:ok, Enum.reverse(acc)}
      _ -> {:error, remaining}
    end
  end

  defp kahn_loop([node | rest], order, edges, indegree, acc) do
    {next_ready, indegree} =
      edges
      |> Map.get(node, [])
      |> Enum.reduce({[], indegree}, fn dependent, {ready, deg} ->
        deg = Map.update(deg, dependent, 0, &(&1 - 1))

        case Map.get(deg, dependent) do
          0 -> {[dependent | ready], deg}
          _ -> {ready, deg}
        end
      end)

    # keep input order among newly-ready nodes
    queued = rest ++ Enum.filter(order, &(&1 in next_ready))
    kahn_loop(queued, order, edges, indegree, [node | acc])
  end

  defp extract_cycle(remaining, edges) do
    # edges point dependency -> dependent; walk that direction to name a cycle
    graph = Map.new(remaining, fn node -> {node, Map.get(edges, node, [])} end)

    remaining
    |> Enum.find_value(&find_cycle(&1, graph, [], MapSet.new()))
    |> case do
      nil -> remaining
      cycle -> cycle
    end
  end

  # -------------------------------------------------------------- dependencies

  defp loaded_by_name(manager) do
    manager
    |> Raxol.Plugins.Manager.list_plugins()
    |> Map.new(fn plugin -> {normalize_plugin_key(plugin.name), plugin} end)
  end

  @spec dependencies(map()) :: [dep()]
  defp dependencies(plugin) do
    (Map.get(plugin, :dependencies) || [])
    |> Enum.map(&normalize_dependency/1)
  end

  defp normalize_dependency({name, requirement} = orig)
       when is_binary(requirement),
       do: {normalize_plugin_key(name), requirement, orig}

  defp normalize_dependency({name, _other} = orig),
    do: {normalize_plugin_key(name), nil, orig}

  defp normalize_dependency(name) when is_atom(name) or is_binary(name),
    do: {normalize_plugin_key(name), nil, name}

  defp normalize_dependency(other),
    do: {normalize_plugin_key(other), nil, other}
end
