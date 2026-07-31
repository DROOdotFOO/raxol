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

  # An MCP client reports `{:not_ready, :initializing}` until its initialize
  # handshake round-trips; without waiting, a freshly started server lists zero
  # tools. Poll readiness up to this budget before giving up (fail-open).
  @default_ready_timeout_ms 15_000
  @default_ready_interval_ms 100

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
    * `:ready_timeout` -- ms to wait for a server's initialize handshake before
      listing its tools (default #{@default_ready_timeout_ms}). A server not
      ready in time fails open (skipped), as any load failure does.
    * `:ready_interval` -- ms between readiness polls (default
      #{@default_ready_interval_ms}).

  Returns `%{tools:, servers:, failed:}`. `servers` are the started client refs
  (the CALLER owns their lifecycle -- supervise or stop them). `failed` lists the
  specs that could not load, with the reason.
  """
  @spec load([server_spec()], keyword()) :: loaded()
  def load(specs, opts \\ []) when is_list(specs) do
    start = Keyword.get(opts, :start, &Raxol.MCP.Client.start_link/1)
    timeout = Keyword.get(opts, :ready_timeout, @default_ready_timeout_ms)
    interval = Keyword.get(opts, :ready_interval, @default_ready_interval_ms)

    # Start every client first so their initialize handshakes run concurrently,
    # then await each and list its tools. Start-then-await keeps one server's
    # (multi-second) cold start from serializing the whole bundle's boot.
    specs
    |> Enum.map(&{&1, start_client(&1, start)})
    |> Enum.reduce(%{tools: [], servers: [], failed: []}, fn {spec, started},
                                                             acc ->
      name = spec_name(spec)

      case resolve(started, name, timeout, interval) do
        {:ok, server, tools} ->
          %{
            acc
            | tools: acc.tools ++ tools,
              servers: [{name, server} | acc.servers]
          }

        {:error, reason} ->
          Logger.warning(fn ->
            "mcp bundle: server #{inspect(name)} skipped: #{inspect(reason)}"
          end)

          %{acc | failed: [{name, reason} | acc.failed]}
      end
    end)
    |> then(
      &%{
        &1
        | servers: Enum.reverse(&1.servers),
          failed: Enum.reverse(&1.failed)
      }
    )
  end

  defp spec_name(spec), do: Map.get(spec, :name, spec)

  defp start_client(%{name: name, command: command} = spec, start) do
    start.(
      name: name,
      command: command,
      args: Map.get(spec, :args, []),
      env: Map.get(spec, :env, [])
    )
  end

  defp start_client(spec, _start), do: {:error, {:invalid_spec, spec}}

  defp resolve({:ok, server}, name, timeout, interval) do
    case await_tools(server, name, timeout, interval) do
      {:ok, tools} -> {:ok, server, tools}
      {:error, _} = err -> err
    end
  end

  defp resolve({:error, _} = err, _name, _timeout, _interval), do: err

  # Retry listing tools while the client is still initializing, until ready or
  # the deadline. Any non-`:not_ready` error fails open immediately.
  defp await_tools(server, name, timeout, interval) do
    poll_tools(
      server,
      name,
      System.monotonic_time(:millisecond) + timeout,
      interval
    )
  end

  defp poll_tools(server, name, deadline, interval) do
    case Dynamic.from_client(server, name) do
      {:ok, tools} ->
        {:ok, tools}

      # Only `:starting`/`:initializing` are transient; a `:closed` server has
      # exited and will never become ready, so fail open at once rather than
      # burning the whole budget on a dead port.
      {:error, {:not_ready, status}} = err
      when status in [:starting, :initializing] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(interval)
          poll_tools(server, name, deadline, interval)
        else
          err
        end

      {:error, _} = err ->
        err
    end
  end

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
