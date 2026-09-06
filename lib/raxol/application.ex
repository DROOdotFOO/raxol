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

    # Put those same tools in front of a Tidewave client, gated the same way.
    maybe_inject_tidewave_tools()

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
      maybe_add_ssh_playground(),
      # Hosted coding agent over SSH (RAXOL_SSH_CODE=true, multi-tenant)
      maybe_add_ssh_code()
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

  # Listing methods only. They disclose the names the server already advertises;
  # `resources/read` and the subscribe pair stream live model state and so are
  # absent on purpose.
  @default_production_read_methods [
    "tools/list",
    "resources/list",
    "prompts/list",
    "prompts/get",
    "completion/complete"
  ]

  # Empty opts meant `authorizer: nil`, and a nil authorizer is ALLOW -- see
  # `Raxol.MCP.Authorizer`, which documents that default as safe because a stdio
  # transport already inherits the OS process boundary. That reasoning holds for
  # stdio and holds for nothing else, so the decision is made HERE rather than
  # inherited from an empty list.
  #
  # `config :raxol, :mcp_authorizer` / `:mcp_read_authorizer` take a 3-arity
  # `(tool_name, arguments, context) -> decision` fun and win when set. Otherwise
  # production resolves an allowlist driven by `:mcp_allowed_tools` /
  # `:mcp_allowed_read_methods`.
  defp maybe_add_mcp_supervisor do
    if module_available?(Raxol.MCP.Supervisor) do
      production? = mcp_production?()

      {Raxol.MCP.Supervisor,
       [
         authorizer: resolve_mcp_authorizer(:mcp_authorizer, production?),
         read_authorizer:
           resolve_mcp_authorizer(:mcp_read_authorizer, production?)
       ]}
    end
  end

  @doc false
  @spec resolve_mcp_authorizer(atom(), boolean()) ::
          (String.t(), map(), map() -> term())
  def resolve_mcp_authorizer(key, production?) do
    case Application.get_env(:raxol, key) do
      nil ->
        default_mcp_authorizer(key, production?)

      fun when is_function(fun, 3) ->
        fun

      other ->
        # Ignoring this would reinstate the exact bug the explicit opts fix: a
        # deployment that believes it configured a policy, running without one.
        raise ArgumentError,
              "config :raxol, #{inspect(key)} must be a 3-arity fun " <>
                "(tool_name, arguments, context) -> :allow | {:ask, prompt} | " <>
                "{:deny, reason}, got: #{inspect(other)}"
    end
  end

  # Outside production: `allow_all/0`. Behaviourally what the implicit nil already
  # did, but said out loud, so `mix mcp.server` and the Tidewave dev endpoint keep
  # working and the opt-out is visible in the code rather than implied by an empty
  # list.
  defp default_mcp_authorizer(_key, false), do: Raxol.MCP.Authorizer.allow_all()

  # In production: a real authorizer, and specifically NOT `allow_all/0`.
  # `Raxol.MCP.Server.authorization_configured?/1` is literally `authorizer !=
  # nil`, and the SSE transport's boot gate
  # (`Raxol.MCP.Deployment.enforce_authorization!/2`) reads exactly that value, so
  # a blanket allow here would satisfy the gate and let a NETWORK transport serve
  # every tool unguarded -- the one outcome that gate exists to prevent.
  #
  # An empty allowlist is strictly TIGHTER than the nil this replaced, not merely
  # more explicit: `Authorizer.decide/4` treats nil as allow, so a production
  # server previously ran any tool nobody had annotated sensitive. Now nothing
  # runs until a deployment names it.
  defp default_mcp_authorizer(:mcp_authorizer, true) do
    Raxol.MCP.Authorizer.allowlist(
      Application.get_env(:raxol, :mcp_allowed_tools, [])
    )
  end

  # Reads cannot default to the same empty list: `tools/list` is a read, so
  # denying everything would leave even an allowlisted tool undiscoverable and
  # the server unusable rather than merely closed. The split is by what the
  # method DISCLOSES -- listing methods reveal names, which are already the
  # server's advertised surface, while `resources/read` and the subscribe pair
  # stream live model state to whoever connects.
  defp default_mcp_authorizer(:mcp_read_authorizer, true) do
    Raxol.MCP.Authorizer.allowlist(
      Application.get_env(
        :raxol,
        :mcp_allowed_read_methods,
        @default_production_read_methods
      )
    )
  end

  # The HOST application's environment, deliberately NOT
  # `Raxol.MCP.Deployment.production?/0`. That one is captured at raxol_mcp's
  # COMPILE time, and as its own moduledoc says, a path dependency compiles under
  # :prod regardless of the umbrella's env -- so it reads `true` inside a dev
  # session. Selecting the default from it handed dev the production allowlist
  # and denied every tool in `mix mcp.server` and Tidewave, which is the exact
  # opposite of what the dev default is for.
  #
  # `mix_env/0` is read at runtime and answers for this application: `:dev` in a
  # dev session, and `:prod` in a release, where Mix is absent entirely. It is
  # already what decides whether the dev endpoint starts at all.
  defp mcp_production?, do: mix_env() not in [:dev, :test]

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
        # Anonymous surfaces bind loopback unless RAXOL_SSH_ANONYMOUS_PUBLIC=1
        # separately acknowledges the exposure, and must state every resource
        # cap or the server refuses to start.
        app_module: Raxol.Playground.App,
        port: port,
        host_keys_dir: host_keys_dir,
        allow_anonymous: true,
        max_connections: max_connections,
        max_per_ip: ssh_env_int("RAXOL_SSH_MAX_PER_IP", 10),
        idle_timeout: :timer.seconds(ssh_env_int("RAXOL_SSH_IDLE_SECONDS", 300)),
        max_session_duration:
          :timer.seconds(ssh_env_int("RAXOL_SSH_MAX_SESSION_SECONDS", 3600))
      }
    end
  end

  defp ssh_env_int(name, default) do
    case System.get_env(name) do
      nil -> default
      val -> String.to_integer(val)
    end
  end

  # The hosted coding agent: multi-tenant ONLY. This surface reaches
  # write/shell tools, so it never serves anonymously and never serves
  # single-tenant from a shared host — no tenants root, no server.
  # raxol_agent is optional for main raxol; without it the child is
  # skipped with a log rather than crashing boot.
  @compile {:no_warn_undefined,
            [
              Raxol.Agent.Code.App,
              Raxol.Agent.Code.Tenant,
              Raxol.Payments.Ledger,
              Raxol.Payments.SpendingPolicy,
              Decimal
            ]}
  defp maybe_add_ssh_code do
    enabled? = System.get_env("RAXOL_SSH_CODE") == "true"
    tenants = System.get_env("RAXOL_SSH_CODE_TENANTS")

    cond do
      not enabled? ->
        nil

      tenants in [nil, ""] ->
        Log.warning(
          "[Raxol.Application] RAXOL_SSH_CODE=true requires " <>
            "RAXOL_SSH_CODE_TENANTS (the per-user key root); refusing to " <>
            "serve the coding agent without tenant auth"
        )

        nil

      not code_agent_available?() ->
        Log.warning(
          "[Raxol.Application] RAXOL_SSH_CODE=true but raxol_agent is not " <>
            "in this build; coding-agent SSH disabled"
        )

        nil

      not http_client_available?() ->
        Log.warning(
          "[Raxol.Application] RAXOL_SSH_CODE=true but no HTTP client " <>
            "(req) is in this build; every LLM turn would fail with " <>
            ":req_not_available, so coding-agent SSH is disabled"
        )

        nil

      true ->
        ssh_code_children(tenants)
    end
  end

  # A hosted tenant spends the HOST's provider credential, so the budget is
  # not optional: without a ledger every tenant's spend is unbounded and
  # unattributed (`CostLedger.check/3` has nothing to ask and passes). Refuse
  # to serve rather than serve unmetered — the same fail-closed posture the
  # tenants-root check above takes for auth.
  defp ssh_code_children(tenants) do
    case ssh_code_budget() do
      {:ok, policy} ->
        [
          Supervisor.child_spec(
            {Raxol.Payments.Ledger, name: Raxol.SSH.CodeLedger},
            id: :ssh_code_ledger
          ),
          ssh_code_server_spec(tenants, policy)
        ]

      {:error, message} ->
        Log.warning(
          "[Raxol.Application] RAXOL_SSH_CODE=true but #{message}; refusing " <>
            "to serve the coding agent without a spending budget"
        )

        nil
    end
  end

  defp ssh_code_server_spec(tenants, policy) do
    port = ssh_code_port()
    host_keys_dir = System.get_env("RAXOL_SSH_HOST_KEYS_DIR") || "/app/ssh_keys"

    # A distinct child id and server name: the playground SSH server
    # may run beside this one in the same tree.
    Supervisor.child_spec(
      {
        Raxol.SSH.Server,
        # Server-wide: one ledger, one policy. The per-tenant `agent_id`
        # (`ssh:<user>`, from Tenant.app_opts, which wins over these) is the
        # ledger scope key, so each tenant draws on their own budget.
        name: Raxol.SSH.CodeServer,
        app_module: Raxol.Agent.Code.App,
        port: port,
        host_keys_dir: host_keys_dir,
        tenants_dir: tenants,
        app_opts: [ledger: Raxol.SSH.CodeLedger, spending_policy: policy],
        tenant_opts: &Raxol.Agent.Code.Tenant.app_opts(tenants, &1)
      },
      id: :ssh_code_server
    )
  end

  @doc false
  # `RAXOL_SSH_CODE_BUDGET_USD` is the per-tenant lifetime cap. Parsed
  # fail-closed: absent, unparseable, or non-positive all refuse. Public so
  # the refusal rules are testable without standing up a real SSH daemon.
  @spec ssh_code_budget() :: {:ok, struct()} | {:error, String.t()}
  def ssh_code_budget do
    # The operator-fixable cause is reported first: a missing cap is a config
    # mistake they can correct, a missing raxol_payments is a build they have
    # to rebuild. Both refuse.
    with {:ok, usd} <- parse_budget(System.get_env("RAXOL_SSH_CODE_BUDGET_USD")),
         true <- payments_available?() do
      # `struct/2`, not a struct literal: raxol_payments is not a compile-time
      # dependency of main raxol (the dependency runs the other way), so the
      # struct cannot be expanded here — only built once the module is loaded,
      # which `payments_available?/0` has just established.
      cap = Decimal.from_float(usd)

      {:ok,
       struct(Raxol.Payments.SpendingPolicy,
         lifetime_max: cap,
         session_max: cap,
         currency: "USD"
       )}
    else
      false ->
        {:error, "raxol_payments is not in this build (no ledger to meter on)"}

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_budget(value) when value in [nil, ""],
    do: {:error, "RAXOL_SSH_CODE_BUDGET_USD is not set"}

  defp parse_budget(value) do
    case Float.parse(String.trim(value)) do
      {usd, ""} when usd > 0.0 ->
        {:ok, usd}

      _ ->
        {:error,
         "RAXOL_SSH_CODE_BUDGET_USD #{inspect(value)} is not a positive amount"}
    end
  end

  defp payments_available? do
    Code.ensure_loaded?(Raxol.Payments.Ledger) and
      Code.ensure_loaded?(Raxol.Payments.SpendingPolicy) and
      Code.ensure_loaded?(Decimal)
  end

  # raxol_agent presence, checked by loadability of the modules the child spec
  # actually needs. NOT `function_exported?(Code.App, :child_spec, 1)`: Code.App
  # is a TEA module (`use Raxol.Core.Runtime.Application`) and never defines
  # child_spec/1, so that test was always false and the server never started.
  defp code_agent_available? do
    Code.ensure_loaded?(Raxol.Agent.Code.App) and
      Code.ensure_loaded?(Raxol.Agent.Code.Tenant)
  end

  @doc false
  # req is an OPTIONAL dep of raxol_agent, and optional deps do not propagate
  # to a release that merely depends on it. Every remote provider resolves to
  # Backend.HTTP, which answers {:error, :req_not_available} without it -- so a
  # release can pass every other gate here and still be unable to make a single
  # LLM call. Fail closed at boot rather than per turn, per tenant.
  @spec http_client_available?() :: boolean()
  def http_client_available?, do: Code.ensure_loaded?(Req)

  # Degrade a malformed port to the default with a warning, the way every other
  # arm of maybe_add_ssh_code/0 degrades — never let it raise and take down the
  # whole application supervisor at boot.
  defp ssh_code_port do
    case System.get_env("RAXOL_SSH_CODE_PORT") do
      value when value in [nil, ""] ->
        2223

      value ->
        case Integer.parse(String.trim(value)) do
          {port, ""} when port > 0 and port < 65_536 ->
            port

          _ ->
            Log.warning(
              "[Raxol.Application] RAXOL_SSH_CODE_PORT #{inspect(value)} is " <>
                "not a valid port; using 2223"
            )

            2223
        end
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

      if Code.ensure_loaded?(Raxol.Headless.DocsResource) do
        Raxol.Headless.DocsResource.register(Raxol.MCP.Registry)
      end

      if Code.ensure_loaded?(Raxol.MCP.AdaptiveTools) and
           Raxol.MCP.AdaptiveTools.available?() do
        Raxol.MCP.AdaptiveTools.register(Raxol.MCP.Registry)
      end

      # The coding-agent harness tools live in raxol_agent, which main raxol
      # does not depend on; they register only when that package is loaded
      # in this VM (e.g. `mix mcp.server` run from packages/raxol_agent).
      if Code.ensure_loaded?(Raxol.Agent.Harness.McpTools) do
        apply(Raxol.Agent.Harness.McpTools, :register, [Raxol.MCP.Registry])
      end
    end

    :ok
  end

  # Tidewave dispatches out of its own map, so without this its client sees
  # Tidewave's tools and none of ours. `inject_into_tidewave/1` supplies closures
  # that re-enter through `Raxol.MCP.Server`, so what lands there answers to the
  # same authorizer as every other MCP surface.
  #
  # Dev-scoped by construction rather than by a check here: `:tidewave` is an
  # `only: :dev` dependency, so outside dev the module does not exist and this is
  # false. `Raxol.Endpoint`, which mounts it, is likewise dev-only.
  #
  # Set `config :raxol, inject_tidewave_tools: false` to opt out.
  defp maybe_inject_tidewave_tools do
    if Code.ensure_loaded?(Tidewave) and
         Code.ensure_loaded?(Raxol.Headless.McpTools) and
         Application.get_env(:raxol, :inject_tidewave_tools, true) do
      inject_tidewave_tools()
    end

    :ok
  end

  # A convenience, not a boot requirement: Tidewave refuses to start without Mix
  # running, and a release has no Tidewave at all, so "not started" is an
  # ordinary outcome rather than a failure worth taking the application down for.
  defp inject_tidewave_tools do
    case Raxol.Headless.McpTools.inject_into_tidewave() do
      :ok ->
        :ok

      {:error, reason} ->
        Log.debug(
          "Raxol tools were not injected into Tidewave (#{inspect(reason)}); " <>
            "Tidewave's own tools are unaffected."
        )

        :ok
    end
  end

  defp mix_env, do: if(Code.ensure_loaded?(Mix), do: Mix.env(), else: :prod)
end
