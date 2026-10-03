defmodule Raxol.Agent.Harness.McpToolConfig do
  @moduledoc """
  Builds the MCP configuration that injects Raxol's tools into a native CLI.

  This is the "vendor owns the loop, we inject our tools" trick from omnigent:
  when a native harness runs its own agent loop, the framework cannot drive tool
  dispatch. Instead it exposes the agent's Actions to the CLI as an MCP server,
  which the CLI discovers via its `--mcp-config <path>` flag and calls directly.

  Two artifacts are produced:

  - The **MCP config** the CLI consumes -- `{"mcpServers": {"<name>": {command,
    args, env}}}`. The CLI launches that command as a child and speaks MCP to it.
  - A **tool manifest** -- the Action tool definitions (derived via
    `Raxol.Agent.Action.ToolConverter`) written to a side file whose path is
    passed to the server command via the `RAXOL_MCP_TOOLS_FILE` env var, so the
    spawned MCP server can load exactly this agent's tools.

  The referenced `:command` must be an MCP server that exposes the manifest's
  tools (e.g. a `mix mcp.server` variant); wiring a specific server binary is the
  caller's responsibility. This module owns the config/manifest format only.
  """

  alias Raxol.Agent.Action.ToolConverter

  @default_server_name "raxol"
  @tools_env_var "RAXOL_MCP_TOOLS_FILE"

  @type opts :: [
          actions: [module()],
          tools: [map()],
          server_name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: %{optional(String.t()) => String.t()},
          dir: Path.t()
        ]

  @doc """
  Derive MCP tool definitions (`%{"name", "description", "inputSchema"}`) from
  Action modules, via `ToolConverter.to_tool_definitions/1`.
  """
  @spec tool_definitions([module()]) :: [map()]
  def tool_definitions(actions) when is_list(actions) do
    actions
    |> ToolConverter.to_tool_definitions()
    |> Enum.map(&to_mcp_tool/1)
  end

  @doc """
  Build the MCP config map the CLI consumes.

  Requires `:command` (the MCP server launcher). Tools come from `:tools`
  (pre-derived) or `:actions` (derived here). The tool manifest path is injected
  into the server entry's env as `RAXOL_MCP_TOOLS_FILE` when `:tools_file` is
  given.
  """
  @spec config(opts()) :: map()
  def config(opts) do
    name = Keyword.get(opts, :server_name, @default_server_name)
    command = Keyword.fetch!(opts, :command)
    args = Keyword.get(opts, :args, [])
    env = build_env(opts)

    entry =
      %{"command" => command, "args" => args}
      |> maybe_put_env(env)

    %{"mcpServers" => %{name => entry}}
  end

  @doc """
  Write the MCP config and tool manifest to disk.

  Writes the manifest (`<dir>/raxol_mcp_tools.json`) and the config
  (`<dir>/raxol_mcp_config.json`), wiring the manifest path into the server env.
  Returns `{:ok, config_path}`, or `{:error, reason}` when a directory or file
  cannot be created.

  Without `:dir`, both go in a new directory under the system temp dir with a
  random name, created with `mkdir` (never reusing or following a path that
  already exists, a symlink included) and closed to other users (0700); each
  file is created exclusively and made 0600 before anything is written into
  it, since the config carries the server's `:env`.

  A `:dir` given by the caller is the caller's: it is created if missing,
  existing files in it are overwritten with default permissions, and nothing
  checks it for symlinks or other users' access.
  """
  @spec write(opts()) :: {:ok, Path.t()} | {:error, term()}
  def write(opts) do
    case Keyword.fetch(opts, :dir) do
      {:ok, dir} ->
        with :ok <- File.mkdir_p(dir), do: write_files(dir, opts, &File.write/2)

      :error ->
        with {:ok, dir} <- private_tmp_dir() do
          case write_files(dir, opts, &write_private/2) do
            {:ok, _} = ok ->
              ok

            error ->
              File.rm_rf(dir)
              error
          end
        end
    end
  end

  @doc false
  # Create a fresh 0700 directory under `root`, trying each of `names` in turn.
  # A name that already exists (a directory, a file, a symlink) is skipped,
  # never reused or followed. Separate from `write/1` so the refusal can be
  # tested against planted paths, which a random name cannot be.
  @spec private_dir(Path.t(), Enumerable.t()) :: {:ok, Path.t()} | {:error, term()}
  def private_dir(root, names) do
    Enum.reduce_while(names, {:error, :tmp_dir_exhausted}, fn name, acc ->
      dir = Path.join(root, name)

      case File.mkdir(dir) do
        :ok -> {:halt, close_dir(dir)}
        {:error, :eexist} -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, {:mkdir, dir, reason}}}
      end
    end)
  end

  @doc "The env var name carrying the tool manifest path to the MCP server."
  @spec tools_env_var() :: String.t()
  def tools_env_var, do: @tools_env_var

  # -- Internals --------------------------------------------------------------

  defp resolve_tools(opts) do
    case Keyword.get(opts, :tools) do
      tools when is_list(tools) -> tools
      _ -> tool_definitions(Keyword.get(opts, :actions, []))
    end
  end

  defp build_env(opts) do
    base = Keyword.get(opts, :env, %{})

    case Keyword.get(opts, :tools_file) do
      nil -> base
      path -> Map.put(base, @tools_env_var, path)
    end
  end

  defp maybe_put_env(entry, env) when map_size(env) == 0, do: entry
  defp maybe_put_env(entry, env), do: Map.put(entry, "env", env)

  defp to_mcp_tool(%{"function" => %{"name" => name} = fun}) do
    %{
      "name" => name,
      "description" => Map.get(fun, "description", ""),
      "inputSchema" => Map.get(fun, "parameters", %{"type" => "object", "properties" => %{}})
    }
  end

  defp to_mcp_tool(%{"name" => name} = tool) do
    %{
      "name" => name,
      "description" => Map.get(tool, "description", ""),
      "inputSchema" =>
        Map.get(tool, "inputSchema") || Map.get(tool, "parameters") ||
          %{"type" => "object", "properties" => %{}}
    }
  end

  defp write_files(dir, opts, write) do
    tools = resolve_tools(opts)
    tools_file = Path.join(dir, "raxol_mcp_tools.json")
    config_file = Path.join(dir, "raxol_mcp_config.json")

    with :ok <- write.(tools_file, Jason.encode!(%{"tools" => tools})),
         cfg = config(Keyword.put(opts, :tools_file, tools_file)),
         :ok <- write.(config_file, Jason.encode!(cfg)) do
      {:ok, config_file}
    end
  end

  @tmp_attempts 5

  defp private_tmp_dir do
    case System.tmp_dir() do
      nil -> {:error, :no_tmp_dir}
      root -> private_dir(root, Stream.repeatedly(&random_name/0) |> Stream.take(@tmp_attempts))
    end
  end

  defp random_name do
    "raxol_mcp_" <> Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
  end

  # `mkdir` just created it, but check it is still a directory, not a symlink,
  # before closing it to other users.
  defp close_dir(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.chmod(dir, 0o700), do: {:ok, dir}

      {:ok, %File.Stat{type: type}} ->
        {:error, {:not_a_directory, dir, type}}

      {:error, reason} ->
        {:error, {:lstat, dir, reason}}
    end
  end

  # Created exclusively (an existing path, a symlink included, is refused) and
  # made 0600 before anything is written into it.
  defp write_private(path, content) do
    with {:ok, io} <- File.open(path, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(io, content)
      after
        File.close(io)
      end
    end
  end
end
