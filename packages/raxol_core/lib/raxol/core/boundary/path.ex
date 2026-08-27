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
  # Resolve `path` to its real location by walking components left-to-right from
  # the filesystem root, carrying a fully-resolved real `base`. A symlink is
  # followed against `base` -- its REAL parent -- so a relative target (including
  # `..`) resolves against where the link actually lives, not its lexical
  # spelling. That is what lets a symlinked ANCESTOR change the effective `..`
  # count: resolving the target against the lexical parent instead would let a
  # link under a symlinked ancestor escape the root while still looking interior.
  # `.`/`..` adjust `base` directly; a component that is not a symlink -- or does
  # not exist (the write-leaf case) -- is accepted literally so the deepest
  # existing ancestor still resolves. Only symlink hops count toward the depth
  # cap, so deep-but-symlink-free nesting is never mistaken for a cycle.
  defp real_path(path) do
    [root | rest] = Path.split(Path.expand(path))
    walk_real(root, rest, 0)
  end

  defp walk_real(_base, _components, depth) when depth > @max_symlink_depth,
    do: {:error, :too_many_symlinks}

  defp walk_real(base, [], _depth), do: {:ok, base}

  defp walk_real(base, ["." | rest], depth), do: walk_real(base, rest, depth)

  defp walk_real(base, [".." | rest], depth),
    do: walk_real(Path.dirname(base), rest, depth)

  defp walk_real(base, [comp | rest], depth) do
    candidate = Path.join(base, comp)

    case :file.read_link(candidate) do
      {:ok, target} ->
        # A symlink resolves against its REAL parent (`base`): an absolute target
        # restarts from its own anchor, a relative one (possibly with `..`) is
        # spliced ahead of the remaining components and resolved against base.
        {anchor, target_rest} = anchor_target(to_string(target), base)
        walk_real(anchor, target_rest ++ rest, depth + 1)

      {:error, _not_a_symlink_or_missing} ->
        walk_real(candidate, rest, depth)
    end
  end

  # Split a symlink target into the base it resolves against and the components
  # to walk from there.
  #
  # `Path.split/1` is `:filename.split/1`, whose notion of "absolute" is
  # OS-dependent: a Windows absolute target splits as `["c:/", "tmp", ...]`,
  # keeping the drive as its own anchor, while the SAME string on Unix splits as
  # `["c:", "tmp", ...]` with no anchor at all. Matching only the POSIX `"/"`
  # anchor therefore sent every Windows-absolute target down the relative branch,
  # where it was spliced onto `base` and landed back INSIDE the root -- an escape
  # `escape_gate/2` could not see, because nothing had left.
  #
  # A drive anchor counts on EVERY host rather than only on Windows. Deciding it
  # per-host would mean the same link is contained on one platform and not on
  # another, and one rule errs the safe way: on Unix a target of `c:/outside/x`
  # names a directory literally called `c:`, so treating it as absolute refuses a
  # pathological-but-legal relative path instead of admitting a real escape.
  defp anchor_target(target, base) do
    case Path.split(target) do
      ["/" | rest] ->
        {"/", rest}

      [anchor | rest] = split ->
        case absolute_anchor(anchor) do
          nil -> {base, split}
          root -> {root, rest}
        end

      [] ->
        {base, []}
    end
  end

  # `"c:/"` is how Windows splits a drive-absolute target; `"c:"` is how Unix
  # splits the same string. A bare drive is drive-RELATIVE on Windows rather than
  # absolute, but anchoring it at the drive root refuses it, which is the safe
  # direction for a boundary.
  defp absolute_anchor(<<letter, ?:>>) when letter in ?A..?Z or letter in ?a..?z,
    do: <<letter, ?:, ?/>>

  defp absolute_anchor(<<letter, ?:, ?/>>)
       when letter in ?A..?Z or letter in ?a..?z,
       do: <<letter, ?:, ?/>>

  # UNC, the same anchor bug one shape over. `:filename.split/1` on Windows gives
  # a UNC path its own `"//"` component (both `"//host/share/x"` and the
  # `"\\\\host\\share\\x"` spelling land there), which is no drive letter -- so it
  # took the very relative branch the drive case was fixed out of.
  #
  # The clause matches TWO IDENTICAL separators, mirroring the `Slash, Slash`
  # guard `:filename.win32_splitb/1` decides UNC by. That also covers the shape
  # Unix produces: a backslash is an ordinary character there, so
  # `"\\\\host\\share\\x"` never splits at all and arrives whole as the anchor,
  # relative-looking. Same link, contained on Unix and escaping on Windows, which
  # is exactly the per-host divergence this function exists to remove -- so the
  # whole anchor is returned as the root and refused on both.
  defp absolute_anchor(<<sep, sep, _::binary>> = unc) when sep in [?/, ?\\],
    do: unc

  defp absolute_anchor(_), do: nil
end
