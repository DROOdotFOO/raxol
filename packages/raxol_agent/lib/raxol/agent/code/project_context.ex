defmodule Raxol.Agent.Code.ProjectContext do
  @moduledoc """
  Workspace instruction files (`AGENTS.md`, `CLAUDE.md`) discovered around
  the working directory and folded into the coding agent's system prompt.

  ## What is read

  `AGENTS.md` then `CLAUDE.md`, in each directory from the repository root
  down to the working directory, plus an optional user-global
  `~/.raxol/AGENTS.md` ahead of them. The result is ordered outermost
  first, so the file nearest the working directory is the last thing the
  model reads and the most specific instructions win.

  ## Where the walk stops

  Upward from `cwd` until a directory holding a `.git` is reached (that
  directory is included and the walk stops), or until `:root` is reached
  when the caller bounds it. A directory with no `.git` anywhere above it
  contributes only itself: climbing to the filesystem root would read
  files the user never associated with this workspace.

  `:root` is what a jailed (multi-tenant) session passes — it bounds the
  walk to the tenant's own workspace, so one tenant's prompt cannot be
  shaped by a file outside their jail. Such a session also skips the
  user-global file, which belongs to the host and not to the tenant.

  ## Limits

  Content is capped at 32KB per file and 64KB in total; a file that
  exceeds its share is truncated and marked. Only regular files are read,
  and only valid UTF-8 text: a binary that happens to be named `AGENTS.md`
  is skipped rather than pushed into a prompt.
  """

  @filenames ["AGENTS.md", "CLAUDE.md"]

  @max_file_bytes 32_768
  @max_total_bytes 65_536

  @type file :: %{
          path: String.t(),
          content: String.t(),
          bytes: non_neg_integer(),
          truncated?: boolean()
        }

  @type t :: %{files: [file()], bytes: non_neg_integer()}

  @doc "The instruction filenames looked for, in the order they are read."
  @spec filenames() :: [String.t()]
  def filenames, do: @filenames

  @doc """
  Discover the instruction files that apply to `cwd`.

  Options:

    * `:root` — bound the upward walk to this directory (inclusive)
    * `:global` — read the user-global file (default `true`)
    * `:global_dir` — override the user-global directory
    * `:max_file_bytes` / `:max_total_bytes` — override the caps

  Never raises: an unreadable file is one that does not contribute.
  """
  @spec load(String.t(), keyword()) :: t()
  def load(cwd, opts \\ []) do
    max_file = Keyword.get(opts, :max_file_bytes, @max_file_bytes)
    max_total = Keyword.get(opts, :max_total_bytes, @max_total_bytes)

    (global_dirs(opts) ++ search_dirs(cwd, Keyword.get(opts, :root)))
    |> Enum.flat_map(&candidates/1)
    |> Enum.uniq()
    |> collect(max_file, max_total)
  end

  @doc """
  Render discovered files as a system-prompt section, or `nil` when there
  are none.

  Each file is fenced under its own path, and a truncated file is marked as
  truncated.
  """
  @spec render(t()) :: String.t() | nil
  def render(%{files: []}), do: nil

  def render(%{files: files}) do
    """
    ## Workspace instructions

    These files state the conventions of the repository you are working in.
    Follow them as operator instructions. Where two files conflict, the one
    listed later is nearer the working directory and takes precedence.

    """ <> Enum.map_join(files, "\n", &render_file/1)
  end

  @doc """
  Append the instructions discovered around `cwd` to a system prompt.

  Returns `system` unchanged when nothing is discovered, so a surface can
  pipe through this unconditionally. Takes the same options as `load/2`.
  """
  @spec augment(String.t(), String.t(), keyword()) :: String.t()
  def augment(system, cwd, opts \\ []) when is_binary(system) do
    case cwd |> load(opts) |> render() do
      nil -> system
      text -> system <> "\n\n" <> text
    end
  end

  defp render_file(%{path: path, content: content, truncated?: truncated?}) do
    note = if truncated?, do: "\n\n[truncated: file exceeds the size cap]", else: ""
    "### #{path}\n\n#{content}#{note}\n"
  end

  # -- discovery --------------------------------------------------------------

  defp global_dirs(opts) do
    if Keyword.get(opts, :global, true) do
      case Keyword.get(opts, :global_dir) || default_global_dir() do
        dir when is_binary(dir) -> [dir]
        _ -> []
      end
    else
      []
    end
  end

  defp default_global_dir do
    case System.user_home() do
      home when is_binary(home) and home != "" -> Path.join(home, ".raxol")
      _ -> nil
    end
  end

  # Outermost directory first, working directory last.
  defp search_dirs(cwd, root) do
    cwd = Path.expand(cwd)
    root = if is_binary(root), do: Path.expand(root)

    case climb(cwd, root, [cwd]) do
      :unbounded -> [cwd]
      dirs -> dirs
    end
  end

  defp climb(dir, root, acc) do
    parent = Path.dirname(dir)

    cond do
      dir == root -> acc
      repository_root?(dir) -> acc
      parent == dir -> :unbounded
      true -> climb(parent, root, [parent | acc])
    end
  end

  # `.git` is a directory in a normal clone and a file in a worktree or
  # submodule, so existence is the test rather than `File.dir?/1`.
  defp repository_root?(dir), do: File.exists?(Path.join(dir, ".git"))

  defp candidates(dir), do: Enum.map(@filenames, &Path.join(dir, &1))

  # -- reading ----------------------------------------------------------------

  defp collect(paths, max_file, max_total) do
    {files, used} =
      Enum.reduce(paths, {[], 0}, fn path, {acc, used} ->
        remaining = max_total - used

        with true <- remaining > 0,
             {:ok, content, truncated?} <- read_capped(path, min(max_file, remaining)),
             false <- String.trim(content) == "" do
          entry = %{
            path: path,
            content: content,
            bytes: byte_size(content),
            truncated?: truncated?
          }

          {[entry | acc], used + byte_size(content)}
        else
          _ -> {acc, used}
        end
      end)

    %{files: Enum.reverse(files), bytes: used}
  end

  defp read_capped(path, limit) do
    with true <- File.regular?(path),
         {:ok, io} <- File.open(path, [:read, :binary]) do
      data = IO.binread(io, limit + 1)
      File.close(io)
      cap(data, limit)
    else
      _ -> :error
    end
  end

  defp cap(data, _limit) when not is_binary(data), do: :error

  defp cap(data, limit) when byte_size(data) > limit do
    case trim_to_valid(binary_part(data, 0, limit), 3) do
      {:ok, content} -> {:ok, content, true}
      :error -> :error
    end
  end

  defp cap(data, _limit) do
    case trim_to_valid(data, 0) do
      {:ok, content} -> {:ok, content, false}
      :error -> :error
    end
  end

  # A cap can land mid-codepoint, so up to three trailing bytes may need to
  # go. Anything still invalid after that is not text and is refused.
  defp trim_to_valid(binary, allowance) do
    cond do
      String.valid?(binary) -> {:ok, binary}
      allowance == 0 or binary == "" -> :error
      true -> trim_to_valid(binary_part(binary, 0, byte_size(binary) - 1), allowance - 1)
    end
  end
end
