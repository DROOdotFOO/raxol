defmodule Raxol.Agent.Code.McpConfig do
  @moduledoc """
  Loader for `.mcp.json` external MCP server config (the Claude Code
  format) used by `mix raxol.code`.

  Reads `<dir>/.mcp.json`:

      {
        "mcpServers": {
          "filesystem": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]
          }
        }
      }

  and returns the declared servers. The surface uses this to discover and
  list configured servers (`/mcp`).

  ## Scope

  This loads and surfaces the config. **Bridging a server's tools into the
  live ReAct toolset is a deliberate follow-up**: the tool loop dispatches
  to `Raxol.Agent.Action` *modules* (`ToolConverter.dispatch_tool_call/3`),
  whereas MCP tools are discovered at runtime, so exposing them needs a
  dispatch path for dynamic (non-module) tools. `Raxol.MCP.Client` already
  connects to servers; the missing piece is that dynamic dispatch seam, not
  this loader.
  """

  @type server :: %{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: map()
        }

  @doc """
  Load MCP servers from `<dir>/.mcp.json`.

  Returns `{:ok, servers}` (possibly empty), `:none` when there is no file,
  or `{:error, reason}` for an unreadable/invalid file.
  """
  @spec load(String.t()) :: {:ok, [server()]} | :none | {:error, term()}
  def load(dir) do
    path = Path.join(dir, ".mcp.json")

    case File.read(path) do
      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, {:read_failed, reason}}

      {:ok, binary} ->
        decode(binary)
    end
  end

  defp decode(binary) do
    case Jason.decode(binary) do
      {:ok, json} when is_map(json) ->
        case Map.get(json, "mcpServers") do
          servers when is_map(servers) -> {:ok, parse(servers)}
          _absent -> {:ok, []}
        end

      {:ok, _other} ->
        {:error, :not_an_object}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp parse(servers) do
    servers
    |> Enum.map(&parse_server/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.name)
  end

  defp parse_server({name, %{"command" => command} = spec})
       when is_binary(name) and is_binary(command) do
    %{
      name: name,
      command: command,
      args: string_list(Map.get(spec, "args", [])),
      env: env_map(Map.get(spec, "env", %{}))
    }
  end

  defp parse_server(_other), do: nil

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  defp env_map(%{} = env), do: env
  defp env_map(_other), do: %{}
end
