# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

import Config

# General application configuration
config :raxol,
  ecto_repos: [Raxol.Repo],
  generators: [binary_id: true]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :category,
    :performance_impact,
    :suggestions_count,
    :optimization_context
  ]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

if config_env() == :dev do
  # Configure esbuild version and profiles
  config :esbuild,
    version: "0.25.0",
    raxol: [
      args:
        ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
      cd: Path.expand("../assets", __DIR__),
      env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
    ]

  # Configure dart_sass version
  config :dart_sass, :version, "1.61.0"
end

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# Configure the database
config :raxol, Raxol.Repo,
  database: "raxol_dev",
  hostname: "localhost",
  enabled: true

# Configure the application
# database_enabled is set per environment in dev.exs, test.exs, prod.exs

# It is also possible to import configuration files, relative to this
# directory. For example, you can emulate configuration per environment
# by uncommenting the line below and defining dev.exs, test.exs and such.
# Configuration from the imported file will override the ones defined
# here (which is why it is important to import them last).
#
#     import_config "#{config_env()}.exs"

# Configure terminal settings
config :raxol, :terminal,
  default_width: 80,
  default_height: 24,
  scrollback_lines: 1000,
  enable_ansi: true,
  enable_mouse: true

# Configure buffer system
# Set to :new to use the refactored modular BufferServer
# Set to :old to use the original monolithic BufferServer
config :raxol, :buffer_system, :new

# Configure web interface settings
config :raxol, :web,
  default_theme: "dark",
  enable_websockets: true,
  session_timeout: 3600

# Configure demo terminal
config :raxol, :demo,
  max_sessions: 1000,
  session_timeout_ms: 1_800_000,
  max_sessions_per_ip: 10
