defmodule Raxol.Application do
  @moduledoc """
  Main application module for Raxol terminal emulator.

  Handles application startup, supervision tree initialization,
  core system configuration, and runtime feature management.

  ## Environment-based Configuration

  The application adapts its behavior based on the environment:
  - `:test` - Minimal supervision tree for testing
  - `:minimal` - Ultra-fast startup with core features only
  - `:dev` - Full feature set with development tools
  - `:prod` - Production configuration with optimizations

  ## Feature Flags

  Features can be enabled/disabled via configuration:

      config :raxol, :features,
        web_interface: true,
        terminal_driver: true,
        plugins: false,
        telemetry: true

  """

  use Application
  alias Raxol.Core.Runtime.Log

  @type feature_flag :: atom()
  @type start_mode :: :full | :minimal | :mcp | :custom
  @type child_spec :: Supervisor.child_spec() | {module(), term()} | module()

  @impl Application
  def start(_type, args) do
    start_time = System.monotonic_time(:microsecond)

    # Determine startup mode
    mode = determine_startup_mode(args)

    # Log startup
    log_startup_info(mode)

    # Get children based on mode and configuration
    children = get_children_for_mode(mode)

    # Configure supervisor
    opts = [
      strategy: :one_for_one,
      name: Raxol.Supervisor,
      max_restarts: 10,
      max_seconds: 60
    ]

    # Start supervision tree with error handling
    result = start_supervisor(children, opts)

    # Record actual start time for uptime calculation
    :persistent_term.put(:raxol_start_time, System.monotonic_time(:second))

    # Register headless tools with MCP registry (all environments)
    maybe_register_mcp_tools()

    # Record startup metrics
    record_startup_metrics(start_time, mode, result)

    # Schedule health checks if enabled
    _health_check_ref = schedule_health_checks(mode)

    result
  end

  @impl Application
  def stop(_state) do
    Log.info("Shutting down...")
    :ok
  end

  # Startup Mode Detection

  defp determine_startup_mode(args) do
    cond do
      args[:mode] ->
        args[:mode]

      System.get_env("RAXOL_MODE") == "minimal" ->
        :minimal

      System.get_env("RAXOL_MODE") == "mcp" ->
        :mcp

      Application.get_env(:raxol, :startup_mode) ->
        Application.get_env(:raxol, :startup_mode)

      mix_env() == :test ->
        :test

      true ->
        :full
    end
  end

  defp log_startup_info(mode) do
    preferences_path = Application.get_env(:raxol, :preferences_path)

    if preferences_path && File.exists?(preferences_path) do
      Raxol.Core.Runtime.Log.info_with_context(
        "Loading preferences from #{preferences_path}",
        %{mode: mode}
      )
    else
      Raxol.Core.Runtime.Log.info_with_context(
        "No preferences file found, using defaults.",
        %{mode: mode}
      )
    end

    Raxol.Core.Runtime.Log.info("Starting in #{mode} mode")
  end

  # Children Configuration

  defp get_children_for_mode(:test) do
    # Minimal children for test environment
    # Tests can start their own processes as needed
    [
      {Raxol.Performance.ETSCacheManager, []},
      {Registry, keys: :duplicate, name: :raxol_event_subscriptions},
      Raxol.Core.Runtime.EmitBus,
      {Raxol.DynamicSupervisor, []},
      {Raxol.Core.UserPreferences, [name: Raxol.Core.UserPreferences]}
    ]
  end

  defp get_children_for_mode(:minimal) do
    # Ultra-minimal for quick startup - no terminal drivers for headless environments
    [
      # Core error recovery only
      {Raxol.Core.ErrorRecovery, [mode: :minimal]},
      # Basic telemetry if enabled
      maybe_add_telemetry(:minimal)
    ]
    |> List.flatten()
    |> Enum.filter(& &1)
  end

  defp get_children_for_mode(:mcp) do
    # Lightweight mode for MCP server -- only what headless tools need
    [
      {Raxol.Core.ErrorRecovery, [name: Raxol.Core.ErrorRecovery]},
      {Raxol.Core.UserPreferences, [name: Raxol.Core.UserPreferences]},
      {Raxol.DynamicSupervisor, []},
      {Registry, keys: :duplicate, name: :raxol_event_subscriptions},
      Raxol.Core.Runtime.EmitBus,
      maybe_add_mcp_supervisor(),
      {Raxol.Headless, []},
      maybe_add_pubsub()
    ]
    |> List.flatten()
    |> Enum.filter(& &1)
  end

  defp get_children_for_mode(:full) do
    # Full feature set
    core_children = get_core_children()
    optional_children = get_optional_children()
    feature_children = get_feature_based_children()

    (core_children ++ optional_children ++ feature_children)
    |> List.flatten()
    |> Enum.filter(& &1)
  end

  defp get_children_for_mode(mode) do
    # Custom mode - read from configuration
    config = Application.get_env(:raxol, :startup_children, %{})

    config
    |> Map.get(mode, [])
    |> validate_children()
  end

  defp get_core_children do
    [
      # Essential services that should always run
      {Raxol.Core.ErrorRecovery, [name: Raxol.Core.ErrorRecovery]},
      {Raxol.Core.UserPreferences, [name: Raxol.Core.UserPreferences]},
      {Raxol.DynamicSupervisor, []},
      {Raxol.Terminal.Supervisor, []},
      maybe_add_agent_supervisor(),
      {Registry, keys: :duplicate, name: :raxol_event_subscriptions},
      Raxol.Core.Runtime.EmitBus,
      # MCP server (registry + server, works in all environments)
      maybe_add_mcp_supervisor(),
      # Headless session manager for programmatic app interaction
      {Raxol.Headless, []},

      # Configuration and Debug services
      {Raxol.Config, [name: Raxol.Config]},
      {Raxol.Debug, [name: Raxol.Debug]},

      # Demo services (guarded - may not be compiled)
      maybe_add_demo_services(),

      # Conditional core services
      maybe_add_repo(),
      maybe_add_pubsub(),
      maybe_add_endpoint()
    ]
  end

  defp get_optional_children do
    [
      # Performance monitoring
      maybe_add_performance_monitoring(),
      # Terminal sync
      maybe_add_terminal_sync(),
      # Rate limiting
      maybe_add_rate_limiting(),
      # Development performance tools
      maybe_add_dev_performance_tools(),
      # SSH playground (enabled via RAXOL_SSH_PLAYGROUND=true)
      maybe_add_ssh_playground()
    ]
  end

  defp get_feature_based_children do
    features = Application.get_env(:raxol, :features, %{})

    [
      if(features[:terminal_driver], do: get_terminal_driver_children()),
      if(features[:plugins] && module_available?(Raxol.Plugin.Supervisor),
        do: {Raxol.Plugin.Supervisor, []}
      )
    ]
  end

  # Conditional Child Specifications

  defp maybe_add_repo do
    if feature_enabled?(:database) && module_available?(Raxol.Repo) do
      Raxol.Repo
    else
      if feature_enabled?(:database) do
        Log.debug(
          "[Raxol.Application] Database feature enabled but Raxol.Repo module not available - continuing without database"
        )
      end

      nil
    end
  end

  defp maybe_add_pubsub do
    if feature_enabled?(:pubsub) and Code.ensure_loaded?(Phoenix.PubSub) do
      {Phoenix.PubSub, name: Raxol.PubSub}
    end
  end

  defp maybe_add_endpoint do
    if mix_env() == :dev and Code.ensure_loaded?(Raxol.Endpoint) and
         not Application.get_env(:raxol, :skip_endpoint, false) do
      {Raxol.Endpoint, []}
    end
  end

  defp maybe_add_demo_services do
    if module_available?(Raxol.Demo.SessionManager) do
      [{Raxol.Demo.SessionManager, []}]
    else
      []
    end
  end

  defp maybe_add_agent_supervisor do
    if module_available?(Raxol.Agent.Supervisor) do
      {Raxol.Agent.Supervisor, []}
    end
  end

  defp maybe_add_mcp_supervisor do
    if module_available?(Raxol.MCP.Supervisor) do
      {Raxol.MCP.Supervisor, []}
    end
  end

  defp maybe_add_performance_monitoring do
    if feature_enabled?(:performance_monitoring) do
      [
        {Raxol.Performance.ETSCacheManager, [hibernate_after: 30_000]},
        {Raxol.Performance.Profiler, [hibernate_after: 30_000]}
      ]
    end
  end

  defp maybe_add_terminal_sync do
    if feature_enabled?(:terminal_sync) do
      {Raxol.Terminal.Sync.System, []}
    end
  end

  defp maybe_add_rate_limiting do
    nil
  end

  defp maybe_add_telemetry(mode) do
    if feature_enabled?(:telemetry) &&
         module_available?(Raxol.Core.Telemetry.Supervisor) do
      {Raxol.Core.Telemetry.Supervisor, [mode: mode]}
    else
      if feature_enabled?(:telemetry) do
        Log.debug(
          "[Raxol.Application] Telemetry feature enabled but Raxol.Core.Telemetry.Supervisor module not available - continuing without telemetry"
        )
      end

      nil
    end
  end

  defp maybe_add_dev_performance_tools do
    if mix_env() == :dev and feature_enabled?(:performance_monitoring) do
      [
        {Raxol.Performance.DevHints, []}
      ]
    else
      []
    end
  end

  defp maybe_add_ssh_playground do
    if System.get_env("RAXOL_SSH_PLAYGROUND") == "true" do
      port =
        case System.get_env("RAXOL_SSH_PORT") do
          nil -> 2222
          val -> String.to_integer(val)
        end

      max_connections =
        case System.get_env("RAXOL_SSH_MAX_CONNECTIONS") do
          nil -> 50
          val -> String.to_integer(val)
        end

      host_keys_dir =
        System.get_env("RAXOL_SSH_HOST_KEYS_DIR") || "/app/ssh_keys"

      {
        Raxol.SSH.Server,
        # The playground is a public, read-only component catalog: anonymous
        # access is intended. A fund-bearing surface must set authorized_keys_dir.
        app_module: Raxol.Playground.App,
        port: port,
        host_keys_dir: host_keys_dir,
        max_connections: max_connections,
        allow_anonymous: true
      }
    end
  end

  defp get_terminal_driver_children do
    case {IO.ANSI.enabled?(), System.get_env("FLY_APP_NAME"),
          System.get_env("RAXOL_MODE"), System.get_env("RAXOL_FORCE_TERMINAL")} do
      # Skip terminal driver in minimal mode
      {_, _, "minimal", _} ->
        Log.info("[Raxol.Application] Minimal mode - terminal driver disabled")

        []

      # Skip terminal driver on Fly.io
      {_, fly_app, _, _} when is_binary(fly_app) ->
        Log.info(
          "[Raxol.Application] Running on Fly.io (#{fly_app}) - terminal driver disabled"
        )

        []

      # Start terminal driver if TTY is available
      {true, _, _, _} ->
        [{Raxol.Terminal.Driver, nil}]

      # Force terminal driver if explicitly requested
      {false, _, _, "true"} ->
        Log.warning(
          "[Raxol.Application] Forcing terminal driver despite no TTY"
        )

        [{Raxol.Terminal.Driver, nil}]

      # No TTY and not forced
      {false, _, _, _} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[Raxol.Application] Not attached to a TTY. Terminal driver will not be started.",
          %{}
        )

        []
    end
  end

  # Feature Flag Management

  defp feature_enabled?(feature) do
    features = Application.get_env(:raxol, :features, default_features())
    get_feature_flag(features, feature)
  end

  @doc false
  # Tolerate both a map (the documented shape) and a keyword list, since config
  # files commonly express `config :raxol, :features, key: value` as a keyword
  # list, which Map.get would reject with a BadMapError at boot. Public only so
  # it can be unit-tested directly.
  def get_feature_flag(features, feature) when is_map(features),
    do: Map.get(features, feature, false)

  def get_feature_flag(features, feature) when is_list(features),
    do: Keyword.get(features, feature, false)

  def get_feature_flag(_features, _feature), do: false

  defp default_features do
    %{
      # Changed to false for graceful development
      database: false,
      pubsub: true,
      # Changed to false for graceful development
      web_interface: false,
      terminal_driver: true,
      performance_monitoring: true,
      terminal_sync: true,
      rate_limiting: true,
      telemetry: true,
      plugins: false,
      audit: false,
      dev_performance_hints: mix_env() == :dev
    }
  end

  # Module Availability Checks

  defp module_available?(module) do
    Code.ensure_loaded?(module) && function_exported?(module, :child_spec, 1)
  end

  # Supervisor Starting with Error Handling

  defp start_supervisor(children, opts) do
    case Supervisor.start_link(children, opts) do
      {:ok, pid} = success ->
        Log.info(
          "[Raxol.Application] Supervisor started successfully: #{inspect(pid)}"
        )

        success

      {:error, {:shutdown, {:failed_to_start_child, child, reason}}} = error ->
        handle_child_start_failure(child, reason)
        error

      {:error, reason} = error ->
        Log.error(
          "[Raxol.Application] Failed to start supervisor: #{inspect(reason)}"
        )

        error
    end
  rescue
    exception ->
      Log.error("""
      [Raxol.Application] Exception during startup:
      #{Exception.format(:error, exception, __STACKTRACE__)}
      """)

      {:error, exception}
  end

  defp handle_child_start_failure(child, reason) do
    Log.error("""
    [Raxol.Application] Failed to start child: #{inspect(child)}
    Reason: #{inspect(reason)}
    """)

    # Attempt graceful degradation for non-critical services
    if optional_child?(child) do
      Log.warning(
        "[Raxol.Application] Continuing without optional service: #{inspect(child)}"
      )
    end
  end

  defp optional_child?(child) when is_atom(child) do
    optional_modules = [
      # Added for graceful database degradation
      Raxol.Repo,
      # Added for graceful telemetry degradation
      Raxol.Core.Telemetry.Supervisor,
      Raxol.Plugin.Supervisor,
      Raxol.Terminal.Driver
    ]

    child in optional_modules
  end

  defp optional_child?({child, _}), do: optional_child?(child)
  defp optional_child?(_), do: false

  # Health Monitoring

  defp schedule_health_checks(_mode), do: :ok

  defp count_children do
    case Process.whereis(Raxol.Supervisor) do
      nil -> 0
      pid -> Supervisor.count_children(pid).active
    end
  end

  # Startup Metrics

  defp record_startup_metrics(start_time, mode, result) do
    duration = System.monotonic_time(:microsecond) - start_time
    success = match?({:ok, _}, result)

    :telemetry.execute(
      [:raxol, :application, :startup],
      %{duration: duration},
      %{mode: mode, success: success}
    )

    if success do
      Log.info("Started in #{duration}μs (#{mode} mode)")
    end
  end

  # Child Validation

  defp validate_children(children) do
    children
    |> Enum.filter(&valid_child_spec?/1)
    |> Enum.map(&normalize_child_spec/1)
  end

  defp valid_child_spec?(spec) when is_atom(spec), do: Code.ensure_loaded?(spec)

  defp valid_child_spec?({module, _args}) when is_atom(module),
    do: Code.ensure_loaded?(module)

  defp valid_child_spec?(%{id: _, start: _}), do: true
  defp valid_child_spec?(_), do: false

  defp normalize_child_spec(module) when is_atom(module), do: module

  defp normalize_child_spec({module, args}) when is_atom(module),
    do: {module, args}

  defp normalize_child_spec(spec), do: spec

  # Memory Optimization Helpers

  @doc false
  def configure_process_flags do
    # Set process flags for memory optimization
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)
    :ok
  end

  @doc """
  Dynamically add a child to the supervision tree.
  """
  @spec add_child(child_spec()) :: {:ok, pid()} | {:error, term()}
  def add_child(child_spec) do
    case Process.whereis(Raxol.DynamicSupervisor) do
      nil ->
        {:error, :dynamic_supervisor_not_started}

      pid ->
        DynamicSupervisor.start_child(pid, child_spec)
    end
  end

  @doc """
  Dynamically remove a child from the supervision tree.
  """
  @spec remove_child(pid() | atom()) ::
          :ok | {:error, :dynamic_supervisor_not_started | :not_found}
  def remove_child(child_id) when is_atom(child_id) do
    case Process.whereis(child_id) do
      nil -> {:error, :not_found}
      pid -> remove_child(pid)
    end
  end

  def remove_child(child_pid) when is_pid(child_pid) do
    case Process.whereis(Raxol.DynamicSupervisor) do
      nil ->
        {:error, :dynamic_supervisor_not_started}

      supervisor_pid ->
        DynamicSupervisor.terminate_child(supervisor_pid, child_pid)
    end
  end

  @doc """
  Get current application health status.
  """
  @spec health_status() :: %{
          mode: atom(),
          supervisor_alive: boolean(),
          children: non_neg_integer(),
          memory_mb: non_neg_integer(),
          process_count: non_neg_integer(),
          features: map(),
          uptime_seconds: integer()
        }
  def health_status do
    supervisor_pid = Process.whereis(Raxol.Supervisor)

    %{
      mode: determine_startup_mode([]),
      supervisor_alive:
        is_pid(supervisor_pid) and Process.alive?(supervisor_pid),
      children: count_children(),
      memory_mb: div(:erlang.memory(:total), 1_048_576),
      process_count: :erlang.system_info(:process_count),
      features: Application.get_env(:raxol, :features, default_features()),
      uptime_seconds:
        System.monotonic_time(:second) -
          :persistent_term.get(
            :raxol_start_time,
            System.monotonic_time(:second)
          )
    }
  end

  @doc """
  Toggle a feature flag at runtime.
  Some features require application restart to take effect.
  """
  @spec toggle_feature(feature_flag(), boolean()) ::
          :ok | {:error, :restart_required}
  def toggle_feature(feature, enabled)
      when is_atom(feature) and is_boolean(enabled) do
    current_features =
      Application.get_env(:raxol, :features, default_features())

    new_features = Map.put(current_features, feature, enabled)
    Application.put_env(:raxol, :features, new_features)

    if feature in [:web_interface, :database, :pubsub] do
      {:error, :restart_required}
    else
      :ok
    end
  end

  defp maybe_register_mcp_tools do
    if module_available?(Raxol.MCP.Registry) and
         Process.whereis(Raxol.MCP.Registry) != nil do
      if Code.ensure_loaded?(Raxol.Headless.McpTools) do
        Raxol.Headless.McpTools.register(Raxol.MCP.Registry)
      end

      if Code.ensure_loaded?(Raxol.MCP.AdaptiveTools) and
           Raxol.MCP.AdaptiveTools.available?() do
        Raxol.MCP.AdaptiveTools.register(Raxol.MCP.Registry)
      end
    end

    :ok
  end

  defp mix_env, do: if(Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod)
end
