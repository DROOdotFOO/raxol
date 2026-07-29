defmodule Raxol.Agent.McpBundle do
  @moduledoc """
  Start external MCP servers from specs and wrap their tools as
  `Raxol.Agent.Action.Dynamic` values for the ReAct loop.

  A Console runtime bundles a default set of standard MCP servers at provision
  so the agent advertises a broad, real toolset (filesystem, fetch, git, ...)
  without hand-writing Actions. Each server's tools are namespaced
  `mcp__<server>__<tool>` and dispatch through the same authorizer + hook chain
  as any Action (see `Raxol.Agent.Action.ToolConverter`); add the returned tools
  to the `:actions` list handed to `Raxol.Agent.Stream.react/2`.

  Loading is FAIL-OPEN per server: a server that fails to start or list its
  tools is logged and skipped, so one broken or uninstalled server never denies
  the agent the rest of its tools.
  """

  require Logger

  alias Raxol.Agent.Action.Dynamic

  @type server_spec :: %{
          required(:name) => atom(),
          required(:command) => String.t(),
          optional(:args) => [String.t()],
          optional(:env) => [{String.t(), String.t()}]
        }

  @type loaded :: %{
          tools: [Dynamic.t()],
          servers: [{atom(), pid()}],
          failed: [{atom(), term()}]
        }

  @doc """
  Start each server spec and collect its tools as `Dynamic` values.

  Options:

    * `:start` -- `(keyword() -> {:ok, pid()} | {:error, term()})`, how a client
      is started (default `&Raxol.MCP.Client.start_link/1`). Injectable for
      tests and for a supervised start.

  Returns `%{tools:, servers:, failed:}`. `servers` are the started client refs
  (the CALLER owns their lifecycle -- supervise or stop them). `failed` lists the
  specs that could not load, with the reason.
  """
  @spec load([server_spec()], keyword()) :: loaded()
  def load(specs, opts \\ []) when is_list(specs) do
    start = Keyword.get(opts, :start, &Raxol.MCP.Client.start_link/1)

    specs
    |> Enum.reduce(%{tools: [], servers: [], failed: []}, fn spec, acc ->
      case load_one(spec, start) do
        {:ok, server, tools} ->
          %{acc | tools: acc.tools ++ tools, servers: [{spec.name, server} | acc.servers]}

        {:error, reason} ->
          Logger.warning(fn ->
            "mcp bundle: server #{inspect(spec.name)} skipped: #{inspect(reason)}"
          end)

          %{acc | failed: [{spec.name, reason} | acc.failed]}
      end
    end)
    |> then(&%{&1 | servers: Enum.reverse(&1.servers), failed: Enum.reverse(&1.failed)})
  end

  defp load_one(%{name: name, command: command} = spec, start) do
    client_opts = [
      name: name,
      command: command,
      args: Map.get(spec, :args, []),
      env: Map.get(spec, :env, [])
    ]

    with {:ok, server} <- start.(client_opts),
         {:ok, tools} <- Dynamic.from_client(server, name) do
      {:ok, server, tools}
    end
  end

  defp load_one(spec, _start), do: {:error, {:invalid_spec, spec}}

  @doc """
  The recommended default server catalog.

  `:workspace` scopes the filesystem server's allowed root (default `"."`).
  `npx` / `uvx` must be on PATH at runtime; a missing one fails open (that server
  is skipped, per `load/2`).
  """
  @spec default_servers(keyword()) :: [server_spec()]
  def default_servers(opts \\ []) do
    workspace = Keyword.get(opts, :workspace, ".")

    [
      %{
        name: :filesystem,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", workspace]
      },
      %{name: :fetch, command: "uvx", args: ["mcp-server-fetch"]},
      %{name: :git, command: "uvx", args: ["mcp-server-git"]},
      %{name: :time, command: "uvx", args: ["mcp-server-time"]},
      %{
        name: :sequential_thinking,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-sequential-thinking"]
      }
    ]
  end
end
