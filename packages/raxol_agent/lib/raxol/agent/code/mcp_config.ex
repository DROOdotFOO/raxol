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

  An entry the loader cannot run is not dropped on the floor: `load_all/1`
  returns it in a `skipped` list with a reason, so `/mcp` and `/inspect`
  show it instead of leaving the operator to wonder why a server named in
  the file never appears. Two reasons exist. `:unsupported_transport` is an
  entry that names a `url` (or a `type` of `http`/`sse`): the Claude Code
  format allows those, but this bridge only starts stdio commands.
  `:invalid_spec` is anything else without a string `command`.

  ## Scope

  This loads the config; `Raxol.Agent.Code.McpLoader` bridges the servers
  into the live toolset (started under the agent DynamicSupervisor via
  `Raxol.Agent.McpBundle`, tools wrapped as `Raxol.Agent.Action.Dynamic`
  and dispatched through the same authorizer and hook chain as any Action).
  """

  @type server :: %{
          name: String.t(),
          command: String.t(),
          args: [String.t()],
          env: map()
        }

  @type skip_reason :: :unsupported_transport | :invalid_spec
  @type skipped :: {String.t(), skip_reason()}

  @doc """
  Load MCP servers from `<dir>/.mcp.json`.

  Returns `{:ok, servers}` (possibly empty), `:none` when there is no file,
  or `{:error, reason}` for an unreadable/invalid file. Entries the bridge
  cannot run are left out; `load_all/1` reports them.
  """
  @spec load(String.t()) :: {:ok, [server()]} | :none | {:error, term()}
  def load(dir) do
    case load_all(dir) do
      {:ok, servers, _skipped} -> {:ok, servers}
      other -> other
    end
  end

  @doc """
  Load MCP servers from `<dir>/.mcp.json`, keeping the entries that cannot
  be bridged.

  Returns `{:ok, servers, skipped}`, `:none` when there is no file, or
  `{:error, reason}` for an unreadable/invalid file. `skipped` pairs each
  refused entry's name with a `t:skip_reason/0`, sorted by name, so a
  surface can show it next to the servers that loaded.
  """
  @spec load_all(String.t()) ::
          {:ok, [server()], [skipped()]} | :none | {:error, term()}
  def load_all(dir) do
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
          servers when is_map(servers) -> parse(servers)
          _absent -> {:ok, [], []}
        end

      {:ok, _other} ->
        {:error, :not_an_object}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp parse(servers) do
    {parsed, skipped} =
      servers
      |> Enum.map(&parse_server/1)
      |> Enum.split_with(&is_map/1)

    {:ok, Enum.sort_by(parsed, & &1.name), Enum.sort_by(skipped, &elem(&1, 0))}
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

  # A `url` entry (Claude Code's `http`/`sse` servers) is a valid config the
  # bridge cannot start; every other command-less shape is a broken entry.
  defp parse_server({name, %{} = spec}) when is_binary(name) do
    {name, skip_reason(spec)}
  end

  defp parse_server({name, _other}), do: {to_string(name), :invalid_spec}

  defp skip_reason(%{"url" => url}) when is_binary(url), do: :unsupported_transport
  defp skip_reason(%{"type" => type}) when type in ["http", "sse"], do: :unsupported_transport
  defp skip_reason(_spec), do: :invalid_spec

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  defp env_map(%{} = env), do: env
  defp env_map(_other), do: %{}
end
