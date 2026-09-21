import Config

# The deployed playground is separate from the root project's dev-only
# Tidewave endpoint. Phoenix 1.8 still defaults `adapter:` to
# `Phoenix.Endpoint.Cowboy2Adapter` only for backwards compatibility
# (`Phoenix.Endpoint.Supervisor`, with a TODO to flip the default to Bandit
# in 2.0). `bandit` is in no lock in this repo, so inheriting that default
# turns a Phoenix major bump into a boot failure; naming Cowboy here makes
# the switch a deliberate edit instead.
#
# Every listener limit below is pinned at or below Cowboy's own default, so
# an upstream default change cannot loosen this listener. Line numbers refer
# to the locked cowboy 2.19.0 / cowlib 2.20.0.
config :raxol_playground, RaxolPlaygroundWeb.Endpoint,
  adapter: Phoenix.Endpoint.Cowboy2Adapter,
  url: [host: "localhost"],
  request_body_options: [
    length: 1_000_000,
    read_length: 64_000,
    read_timeout: 10_000
  ],
  http: [
    compress: true,
    transport_options: [
      # One shared vCPU (fly.toml [[vm]]), so ten accept loops saturate it;
      # Ranch's default of 100 only adds idle processes.
      num_acceptors: 10,
      # Matches [http_service.concurrency] hard_limit in fly.toml: the proxy
      # keeps routing to a machine until it holds 1000 connections, so
      # accepting fewer would only park the difference in the backlog while
      # the proxy still counts the machine as available.
      max_connections: 1_000
    ],
    protocol_options: [
      # Cowboy default 60_000 (cowboy_http.erl:344). Halved: a kept-alive
      # socket with an in-flight stream is cheap to re-establish here, and
      # this still clears the 10_000 ms long-poll window below.
      idle_timeout: 30_000,
      # Cowboy's default (cowboy_http.erl:259). Must stay well above the
      # 10_000 ms `window_ms` of the longpoll transport this endpoint
      # advertises (Phoenix.Transports.LongPoll.default_config/0): Cowboy
      # terminates the connection and kills the in-flight stream with NO
      # response when the connection process sees no message for this long,
      # so any lower ceiling cuts every idle long-poll before it can 204.
      inactivity_timeout: 300_000,
      # Cowboy's default (cowboy_http.erl:343): time to receive a full set of
      # request headers. This is the slow-loris bound; do not raise it.
      request_timeout: 5_000,
      # Cowboy default 1000 (cowboy_http.erl:204). Bounds how much work one
      # socket can pipeline before it must reconnect and re-queue.
      max_keepalive: 100,
      # Cowboy default 8000 (cowboy_http.erl:502). No route here takes a URL
      # near that.
      max_request_line_length: 8_192,
      # Cowboy's default (cowboy_http.erl:681).
      max_header_name_length: 64,
      # Cowboy's default (cowboy_http.erl:770). Large enough for a session
      # cookie plus a forwarded chain, small enough to bound header memory.
      max_header_value_length: 4_096,
      # Cowboy default 100 (cowboy_http.erl:669).
      max_headers: 50,
      # Cowboy default infinity (cow_http2_machine.erl:252). One browser tab
      # needs a handful of HTTP/2 streams; 50 leaves room for a LiveView
      # reconnect storm without letting one connection fan out unbounded.
      max_concurrent_streams: 50,
      # Cowboy default {10_000, 10_000} (cowboy_http2.erl:217).
      max_received_frame_rate: {1_000, 10_000},
      # Cowboy's default (cowboy_http2.erl:223) and the CVE-2023-44487 Rapid
      # Reset guard. Pinned so it cannot be loosened by accident; never
      # raise it.
      max_reset_stream_rate: {10, 10_000}
    ]
  ],
  render_errors: [
    formats: [html: RaxolPlaygroundWeb.ErrorHTML, json: RaxolPlaygroundWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: RaxolPlayground.PubSub,
  live_view: [signing_salt: "raxol_playground_salt"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.19.12",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "3.4.0",
  default: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Configure Raxol playground settings
config :raxol_playground,
  playground: [
    # Enable live code evaluation
    live_eval: true,

    # Code execution timeout (ms)
    eval_timeout: 5000,

    # Maximum code length
    max_code_length: 10_000,

    # Allowed modules for evaluation
    allowed_modules: [
      IO,
      Enum,
      String,
      Process,
      GenServer,
      Agent,
      Task
    ],

    # Component categories
    component_categories: [
      "Input",
      "Display",
      "Navigation",
      "Feedback",
      "Overlay",
      "Layout"
    ],

    # Example configurations
    examples: [
      terminal_editor: %{
        name: "Terminal Text Editor",
        description: "Vi-like terminal text editor",
        complexity: "Advanced",
        estimated_time: "2-3 hours"
      },
      file_browser: %{
        name: "File Browser",
        description: "Navigate and preview files",
        complexity: "Intermediate",
        estimated_time: "1-2 hours"
      },
      dashboard: %{
        name: "System Monitor",
        description: "Real-time system metrics",
        complexity: "Intermediate",
        estimated_time: "2-3 hours"
      },
      chat: %{
        name: "Chat Application",
        description: "Real-time terminal chat",
        complexity: "Advanced",
        estimated_time: "3-4 hours"
      },
      db_client: %{
        name: "Database Client",
        description: "SQL query interface",
        complexity: "Advanced",
        estimated_time: "4-5 hours"
      }
    ]
  ]

# Import environment specific config
import_config "#{config_env()}.exs"
