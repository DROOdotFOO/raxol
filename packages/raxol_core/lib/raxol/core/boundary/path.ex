defmodule Raxol.Core.Boundary.Path do
  @moduledoc """
  Path-traversal confinement: resolve an untrusted `requested` reference under
  a trusted `root` and prove the result stays inside that root, rejecting every
  escape *before* any syscall touches the target.

  This is the centralized seed of the "same gap, four patches" boundary
  (PR #569 thread 2). It is one of **two** boundary confinements — the other is
  `Raxol.Core.Boundary.TermText` (terminal-injection). They share a threat
  narrative but nothing else, so they are two functions, not one.

  Seeded from the proven `Raxol.AgentClientProtocol.Client.FsSandbox.resolve/2`
  (leaf-symlink *and* symlinked-ancestor resolution, cycle-guarded, rejecting
  before any target syscall) plus PA-6's ref-shape gate. The Agent Client Protocol package keeps
  its own tested copy as a documented intentional duplicate; both bind to the
  same shared conformance vectors (`test/support/boundary_vectors/`) so drift is
  a red test, not a silent fork.

  ## Rule order

  `confine/3` enforces these in order. Everything below the ref gate happens
  before any syscall on the *target* (the only I/O is `:file.read_link` during
  symlink resolution, which reads links, never opens/creates the target):

  1. **Ref-shape gate** — when `ref_format:` is given, the RAW `requested`
     string must match the regex, else `{:error, :malformed_ref}`. Refs are
     validated as opaque tokens before they are ever treated as paths. Skipped
     when the option is absent.
  2. **Lexical confinement** — `root = Path.expand(root)`;
     `lexical = Path.expand(Path.join(root, requested))`. Unless `lexical`
     equals `root` or starts with `root <> "/"`, `{:error, :path_traversal}`.
     (An absolute `requested` is jailed under `root` by `Path.join`, not
     honored.)
  3. **Symlink resolution** — a hand-rolled realpath of BOTH `root` and
     `lexical`: follows a leaf symlink, recurses into the parent so a symlinked
     ancestor directory is caught too, resolves POSIX relative link targets
     against the link's own directory, and works for a not-yet-existing write
     leaf by resolving the deepest existing ancestor. Depth-capped at 40;
     a cycle yields `{:error, :too_many_symlinks}`.
  4. **Post-resolution re-check** — the real path must still be within the real
     root, else `{:error, :symlink_escape}`.

  Total function: never raises on bad input (a non-binary `root`/`requested`
  yields `{:error, :invalid_input}`).
  """

  @max_symlink_depth 40

  @typedoc "Rejection reason returned by `confine/3`."
  @type reason ::
          :malformed_ref
          | :path_traversal
          | :too_many_symlinks
          | :symlink_escape
          | :invalid_input

  @doc """
  Confine `requested` under `root`.

  Returns `{:ok, real_absolute_path}` when the fully symlink-resolved target
  provably stays inside the resolved root, or `{:error, reason}` (see the
  moduledoc rule order for the exact reason per rejection).

  ## Options

    * `:ref_format` — a `Regex.t()` the RAW `requested` string must match before
      any resolution (e.g. PA-6's
      `~r/^(blobs|snapshots)\\/[0-9a-f]{64}(\\.json)?$/`). Absent = no gate.
  """
  @spec confine(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, reason()}
  def confine(root, requested, opts \\ [])

  def confine(root, requested, opts)
      when is_binary(root) and is_binary(requested) and is_list(opts) do
    with :ok <- ref_gate(requested, Keyword.get(opts, :ref_format)),
         expanded_root = Path.expand(root),
         lexical = Path.expand(Path.join(expanded_root, requested)),
         :ok <- lexical_gate(expanded_root, lexical),
         {:ok, root_real} <- real_path(expanded_root),
         {:ok, real} <- real_path(lexical),
         :ok <- escape_gate(root_real, real) do
      {:ok, real}
    end
  end

  def confine(_root, _requested, _opts), do: {:error, :invalid_input}

  # --- Rule 1: ref-shape gate ------------------------------------------------

  defp ref_gate(_requested, nil), do: :ok

  defp ref_gate(requested, %Regex{} = re) do
    if Regex.match?(re, requested), do: :ok, else: {:error, :malformed_ref}
  end

  # A ref_format that is present but not a Regex is a misconfiguration; fail
  # closed rather than silently skipping the gate or raising.
  defp ref_gate(_requested, _other), do: {:error, :malformed_ref}

  # --- Rule 2: lexical confinement -------------------------------------------

  defp lexical_gate(root, lexical) do
    if within?(root, lexical), do: :ok, else: {:error, :path_traversal}
  end

  # --- Rule 4: post-resolution re-check --------------------------------------

  defp escape_gate(root_real, real) do
    if within?(root_real, real), do: :ok, else: {:error, :symlink_escape}
  end

  defp within?(root, path), do: path == root or String.starts_with?(path, root <> "/")

  # --- Rule 3: hand-rolled realpath ------------------------------------------
  #
  # If `path` itself is a symlink, follow it (a relative target resolves against
  # the symlink's OWN directory, per POSIX); otherwise recurse into the parent
  # so a symlinked ANCESTOR is caught, then rejoin the basename. Both existing
  # paths (read case) and not-yet-existing ones (write case: leaf absent, every
  # ancestor present) resolve correctly. Depth-guarded against symlink cycles.
  defp real_path(path), do: real_path(path, 0)

  defp real_path(_path, depth) when depth > @max_symlink_depth,
    do: {:error, :too_many_symlinks}

  defp real_path(path, depth) do
    case :file.read_link(path) do
      {:ok, target} ->
        target = to_string(target)

        resolved =
          if Path.type(target) == :absolute,
            do: target,
            else: Path.join(Path.dirname(path), target)

        real_path(Path.expand(resolved), depth + 1)

      {:error, _not_a_symlink_or_missing} ->
        case Path.dirname(path) do
          ^path ->
            {:ok, path}

          parent ->
            case real_path(parent, depth + 1) do
              {:ok, real_parent} -> {:ok, Path.join(real_parent, Path.basename(path))}
              error -> error
            end
        end
    end
  end
end
