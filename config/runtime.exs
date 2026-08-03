import Config

if config_env() == :prod do
  # Configure your database
  config :raxol, Raxol.Repo,
    username: System.get_env("DATABASE_USERNAME", "postgres"),
    password: System.get_env("DATABASE_PASSWORD", "postgres"),
    hostname: System.get_env("DATABASE_HOSTNAME", "localhost"),
    database: System.get_env("DATABASE_NAME", "raxol_prod"),
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true

  # Xochi origin-pull solver pin (#333). Pin the solver collection address the
  # agent will sign pulls to, so a forged/MITM'd quote cannot redirect funds.
  # These must equal Riddler's canonical solver address(es) (the HD-derived
  # submitter; see Riddler Xochi.Config.solver_address/1). The allowlist is a flat
  # set, so when one address serves every chain a single var covers all corridors;
  # a per-chain var is here for each of the five supported chains in case they
  # ever diverge. Permit2 is fail-closed regardless; set
  # XOCHI_PULL_REQUIRE_SOLVER_PIN=true to hard-pin ERC-3009 too.
  xochi_env_solvers =
    ~w(XOCHI_SOLVER_ETH XOCHI_SOLVER_BASE XOCHI_SOLVER_ARBITRUM XOCHI_SOLVER_OPTIMISM XOCHI_SOLVER_POLYGON)
    |> Enum.map(&System.get_env/1)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))

  xochi_require_solver_pin =
    System.get_env("XOCHI_PULL_REQUIRE_SOLVER_PIN", "false") == "true"

  # Fail closed at boot rather than sign origin pulls to an unverified recipient:
  # a deployment that includes the payments app must pin the solver (set the
  # XOCHI_SOLVER_* addresses, or XOCHI_PULL_REQUIRE_SOLVER_PIN=true). Guarded so a
  # release without the payments app (the module is absent) skips the check.
  if Code.ensure_loaded?(Raxol.Payments.Protocols.Xochi) do
    Raxol.Payments.Protocols.Xochi.assert_origin_pull_pinned!(
      xochi_env_solvers,
      xochi_require_solver_pin
    )
  end

  # With XochiPull enabled (Riddler #591), the origin pull routes to the verified
  # per-chain pull contracts, not the bare solver EOA. Trust those verified
  # recipients in addition to any XOCHI_SOLVER_* addresses so a real settlement
  # signs against the deployed contract instead of a rejected `to`/`spender`.
  xochi_solver_allowlist =
    if Code.ensure_loaded?(Raxol.Payments.Xochi.PullContracts) do
      Enum.uniq(
        xochi_env_solvers ++
          Raxol.Payments.Xochi.PullContracts.pull_recipients()
      )
    else
      xochi_env_solvers
    end

  config :raxol_payments,
    pull_solver_allowlist: xochi_solver_allowlist,
    pull_require_solver_pin: xochi_require_solver_pin

  # Settlement accounting + rebalance advisor (default off). When enabled, each
  # Xochi settlement is booked (fee vs on-chain gas) into a SettlementLedger and the
  # RebalanceAdvisor runs periodically. Read-only: it reads the solver's balances
  # and receipts over public RPC and never moves funds (the Riddler auto-rebalancer
  # executes). Enable with RAXOL_ACCOUNTING_ENABLED=true and set the RPC_* + solver
  # address vars. The env contract lives in Raxol.Payments.Accounting so this file and
  # the raxol_earn sidecar release config read it identically. Guarded so a release
  # without the payments app (the module is absent) skips it.
  if Code.ensure_loaded?(Raxol.Payments.Accounting) do
    {accounting_opts, accounting_enabled} =
      Raxol.Payments.Accounting.env_config()

    config :raxol_payments, :accounting, accounting_opts
    config :raxol_earn, accounting_enabled: accounting_enabled
  end

  # Configure terminal settings from environment
  config :raxol, :terminal,
    default_width: String.to_integer(System.get_env("TERMINAL_WIDTH") || "80"),
    default_height:
      String.to_integer(System.get_env("TERMINAL_HEIGHT") || "24"),
    scrollback_lines:
      String.to_integer(System.get_env("TERMINAL_SCROLLBACK") || "1000"),
    enable_ansi: System.get_env("TERMINAL_ANSI", "true") == "true",
    enable_mouse: System.get_env("TERMINAL_MOUSE", "true") == "true",
    debug_mode: System.get_env("TERMINAL_DEBUG", "false") == "true",
    log_level: String.to_atom(System.get_env("TERMINAL_LOG_LEVEL") || "info"),
    virtual_scroll_size:
      String.to_integer(
        System.get_env("TERMINAL_VIRTUAL_SCROLL_SIZE") || "1000"
      ),
    memory_limit:
      String.to_integer(System.get_env("TERMINAL_MEMORY_LIMIT") || "52428800"),
    cleanup_interval:
      String.to_integer(System.get_env("TERMINAL_CLEANUP_INTERVAL") || "60000")

  # Configure web interface settings from environment
  config :raxol, :web,
    default_theme: System.get_env("WEB_THEME", "light"),
    enable_websockets: System.get_env("WEB_WEBSOCKETS", "true") == "true",
    session_timeout:
      String.to_integer(System.get_env("WEB_SESSION_TIMEOUT") || "3600"),
    debug_mode: System.get_env("WEB_DEBUG", "false") == "true",
    enable_hot_reload: System.get_env("WEB_HOT_RELOAD", "false") == "true",
    reduced_motion: System.get_env("REDUCED_MOTION", "false") == "true",
    high_contrast: System.get_env("HIGH_CONTRAST", "false") == "true",
    font_family:
      System.get_env("WEB_FONT_FAMILY", "JetBrains Mono, SF Mono, monospace"),
    font_size: String.to_integer(System.get_env("WEB_FONT_SIZE") || "14"),
    line_height: String.to_float(System.get_env("WEB_LINE_HEIGHT") || "1.2")

  # Configure production-specific settings from environment
  config :raxol, :production,
    enable_metrics: System.get_env("ENABLE_METRICS", "true") == "true",
    enable_logging: System.get_env("ENABLE_LOGGING", "true") == "true",
    enable_error_reporting:
      System.get_env("ENABLE_ERROR_REPORTING", "true") == "true",
    enable_performance_monitoring:
      System.get_env("ENABLE_PERFORMANCE_MONITORING", "true") == "true",
    memory_warning_threshold:
      String.to_integer(
        System.get_env("MEMORY_WARNING_THRESHOLD") || "41943040"
      ),
    performance_sampling_rate:
      String.to_integer(System.get_env("PERFORMANCE_SAMPLING_RATE") || "1000")
end
