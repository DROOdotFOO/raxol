defmodule Raxol.Agent.Actions.Fs do
  @moduledoc """
  Read-only real-filesystem Actions for LLM tool use.

  Unlike `Raxol.Agent.Actions.Vfs` (the in-memory virtual filesystem),
  these touch the actual filesystem the BEAM runs on — scoped to the
  current working directory and **strictly read-only** (`list_dir`,
  `read_file`, `file_stat`). No write, delete, or shell surface here;
  mutating tools must go through the blast-radius gate when it lands.

  Path discipline: every path is expanded relative to cwd and must stay
  under cwd — `../` escapes and absolute paths outside cwd are rejected
  with `:outside_cwd`. Containment is decided on the REAL path (symlinks
  resolved via `realpath/1`), never the lexical one — a symlink inside
  cwd that points outside it is out of bounds, because the string prefix
  check alone cannot see through it. Both sides of the comparison are
  canonicalized: the sandbox root itself may sit behind a symlink (e.g.
  macOS's `/tmp` -> `/private/tmp`), so only the real root and the real
  candidate may be compared.
  """

  defmodule ListDir do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "list_dir",
      description:
        "List entries of a directory (relative to the current working " <>
          "directory). Returns names with a trailing / for directories.",
      schema: [
        input: [
          path: [
            type: :string,
            required: false,
            description: "Directory to list, relative to cwd. Default: \".\""
          ]
        ],
        output: [
          path: [type: :string],
          entries: [type: {:list, :string}]
        ]
      ]

    @impl true
    def run(params, _context) do
      path = Map.get(params, :path) || "."

      with {:ok, abs} <- Raxol.Agent.Actions.Fs.resolve(path),
           {:ok, names} <- File.ls(abs) do
        entries =
          names
          |> Enum.sort()
          |> Enum.map(fn name ->
            if File.dir?(Path.join(abs, name)), do: name <> "/", else: name
          end)

        {:ok, %{path: path, entries: entries}}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defmodule ReadFile do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "read_file",
      description:
        "Read a text file (relative to the current working directory). " <>
          "Optionally read a line range with `offset` (1-based start line) " <>
          "and `limit` (line count). Returns at most 256KB; `truncated` " <>
          "flags when the content was longer.",
      schema: [
        input: [
          path: [type: :string, required: true, description: "File to read"],
          offset: [
            type: :integer,
            description: "1-based line to start from (with `limit`)"
          ],
          limit: [
            type: :integer,
            description: "Number of lines to read from `offset`"
          ]
        ],
        output: [
          path: [type: :string],
          content: [type: :string],
          truncated: [type: :boolean],
          offset: [type: :integer],
          line_count: [type: :integer]
        ]
      ]

    @max_bytes 262_144

    @impl true
    def run(%{path: path} = params, context) do
      # `allow_outside_cwd` exists only on the post-approval execute of
      # an escalated outside-cwd read (the executor sets it after the
      # operator's allow for THIS call) — every other caller stays
      # confined by resolve/1.
      resolver =
        if is_map(context) && Map.get(context, :allow_outside_cwd),
          do: &Raxol.Agent.Actions.Fs.resolve_unconfined/1,
          else: &Raxol.Agent.Actions.Fs.resolve/1

      with {:ok, abs} <- resolver.(path),
           {:ok, content} <- File.read(abs) do
        {:ok,
         slice(path, content, Map.get(params, :offset), Map.get(params, :limit))}
      else
        {:error, reason} -> {:error, reason}
      end
    end

    # Whole-file read: cap at @max_bytes.
    defp slice(path, content, nil, nil) do
      truncated = byte_size(content) > @max_bytes

      %{
        path: path,
        content: binary_part(content, 0, min(byte_size(content), @max_bytes)),
        truncated: truncated,
        offset: 1,
        line_count: content |> String.split("\n") |> length()
      }
    end

    # Line-range read: 1-based `offset`, optional `limit` lines. A blank
    # `limit` reads to end of file.
    defp slice(path, content, offset, limit) do
      start = max(offset || 1, 1)
      lines = String.split(content, "\n")
      dropped = Enum.drop(lines, start - 1)
      taken = if is_integer(limit), do: Enum.take(dropped, limit), else: dropped
      text = Enum.join(taken, "\n")
      truncated = byte_size(text) > @max_bytes

      %{
        path: path,
        content: binary_part(text, 0, min(byte_size(text), @max_bytes)),
        truncated: truncated,
        offset: start,
        line_count: length(taken)
      }
    end
  end

  defmodule FileStat do
    @moduledoc false
    use Raxol.Agent.Action,
      name: "file_stat",
      description:
        "Stat a path (relative to the current working directory): " <>
          "type, size in bytes, and mtime.",
      schema: [
        input: [
          path: [type: :string, required: true, description: "Path to stat"]
        ],
        output: [
          path: [type: :string],
          type: [type: :string],
          size: [type: :integer],
          mtime: [type: :string]
        ]
      ]

    @impl true
    def run(%{path: path}, _context) do
      with {:ok, abs} <- Raxol.Agent.Actions.Fs.resolve(path),
           {:ok, stat} <- File.stat(abs, time: :posix) do
        {:ok,
         %{
           path: path,
           type: to_string(stat.type),
           size: stat.size,
           mtime: stat.mtime |> DateTime.from_unix!() |> DateTime.to_iso8601()
         }}
      else
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "All read-only fs actions, for passing as `actions:` to a ReAct run."
  @spec all() :: [module()]
  def all, do: [ListDir, ReadFile, FileStat]

  @doc """
  Whether `path` lands outside the sandbox root — the executor's
  escalation predicate (an outside-cwd `read_file` asks the operator
  instead of hard-refusing). Makes the SAME canonicalized containment
  decision `resolve/1` makes, inverted — the two must never disagree
  about a path, or a symlink escape would surface as a bare
  `:outside_cwd` error instead of an operator escalation. A symlink
  cycle counts as outside (escalate, never silently allow).
  """
  @spec outside_cwd?(String.t() | nil) :: boolean()
  def outside_cwd?(path) when is_binary(path) do
    cwd = working_dir()
    abs = Path.expand(path, cwd)

    case {safe_realpath(abs), safe_realpath(cwd)} do
      {{:ok, real_abs}, {:ok, real_root}} ->
        not contained?(real_abs, real_root)

      _ ->
        true
    end
  end

  def outside_cwd?(_path), do: false

  @doc """
  Expansion WITHOUT the sandbox check — only reachable through an
  operator-approved escalation (`allow_outside_cwd` in the tool context,
  set by the executor strictly after an allow decision for THIS call).
  """
  @spec resolve_unconfined(String.t()) :: {:ok, String.t()}
  def resolve_unconfined(path),
    do: {:ok, Path.expand(path, working_dir())}

  @doc """
  Expand `path` against the working directory and require the result to
  stay under it.

  The working directory is `RAXOL_CLI_CWD` when set (the `bin/raxol`
  wrapper exports the caller's cwd before re-execing from the package
  directory), else the BEAM's cwd.

  The returned path is the lexical expansion (symlinks left in place —
  reading through a contained symlink is fine, the OS follows it the
  same way either way), but the containment DECISION is made on
  `realpath/1` of both sides, so a symlink cannot lexically hide an
  escape.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :outside_cwd}
  def resolve(path) do
    cwd = working_dir()
    abs = Path.expand(path, cwd)

    with {:ok, real_abs} <- safe_realpath(abs),
         {:ok, real_root} <- safe_realpath(cwd),
         true <- contained?(real_abs, real_root) do
      {:ok, abs}
    else
      _ -> {:error, :outside_cwd}
    end
  end

  defp contained?(real_path, real_root) do
    real_path == real_root or String.starts_with?(real_path, real_root <> "/")
  end

  @max_symlink_hops 40

  @doc """
  Best-effort canonicalization of `path`: resolves every symlink along
  it, component by component, from the root down. A component that does
  not exist (the final segment of a not-yet-created file, for a future
  write path) is kept literally rather than erroring — only EXISTING
  components can be symlinks. On a symlink cycle (more than
  #{@max_symlink_hops} hops), returns `path` unresolved — callers that
  need a containment guarantee (see `resolve/1`) must not treat that
  fallback as trustworthy; use `safe_realpath/1` there instead, which
  surfaces the cycle as an error so containment fails closed rather
  than falling back to an unresolved (and possibly still
  lexically-matching) path.

  `path` must already be absolute (callers canonicalize an
  already-`Path.expand/2`-ed path); this function does no cwd-relative
  expansion of its own.
  """
  @spec realpath(String.t()) :: String.t()
  def realpath(path) do
    case safe_realpath(path) do
      {:ok, real} -> real
      :error -> path
    end
  end

  @spec safe_realpath(String.t()) :: {:ok, String.t()} | :error
  defp safe_realpath(path) do
    case walk(Path.split(path), "/", 0) do
      {:ok, real} -> {:ok, real}
      {:error, :symlink_loop} -> :error
    end
  end

  defp walk(_components, _acc, hops) when hops > @max_symlink_hops do
    {:error, :symlink_loop}
  end

  defp walk([], acc, _hops), do: {:ok, acc}
  defp walk(["/" | rest], _acc, hops), do: walk(rest, "/", hops)

  defp walk([component | rest], acc, hops) do
    candidate = Path.join(acc, component)

    case File.read_link(candidate) do
      {:ok, target} ->
        resolved =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, acc)
          end

        walk(Path.split(resolved) ++ rest, "/", hops + 1)

      {:error, _not_a_symlink_or_missing} ->
        walk(rest, candidate, hops)
    end
  end

  @doc "The directory fs actions are scoped to (see `resolve/1`)."
  @spec working_dir() :: String.t()
  def working_dir do
    case System.get_env("RAXOL_CLI_CWD") do
      nil -> File.cwd!()
      "" -> File.cwd!()
      dir -> Path.expand(dir)
    end
  end
end
