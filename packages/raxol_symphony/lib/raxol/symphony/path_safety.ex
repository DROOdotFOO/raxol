defmodule Raxol.Symphony.PathSafety do
  @moduledoc """
  Workspace path safety primitives.

  Implements SPEC s9.5 invariants:

  - **Invariant 1**: Coding agent runs only inside its per-issue workspace path
    (cwd check enforced at agent launch).
  - **Invariant 2**: Workspace path stays inside workspace root (prefix check
    on normalized absolute paths).
  - **Invariant 3**: Workspace key sanitized to `[A-Za-z0-9._-]` only.

  These checks are the baseline filesystem guarantee; they do not replace the
  agent's approval/sandbox policy.
  """

  @sanitize_pattern ~r/[^A-Za-z0-9._-]/u

  @doc """
  Sanitizes an issue identifier into a workspace key.

  Replaces any character outside `[A-Za-z0-9._-]` with `_`.
  """
  @spec sanitize_key(binary()) :: binary()
  def sanitize_key(identifier) when is_binary(identifier) do
    Regex.replace(@sanitize_pattern, identifier, "_")
  end

  @doc """
  Computes the absolute workspace path for an issue.

  Returns `{:ok, path}` when the resulting path is inside `workspace_root`,
  otherwise `{:error, :workspace_outside_root}`.
  """
  @spec workspace_path(Path.t(), binary()) ::
          {:ok, Path.t()} | {:error, :workspace_outside_root | :invalid_workspace_root}
  def workspace_path(workspace_root, identifier)
      when is_binary(workspace_root) and is_binary(identifier) do
    with {:ok, root} <- absolutize(workspace_root) do
      key = sanitize_key(identifier)
      candidate = Path.join(root, key) |> Path.expand()
      validate_inside_root(candidate, root)
    end
  end

  @doc """
  Validates that `path` is contained within `root`.

  Both arguments are normalized to absolute paths before comparison.

  Returns `{:ok, path}` (the normalized path) or
  `{:error, :workspace_outside_root}`.
  """
  @spec validate_inside_root(Path.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, :workspace_outside_root | :invalid_workspace_root}
  def validate_inside_root(path, root)
      when is_binary(path) and is_binary(root) do
    with {:ok, abs_path} <- absolutize(path),
         {:ok, abs_root} <- absolutize(root) do
      if inside?(abs_path, abs_root) do
        {:ok, abs_path}
      else
        {:error, :workspace_outside_root}
      end
    end
  end

  @doc """
  Computes the workspace path for an issue on a REMOTE host (issue #744).

  This is `workspace_path/2` for a path that names a directory on another
  machine. It deliberately does NOT use `Path.expand/1`: that resolves `~`
  against the ORCHESTRATOR's home and a relative path against the
  orchestrator's cwd, so a remote root would silently pick up local state and
  the containment check would then be measured against the wrong root.

  `..` and `.` segments are folded purely instead, and the result must stay
  inside `root` (Invariant 2). `root` must be rooted at `/` or `~`, since a
  relative remote root resolves against whatever directory the remote login
  shell happens to start in.
  """
  @spec remote_workspace_path(Path.t(), binary()) ::
          {:ok, Path.t()} | {:error, :workspace_outside_root | :invalid_workspace_root}
  def remote_workspace_path(root, identifier)
      when is_binary(root) and is_binary(identifier) do
    with {:ok, abs_root} <- normalize_remote(root) do
      # `sanitize_key/1` strips `/`, so a key cannot add a segment. It does
      # permit `.`, so `".."` survives as a whole segment -- the containment
      # check below is what rejects it.
      validate_inside_remote_root(
        join_remote_segment(abs_root, sanitize_key(identifier)),
        abs_root
      )
    end
  end

  @doc """
  Validates that a REMOTE `path` is contained within a remote `root`.

  The remote counterpart of `validate_inside_root/2`, normalizing both sides
  without consulting the local filesystem or environment.
  """
  @spec validate_inside_remote_root(Path.t(), Path.t()) ::
          {:ok, Path.t()} | {:error, :workspace_outside_root | :invalid_workspace_root}
  def validate_inside_remote_root(path, root)
      when is_binary(path) and is_binary(root) do
    with {:ok, abs_root} <- normalize_remote(root),
         {:ok, abs_path} <- normalize_remote(path) do
      if inside?(abs_path, abs_root) do
        {:ok, abs_path}
      else
        {:error, :workspace_outside_root}
      end
    end
  end

  @doc """
  Asserts that the current working directory matches `expected_path`.

  Used as the SPEC s9.5 Invariant 1 check immediately before launching a LOCAL
  coding-agent subprocess. A remote worker has no local cwd to check: its
  counterpart is the `cd WS && …` short-circuit that
  `Raxol.Symphony.Ssh.remote_bash/2` builds at the command boundary.
  """
  @spec assert_cwd!(Path.t()) :: :ok | no_return()
  def assert_cwd!(expected_path) when is_binary(expected_path) do
    {:ok, cwd} = File.cwd()

    if Path.expand(cwd) == Path.expand(expected_path) do
      :ok
    else
      raise "PathSafety: cwd #{inspect(cwd)} != expected workspace #{inspect(expected_path)}"
    end
  end

  # -- Internals --------------------------------------------------------------

  defp absolutize(""), do: {:error, :invalid_workspace_root}

  defp absolutize(path) when is_binary(path) do
    {:ok, Path.expand(path)}
  end

  # A remote root is usable only if the remote login shell will resolve it to
  # the same directory every time: absolute, or home-relative (`~`, `~user`),
  # which the login shell expands consistently.
  defp normalize_remote(""), do: {:error, :invalid_workspace_root}

  defp normalize_remote("/" <> rest), do: {:ok, fold_remote("/", rest)}

  defp normalize_remote("~" <> _ = path) do
    {prefix, rest} =
      case String.split(path, "/", parts: 2) do
        [only] -> {only, ""}
        [head, tail] -> {head, tail}
      end

    {:ok, fold_remote(prefix, rest)}
  end

  defp normalize_remote(_relative), do: {:error, :invalid_workspace_root}

  # Fold `.` and `..` without touching the filesystem. `..` past the root is
  # clamped rather than escaping, so a root can never normalize above itself.
  defp fold_remote(prefix, rest) do
    rest
    |> String.split("/")
    |> Enum.reduce([], fn
      "", acc -> acc
      ".", acc -> acc
      "..", [_popped | tail] -> tail
      "..", [] -> []
      segment, acc -> [segment | acc]
    end)
    |> Enum.reverse()
    |> join_remote(prefix)
  end

  defp join_remote([], "/"), do: "/"
  defp join_remote([], prefix), do: prefix
  defp join_remote(segments, "/"), do: "/" <> Enum.join(segments, "/")
  defp join_remote(segments, prefix), do: prefix <> "/" <> Enum.join(segments, "/")

  defp join_remote_segment("/", segment), do: "/" <> segment
  defp join_remote_segment(root, segment), do: root <> "/" <> segment

  defp inside?(path, root) do
    # Append `/` so that `/foo/barbaz` is not considered inside `/foo/bar`.
    path_with_sep = path <> "/"
    root_with_sep = ensure_trailing_slash(root)
    path == root or String.starts_with?(path_with_sep, root_with_sep)
  end

  defp ensure_trailing_slash(path) do
    if String.ends_with?(path, "/"), do: path, else: path <> "/"
  end
end
