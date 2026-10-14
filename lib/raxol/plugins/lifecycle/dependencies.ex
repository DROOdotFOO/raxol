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

  alias Raxol.Core.Runtime.Plugins.{DependencyResolver, Manifest}

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

  Delegates to `Raxol.Core.Runtime.Plugins.DependencyResolver`, mapping plugin
  names to manifest ids and back.
  """
  def resolve_plugin_order(initialized_plugins) do
    manifests = Enum.map(initialized_plugins, &manifest/1)
    in_batch = MapSet.new(manifests, & &1.id)

    outside =
      manifests
      |> Enum.flat_map(fn m -> Enum.map(m.depends_on, &elem(&1, 0)) end)
      |> Enum.reject(&MapSet.member?(in_batch, &1))

    case DependencyResolver.resolve_incremental(manifests, outside) do
      {:ok, ids} ->
        {:ok, Enum.map(ids, &Atom.to_string/1)}

      {:error, {:cycle, ids}} ->
        {:error, :circular_dependency, Enum.map(ids, &Atom.to_string/1), []}
    end
  end

  @doc """
  Rejects a plugin whose dependencies close a cycle, directly or transitively.
  """
  def check_for_circular_dependency(plugin, manager) do
    name = normalize_plugin_key(plugin.name)
    graph = dependency_graph(plugin, manager)

    case DependencyResolver.find_cycle(name, graph) do
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

  defp manifest(plugin) do
    %Manifest{
      id: String.to_atom(normalize_plugin_key(plugin.name)),
      depends_on:
        Enum.map(dependencies(plugin), fn {name, req, _orig} ->
          {String.to_atom(name), req}
        end)
    }
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
