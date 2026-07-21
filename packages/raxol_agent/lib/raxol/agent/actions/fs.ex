defmodule Raxol.Agent.Actions.Fs do
  @moduledoc """
  Read-only real-filesystem Actions for LLM tool use.

  Unlike `Raxol.Agent.Actions.Vfs` (the in-memory virtual filesystem),
  these touch the actual filesystem the BEAM runs on — scoped to the
  current working directory and **strictly read-only** (`list_dir`,
  `read_file`, `file_stat`). No write, delete, or shell surface here;
  mutating tools must go through the blast-radius gate when it lands
  (see `docs/proposals/in-flight/harness-spec-backend.md` §8).

  Path discipline: every path is expanded relative to cwd and must stay
  under cwd — `../` escapes and absolute paths outside cwd are rejected
  with `:outside_cwd`.
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
    def run(%{path: path} = params, _context) do
      with {:ok, abs} <- Raxol.Agent.Actions.Fs.resolve(path),
           {:ok, content} <- File.read(abs) do
        {:ok, slice(path, content, Map.get(params, :offset), Map.get(params, :limit))}
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
  Expand `path` against the working directory and require the result to
  stay under it.

  The working directory is `RAXOL_CLI_CWD` when set (the `bin/raxol`
  wrapper exports the caller's cwd before re-execing from the package
  directory), else the BEAM's cwd.
  """
  @spec resolve(String.t()) :: {:ok, String.t()} | {:error, :outside_cwd}
  def resolve(path) do
    cwd = working_dir()
    abs = Path.expand(path, cwd)

    if abs == cwd or String.starts_with?(abs, cwd <> "/") do
      {:ok, abs}
    else
      {:error, :outside_cwd}
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
