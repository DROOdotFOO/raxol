defmodule Raxol.MCP.Supervisor do
  @moduledoc """
  Supervision tree for the MCP subsystem.

  Starts the client's shared table owner, the Registry and the Server. The
  stdio transport is NOT started automatically (it takes over stdin/stdout) --
  use `mix mcp.server` or start it explicitly.

  ## Children (rest_for_one)

  1. `Raxol.MCP.Client.Tables` -- the per-origin era verdicts and circuit
     breakers the HTTP client transport shares between clients. First, so that
     a Registry or Server restart does not discard state that belongs to
     neither of them (ADR-0037 decision 2).
  2. `Raxol.MCP.Registry` -- ETS-backed tool/resource store
  3. `Raxol.MCP.Server` -- transport-agnostic message router
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
    # Which transport this server fronts, for the authorization context the
    # server hands its authorizers. Declared, not inferred: a transport
    # attaches after the server boots, and SSE is mounted in the embedder's own
    # Plug pipeline, so the server cannot work it out for itself.
    transport = Keyword.get(opts, :transport, :unknown)
    # `:default`, not `:configured`: an embedder who forgets this option must
    # leave the SSE boot gate shut rather than satisfy it by omission.
    authorizer_source = Keyword.get(opts, :authorizer_source, :default)

    children = [
      Raxol.MCP.Client.Tables,
      {Raxol.MCP.Registry, name: registry_name},
      {Raxol.MCP.Server,
       name: server_name,
       registry: registry_name,
       authorizer: authorizer,
       read_authorizer: read_authorizer,
       transport: transport,
       authorizer_source: authorizer_source}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
