defmodule Raxol.Agent.Code.McpConfig do
  @moduledoc """
  Loader for external MCP server config in the Claude Code format, used by
  `mix raxol.code`.

  Two files, two provenances. `<dir>/.mcp.json` is the workspace's own:

      {
        "mcpServers": {
          "filesystem": {
            "command": "npx",
            "args": ["-y", "@modelcontextprotocol/server-filesystem", "."]
          },
          "intel": {
            "url": "https://mcp.example.com/v1",
            "headers": {"Authorization": "Bearer ..."},
            "metered": true,
            "prices": {"lookup": 150}
          }
        }
      }

  and `~/.raxol/mcp.json` (override with `$RAXOL_MCP_CONFIG`) is the
  operator's own, read by `load_user/0` in the same format.

  Both forms of an entry are parsed. A `command` entry is a local stdio
  subprocess; a `url` entry is a remote HTTP server (ADR-0037). An entry
  carrying both keys is still returned and is refused later, with a named
  reason, by `Raxol.Agent.McpBundle`: the reason to parse it at all is that an
  operator then sees a refusal in `/mcp` instead of a server that silently
  vanished. An entry carrying neither names no transport at all, so it comes
  back as a `skipped` pair instead of a server. Nothing here is dropped
  except an entry whose name is not a string, which names nothing.

  ## Provenance is part of the parse

  Every server carries `:source` -- `:workspace` for `<dir>/.mcp.json`,
  `:user` for the operator's file. The two are not equally trusted, because
  `.mcp.json` is repository content that a clone can carry, and an
  `${env:VAR}` or `op://` header value is an instruction to read a named
  secret. `Raxol.Agent.McpHeaders` resolves such a reference only for a
  `:user` spec, or for a workspace spec whose header the operator has
  allowlisted outside the workspace; see that module for the full reasoning.
  Losing `:source` between here and there would silently widen that gate, so
  it travels with the spec rather than being re-derived.

  ## Remote fields

    * `url` -- the MCP endpoint. `https` only is enforced at the transport.
    * `headers` -- a name/value list, sorted for determinism. Values may be
      literals or references (`${env:VAR}`, `${op://...}`, `op://...`);
      whether a reference resolves depends on `:source`.
    * `metered` -- the origin bills per call. Implied by a non-empty `prices`,
      since declaring prices is declaring that calls cost money.
    * `prices` -- per-tool declared price, in whatever unit the run budget
      counts. Only positive integers are kept: a malformed price is not a
      price, which leaves the tool unpriced on a metered origin, and
      `Raxol.Agent.McpSpendHook` denies that by default rather than guessing
      it free.
    * `concurrency` -- `"stateless" | "pooled" | "serialized"`, matched
      against that fixed set (never `String.to_atom/1` on file input).
      Absent means the transport picks its own per-era default.

  An entry the loader cannot run is not dropped on the floor: `load_all/1`
  and `load_user/0` return it in a `skipped` list with a reason, so `/mcp`
  and `/inspect` show it instead of leaving the operator to wonder why a
  server named in the file never appears. One reason per fault, so the
  rendered text sends the operator to the line of the config that is
  actually wrong: `:unsupported_transport` is an entry whose `type` is
  `http`/`sse` but which names no `url` to connect to; `:no_command` is an
  object naming neither `command` nor `url`; `:command_not_string` is a
  `command` that is not a string; `:not_an_object` is an entry that is not
  an object at all.

  ## Scope

  This loads the config; `Raxol.Agent.Code.McpLoader` bridges the servers into
  the live toolset. Its loader and per-session janitor run under
  `Raxol.Agent.TaskSupervisor`; the janitor owns the MCP clients and their OS
  subprocesses. Tools are wrapped as `Raxol.Agent.Action.Dynamic` and dispatched
  through the same authorizer and hook chain as any Action.
  """

  alias Raxol.Agent.OperatorFile

  @env_path "RAXOL_MCP_CONFIG"
  @user_filename "mcp.json"
  @workspace_filename ".mcp.json"
  @label "user mcp config"

  @type source :: :workspace | :user

  @type server :: %{
          required(:name) => String.t(),
          required(:source) => source(),
          optional(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:env) => map(),
          optional(:url) => String.t(),
          optional(:headers) => [{String.t(), String.t()}],
          optional(:metered) => boolean(),
          optional(:prices) => %{optional(String.t()) => pos_integer()},
          optional(:concurrency) => :stateless | :pooled | :serialized
        }

  @type skip_reason ::
          :unsupported_transport
          | :no_command
          | :command_not_string
          | :not_an_object

  @type skipped :: {String.t(), skip_reason()}

  @doc """
  Load MCP servers from `<dir>/.mcp.json`, tagged `source: :workspace`,
  keeping the entries that cannot be bridged.

  Returns `{:ok, servers, skipped}`, `:none` when there is no file, or
  `{:error, reason}` for an unreadable/invalid file. `skipped` pairs each
  refused entry's name with a `t:skip_reason/0`, sorted by name, so a
  surface can show it next to the servers that loaded.
  """
  @spec load_all(String.t()) ::
          {:ok, [server()], [skipped()]} | :none | {:error, term()}
  def load_all(dir) do
    read_config(Path.join(dir, @workspace_filename), :workspace)
  end

  @doc """
  Load the operator's own MCP servers, tagged `source: :user`.

  Same format and same return shape as `load_all/1`, read from `user_path/0`.
  This is the file whose header references resolve, and whose servers are
  exempt from the workspace host allowlist, so it must be a file the operator
  actually wrote: `Raxol.Agent.OperatorFile` refuses one that is not owned by
  this account or is group/other-writable, and refuses to guess a path at all
  when the process has no home directory. `{:error, :no_home}` there rather
  than `~/.raxol` silently becoming `/tmp/.raxol`, where any local user could
  plant a `:user`-provenance server first.
  """
  @spec load_user() :: {:ok, [server()], [skipped()]} | :none | {:error, term()}
  def load_user do
    case OperatorFile.read(@env_path, @user_filename, @label) do
      {:ok, binary} -> decode(binary, :user)
      :none -> :none
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The user-level config path (`$RAXOL_MCP_CONFIG` or `~/.raxol/mcp.json`), or
  nil when there is neither an override nor a home directory.
  """
  @spec user_path() :: String.t() | nil
  def user_path, do: OperatorFile.path(@env_path, @user_filename)

  defp read_config(path, source) do
    case File.read(path) do
      {:error, :enoent} ->
        :none

      {:error, reason} ->
        {:error, {:read_failed, reason}}

      {:ok, binary} ->
        decode(binary, source)
    end
  end

  defp decode(binary, source) do
    case Jason.decode(binary) do
      {:ok, json} when is_map(json) ->
        case Map.get(json, "mcpServers") do
          servers when is_map(servers) -> parse(servers, source)
          _absent -> {:ok, [], []}
        end

      {:ok, _other} ->
        {:error, :not_an_object}

      {:error, _} ->
        {:error, :invalid_json}
    end
  end

  defp parse(servers, source) do
    {parsed, skipped} =
      servers
      |> Enum.map(&parse_server(&1, source))
      |> Enum.reject(&is_nil/1)
      |> Enum.split_with(&is_map/1)

    {:ok, Enum.sort_by(parsed, & &1.name), Enum.sort_by(skipped, &elem(&1, 0))}
  end

  # A named object is a server declaration even when its keys are wrong, as
  # long as it names a transport: an entry carrying both `command` and `url`
  # is still returned and refused by name at `Raxol.Agent.McpBundle`, because
  # the ambiguity is the operator's to resolve. An entry naming neither names
  # nothing to start, so it rides back as `{name, reason}` instead.
  defp parse_server({name, spec}, source) when is_binary(name) and is_map(spec) do
    server =
      %{name: name, source: source}
      |> put_stdio(spec)
      |> put_remote(spec)

    if Map.has_key?(server, :command) or Map.has_key?(server, :url) do
      server
    else
      {name, skip_reason(spec)}
    end
  end

  defp parse_server({name, _not_an_object}, _source) when is_binary(name),
    do: {name, :not_an_object}
  defp parse_server(_other, _source), do: nil

  defp put_stdio(server, %{"command" => command} = spec) when is_binary(command) do
    Map.merge(server, %{
      command: command,
      args: string_list(Map.get(spec, "args", [])),
      env: env_map(Map.get(spec, "env", %{}))
    })
  end

  defp put_stdio(server, _spec), do: server

  defp put_remote(server, %{"url" => url} = spec) when is_binary(url) do
    prices = prices(Map.get(spec, "prices", %{}))

    server
    |> Map.merge(%{
      url: url,
      headers: headers(Map.get(spec, "headers", %{})),
      prices: prices,
      metered: Map.get(spec, "metered") == true or prices != %{}
    })
    |> put_concurrency(Map.get(spec, "concurrency"))
  end

  defp put_remote(server, _spec), do: server

  defp put_concurrency(server, "stateless"), do: Map.put(server, :concurrency, :stateless)
  defp put_concurrency(server, "pooled"), do: Map.put(server, :concurrency, :pooled)
  defp put_concurrency(server, "serialized"), do: Map.put(server, :concurrency, :serialized)
  defp put_concurrency(server, _other), do: server

  # An entry that names neither transport names nothing the bridge can start,
  # so it rides back as a reason rather than as a server: `/mcp` and
  # `/inspect` then show the line of the config that is actually wrong.
  # `type: "http" | "sse"` declares a remote server and then fails to name
  # its `url`; a non-string `command` is a broken stdio entry; anything else
  # simply has no transport key at all.
  defp skip_reason(%{"type" => type}) when type in ["http", "sse"], do: :unsupported_transport
  defp skip_reason(%{"command" => _not_a_string}), do: :command_not_string
  defp skip_reason(_spec), do: :no_command

  defp headers(%{} = headers) do
    headers
    |> Enum.filter(fn {name, value} -> is_binary(name) and is_binary(value) end)
    |> Enum.sort()
  end

  defp headers(_other), do: []

  defp prices(%{} = prices) do
    for {tool, price} <- prices, is_binary(tool), is_integer(price), price > 0, into: %{} do
      {tool, price}
    end
  end

  defp prices(_other), do: %{}

  defp string_list(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp string_list(_other), do: []

  defp env_map(%{} = env), do: env
  defp env_map(_other), do: %{}
end
