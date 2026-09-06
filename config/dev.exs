import Config

# Enable web interface in dev
config :raxol, :features, %{
  web_interface: true,
  pubsub: true,
  database: false,
  terminal_driver: true,
  performance_monitoring: true,
  terminal_sync: true,
  rate_limiting: false,
  telemetry: true,
  plugins: false,
  audit: false,
  dev_performance_hints: true
}

# Disable Ecto repos for dev (Raxol uses Phoenix as library, no active Repo)
# This prevents Tidewave from trying to use Ecto tools
config :raxol, ecto_repos: []

# Configure your database (not started in dev)
config :raxol, Raxol.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "raxol_dev",
  template: "template0",
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  pool_size: 10

# Dev endpoint for Tidewave MCP (localhost:<port>/tidewave/mcp).
# RAXOL_DEV_PORT pins an explicit port; otherwise probe upward from 4000
# for the first free one, so a co-resident service on 4000 (e.g. a local
# LiteLLM) doesn't take the whole app down with :eaddrinuse. The probe
# binds the same interface with no SO_REUSEADDR as the endpoint itself
# binds -- a truthful free/busy read, not a false positive.
dev_bind_ip = {127, 0, 0, 1}

resolve_dev_port = fn ->
  case System.get_env("RAXOL_DEV_PORT") do
    nil ->
      base = 4000

      port =
        Enum.find(base..(base + 50), base, fn candidate ->
          case :gen_tcp.listen(candidate, [:binary, {:ip, dev_bind_ip}]) do
            {:ok, socket} -> :gen_tcp.close(socket) == :ok
            {:error, _} -> false
          end
        end)

      if port != base do
        IO.puts(
          :stderr,
          "[raxol] port #{base} in use; serving web on #{port}. " <>
            "Set RAXOL_DEV_PORT to pin a port."
        )
      end

      port

    explicit ->
      String.to_integer(explicit)
  end
end

# Loopback, explicitly. Phoenix binds 0.0.0.0 when `ip:` is absent, and this
# endpoint mounts Tidewave, whose `project_eval` evaluates Elixir in the running
# BEAM with no authentication in front of it. On 0.0.0.0 that is remote code
# execution on the developer's machine for anyone who can reach the port, which
# on a shared or public network is anyone on it. Nothing here needs to be
# reachable off-host: it is a dev tool for an MCP client running locally.
#
# Widening this back to 0.0.0.0 (to drive the endpoint from a phone, a VM, or a
# container) re-exposes `project_eval`. Put it behind something first.
config :raxol, Raxol.Endpoint,
  http: [ip: dev_bind_ip, port: resolve_dev_port.()],
  server: true,
  secret_key_base: String.duplicate("dev", 22)

# Enable LiveView debug features for Tidewave
config :phoenix_live_view,
  debug_heex_annotations: true,
  debug_attributes: true

# Configure terminal settings for development
config :raxol, :terminal,
  default_width: 80,
  default_height: 24,
  scrollback_lines: 1000,
  enable_ansi: true,
  enable_mouse: true,
  debug_mode: false,
  log_level: :info

# Configure web interface settings for development
config :raxol, :web,
  default_theme: "light",
  enable_websockets: true,
  session_timeout: 3600,
  debug_mode: false,
  enable_hot_reload: true

# AI Service Configuration
config :raxol, :ai_service,
  local_endpoint:
    System.get_env("AI_LOCAL_ENDPOINT", "http://localhost:8080/v1/completions"),
  timeout: String.to_integer(System.get_env("AI_TIMEOUT", "30000"))

# Streaming Data Configuration  
config :raxol, :streaming,
  default_websocket_endpoint:
    System.get_env("WS_ENDPOINT", "ws://localhost:8080"),
  metrics_path: "/metrics",
  data_path: "/data"

# Task timeouts
config :raxol, :timeouts,
  task_yield: String.to_integer(System.get_env("TASK_YIELD_TIMEOUT", "3000")),
  task_yield_long:
    String.to_integer(System.get_env("TASK_YIELD_LONG_TIMEOUT", "30000")),
  circuit_breaker_reset:
    String.to_integer(System.get_env("CIRCUIT_BREAKER_RESET", "30000"))
