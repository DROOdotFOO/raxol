import Config

# The deployed playground is separate from the root project's dev-only
# Tidewave endpoint. Both projects declare `plug_cowboy`, so pin Cowboy here
# and bound the public listener's Ranch transport and Cowboy protocols
# explicitly rather than inheriting Phoenix defaults.
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
    transport_options: [num_acceptors: 10, max_connections: 500],
    protocol_options: [
      idle_timeout: 30_000,
      inactivity_timeout: 10_000,
      request_timeout: 10_000,
      max_keepalive: 100,
      max_request_line_length: 8_192,
      max_header_name_length: 64,
      max_header_value_length: 8_192,
      max_headers: 50,
      max_concurrent_streams: 50,
      max_received_frame_rate: {1_000, 10_000},
      max_reset_stream_rate: {100, 10_000}
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
    args: ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
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
