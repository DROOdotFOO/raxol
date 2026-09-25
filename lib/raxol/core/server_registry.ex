defmodule Raxol.Core.ServerRegistry do
  @moduledoc """
  Centralized registry and supervisor for all Raxol GenServers.

  Provides unified lifecycle management, health monitoring, and graceful shutdown
  coordination for all server processes in the system.

  ## Features

  - **Unified Supervision**: Single supervisor for all system servers
  - **Health Monitoring**: Built-in health checks and recovery
  - **Graceful Shutdown**: Coordinated shutdown with dependency handling
  - **Server Discovery**: Registry for finding and communicating with servers
  - **Performance Monitoring**: Server performance metrics and alerts

  ## Server Categories

  - **Core Servers**: State management, events, configuration
  - **UI Servers**: Theme management, accessibility, i18n
  - **Terminal Servers**: Buffer management, emulation, parsing
  - **Plugin Servers**: Plugin lifecycle, sandboxing, communication
  """

  use Supervisor
  alias Raxol.Core.Runtime.Log

  @server_specs [
    # Core System Servers
    {Raxol.Core.StateManager, name: :state_manager},
    {Raxol.Core.Config.ConfigServer, name: :config_manager},

    # UI System Servers
    {Raxol.UI.Theming.ThemeManager, name: :theme_manager},
    {Raxol.Core.Accessibility.AccessibilityServer, name: :accessibility_server},
    {Raxol.Core.I18n.I18nServer, name: :i18n_server},
    {Raxol.UI.State.Management.StateManagementServer,
     name: Raxol.UI.State.Management.StateManagementServer},

    # Terminal System Servers
    {Raxol.Terminal.Buffer.BufferServer, name: :buffer_server},
    {Raxol.Terminal.Emulator.EmulatorServer, name: :emulator_server},

    # Performance and Monitoring
    {Raxol.Performance.Memoization.MemoizationServer,
     name: :memoization_server},

    # Optional/Plugin Servers (conditionally started)
    {Raxol.Animation.StateServer, name: :animation_server, optional: true},
    {Raxol.Core.UX.UXServer, name: :ux_server, optional: true}
  ]

  @type server_name :: atom()
  @type server_spec :: {module(), keyword()}

  def start_link(init_arg) do
    Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @impl Supervisor
  def init(_init_arg) do
    children =
      @server_specs
      |> Enum.filter(&server_available?/1)
      |> Enum.map(&build_child_spec/1)

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Get a server process by name.
  """
  @spec get_server(server_name()) :: pid() | nil
  def get_server(server_name) do
    case Registry.lookup(Raxol.Registry, server_name) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  Check if a server is healthy and responding.
  """
  @spec health_check(server_name()) :: :ok | :error
  def health_check(server_name) do
    case get_server(server_name) do
      nil ->
        :error

      pid ->
        try do
          GenServer.call(pid, :ping, 1000)
          :ok
        catch
          :exit, _ -> :error
        end
    end
  end

  @doc """
  Get health status of all registered servers.
  """
  @spec health_status() :: %{server_name() => :ok | :error}
  def health_status do
    @server_specs
    |> Enum.map(fn {_module, opts} -> Keyword.fetch!(opts, :name) end)
    |> Map.new(fn name -> {name, health_check(name)} end)
  end

  @doc """
  Gracefully shutdown all servers in dependency order.
  """
  @spec graceful_shutdown(timeout()) :: :ok
  def graceful_shutdown(timeout \\ Raxol.Core.Defaults.shutdown_timeout_ms()) do
    Log.info("Initiating graceful server shutdown")

    # Shutdown in reverse order to handle dependencies
    shutdown_order = Enum.reverse(@server_specs)

    Enum.each(shutdown_order, fn {_module, opts} ->
      server_name = Keyword.fetch!(opts, :name)
      shutdown_server(server_name, timeout)
    end)

    Log.info("All servers stopped")
  end

  ## Private Functions

  defp server_available?({module, opts}) do
    if Keyword.get(opts, :optional, false) do
      Code.ensure_loaded?(module)
    else
      true
    end
  end

  defp build_child_spec({module, opts}) do
    server_name = Keyword.fetch!(opts, :name)

    %{
      id: server_name,
      start: {module, :start_link, [opts]},
      restart: :permanent,
      shutdown: Raxol.Core.Defaults.shutdown_timeout_ms(),
      type: :worker,
      modules: [module]
    }
  end

  defp shutdown_server(server_name, timeout) do
    case get_server(server_name) do
      nil ->
        Log.debug("Server #{server_name} not running")

      pid ->
        Log.debug("Stopping server #{server_name}")

        try do
          GenServer.stop(pid, :normal, timeout)
        catch
          :exit, _ ->
            Log.warning("Server #{server_name} did not shut down gracefully")
        end
    end
  end
end
