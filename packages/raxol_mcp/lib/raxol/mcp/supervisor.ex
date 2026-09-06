defmodule Raxol.MCP.Supervisor do
  @moduledoc """
  Supervision tree for the MCP subsystem.

  Starts the Registry and Server. The stdio transport is NOT started
  automatically (it takes over stdin/stdout) -- use `mix mcp.server`
  or start it explicitly.

  ## Children (rest_for_one)

  1. `Raxol.MCP.Registry` -- ETS-backed tool/resource store
  2. `Raxol.MCP.Server` -- transport-agnostic message router
  """

  use Supervisor

  @doc "Start the MCP supervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    registry_name = Keyword.get(opts, :registry_name, Raxol.MCP.Registry)
    server_name = Keyword.get(opts, :server_name, Raxol.MCP.Server)
    authorizer = Keyword.get(opts, :authorizer)
    read_authorizer = Keyword.get(opts, :read_authorizer)
    authorizer_source = Keyword.get(opts, :authorizer_source, :configured)

    children = [
      {Raxol.MCP.Registry, name: registry_name},
      {Raxol.MCP.Server,
       name: server_name,
       registry: registry_name,
       authorizer: authorizer,
       read_authorizer: read_authorizer,
       authorizer_source: authorizer_source}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
