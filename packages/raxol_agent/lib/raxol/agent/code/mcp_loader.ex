defmodule Raxol.Agent.Code.McpLoader do
  @moduledoc """
  Bridge from `.mcp.json` server config to live agent tools for the coding
  surfaces: converts `Raxol.Agent.Code.McpConfig` servers into
  `Raxol.Agent.McpBundle` specs, starts each server's MCP client under the
  agent DynamicSupervisor, and returns the bundle result (tools as
  `Raxol.Agent.Action.Dynamic` values, started servers, per-server
  failures).

  Supervision follows the Console runtime's shape: clients are `:transient`
  children of `Raxol.Agent.DynSup`, never linked to the caller, so a
  crashing server binary cannot take a TUI down and the TUI can terminate
  the clients it started when it quits.
  """

  alias Raxol.Agent.McpBundle

  @type result :: %{tools: [struct()], servers: [{atom(), pid()}], failed: [{term(), term()}]}

  @doc """
  Load the configured servers; never raises or exits.

  Options: `:bundle` (the load function, default `McpBundle.load/2`) and
  `:start` (the per-client start function, default supervised under
  `Raxol.Agent.DynSup`), both injectable for tests.
  """
  @spec load([map()], keyword()) :: result()
  def load(servers, opts \\ []) do
    bundle = Keyword.get(opts, :bundle, &McpBundle.load/2)
    start = Keyword.get(opts, :start, &supervised_start/1)

    bundle.(Enum.map(servers, &to_spec/1), start: start)
  catch
    kind, reason ->
      %{tools: [], servers: [], failed: [{:bundle, {kind, reason}}]}
  end

  @doc "Terminate previously started clients; unknown pids are ignored."
  @spec stop_clients([{term(), pid()}]) :: :ok
  def stop_clients(servers) do
    Enum.each(servers, fn {_name, pid} ->
      DynamicSupervisor.terminate_child(Raxol.Agent.DynSup, pid)
    end)

    :ok
  end

  # McpConfig servers carry string names and an env MAP; the bundle spec
  # wants an atom name and an env LIST. The atom is minted from the user's
  # own local `.mcp.json` (bounded, not wire input).
  defp to_spec(server) do
    %{
      name: String.to_atom(server.name),
      command: server.command,
      args: Map.get(server, :args, []),
      env: server |> Map.get(:env, %{}) |> Map.to_list()
    }
  end

  defp supervised_start(client_opts) do
    DynamicSupervisor.start_child(Raxol.Agent.DynSup, %{
      id: :mcp_client,
      start: {Raxol.MCP.Client, :start_link, [client_opts]},
      restart: :transient
    })
  end
end
