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
          "Returns at most the first 16KB.",
      schema: [
        input: [
          path: [type: :string, required: true, description: "File to read"]
        ],
        output: [
          path: [type: :string],
          content: [type: :string],
          truncated: [type: :boolean]
        ]
      ]

    @max_bytes 16_384

    @impl true
    def run(%{path: path}, context) do
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
        truncated = byte_size(content) > @max_bytes

        {:ok,
         %{
           path: path,
           content:
             binary_part(content, 0, min(byte_size(content), @max_bytes)),
           truncated: truncated
         }}
      else
        {:error, reason} -> {:error, reason}
      end
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
  instead of hard-refusing; V's ruling). Same expansion `resolve/1`
  performs, decision only.
  """
  @spec outside_cwd?(String.t() | nil) :: boolean()
  def outside_cwd?(path) when is_binary(path) do
    cwd = working_dir()
    abs = Path.expand(path, cwd)
    not (abs == cwd or String.starts_with?(abs, cwd <> "/"))
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
