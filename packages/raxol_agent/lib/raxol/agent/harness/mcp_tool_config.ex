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
  Returns `{:ok, config_path}`. `:dir` defaults to a unique temp directory.
  """
  @spec write(opts()) :: {:ok, Path.t()} | {:error, term()}
  def write(opts) do
    dir = Keyword.get_lazy(opts, :dir, &unique_tmp_dir/0)
    File.mkdir_p!(dir)

    tools = resolve_tools(opts)
    tools_file = Path.join(dir, "raxol_mcp_tools.json")
    config_file = Path.join(dir, "raxol_mcp_config.json")

    with :ok <- File.write(tools_file, Jason.encode!(%{"tools" => tools})),
         cfg = config(Keyword.put(opts, :tools_file, tools_file)),
         :ok <- File.write(config_file, Jason.encode!(cfg)) do
      {:ok, config_file}
    end
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

  defp unique_tmp_dir do
    Path.join(System.tmp_dir!(), "raxol_mcp_#{System.unique_integer([:positive])}")
  end
end
