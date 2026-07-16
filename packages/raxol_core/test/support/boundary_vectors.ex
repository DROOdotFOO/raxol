defmodule Raxol.Core.Boundary.Vectors do
  @moduledoc """
  Loader + fixture materializer for the shared boundary conformance vectors in
  `test/support/boundary_vectors/*.json`.

  These vectors are the single source of truth for the must-reject / must-accept
  boundary tables. `Raxol.Core.Boundary.Path` (here) and the Agent Client Protocol package's
  `FsSandbox` both drive the SAME `path_*_vectors.json` — a divergence is a red
  test, not a silent fork. See `test/support/boundary_vectors/README.md`.
  """

  @dir Path.join(__DIR__, "boundary_vectors")

  @doc "Load and decode a vectors JSON file; returns the `\"vectors\"` list."
  @spec load(String.t()) :: [map()]
  def load(filename) do
    @dir
    |> Path.join(filename)
    |> File.read!()
    |> JSON.decode!()
    |> Map.fetch!("vectors")
  end

  @doc """
  Materialize a vector's `setup` list under `base` (a fresh tmp dir). Each entry
  is one of `%{"dir" => p}`, `%{"file" => p, "content" => c}`, or
  `%{"symlink" => p, "target" => t}` — all paths relative to `base`. Dirs and
  files are created first, symlinks last (a symlink target need not exist).
  """
  @spec materialize(String.t(), [map()]) :: :ok
  def materialize(base, setup) when is_binary(base) and is_list(setup) do
    {symlinks, rest} = Enum.split_with(setup, &Map.has_key?(&1, "symlink"))

    Enum.each(rest, fn
      %{"dir" => rel} ->
        File.mkdir_p!(Path.join(base, rel))

      %{"file" => rel} = entry ->
        abs = Path.join(base, rel)
        File.mkdir_p!(Path.dirname(abs))
        File.write!(abs, Map.get(entry, "content", ""))
    end)

    Enum.each(symlinks, fn %{"symlink" => rel, "target" => target} ->
      abs = Path.join(base, rel)
      File.mkdir_p!(Path.dirname(abs))
      :ok = File.ln_s!(target, abs)
    end)

    :ok
  end

  @doc "The absolute root path for a vector: `base/<root>` (`\".\"` = base itself)."
  @spec root_path(String.t(), map()) :: String.t()
  def root_path(base, %{"root" => "."}), do: base
  def root_path(base, %{"root" => root}), do: Path.join(base, root)

  @doc "Build the `confine/3` opts keyword list for a vector (compiles `ref_format`)."
  @spec opts(map()) :: keyword()
  def opts(%{"ref_format" => src}) when is_binary(src), do: [ref_format: Regex.compile!(src)]
  def opts(_vector), do: []
end
