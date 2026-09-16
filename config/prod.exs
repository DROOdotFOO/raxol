import Config

# Configure your database
config :raxol, Raxol.Repo,
  username: System.get_env("DATABASE_USERNAME", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOSTNAME", "localhost"),
  database: System.get_env("DATABASE_NAME", "raxol_prod"),
  pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
  ssl: true

# Configure terminal settings for production
config :raxol, :terminal,
  default_width: 80,
  default_height: 24,
  scrollback_lines: 1000,
  enable_ansi: true,
  enable_mouse: true,
  debug_mode: false

# Enforce the production threshold in Logger itself.
config :logger, level: :info

# Configure web interface settings for production
config :raxol, :web,
  default_theme: "light",
  enable_websockets: true,
  session_timeout: 3600,
  debug_mode: false,
  enable_hot_reload: false

# Configure production-specific settings
config :raxol, :production,
  enable_metrics: true,
  enable_logging: true,
  enable_error_reporting: true,
  enable_performance_monitoring: true
