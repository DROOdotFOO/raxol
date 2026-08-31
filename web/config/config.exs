import Config

# Configure the endpoint
config :raxol_playground, RaxolPlaygroundWeb.Endpoint,
  url: [host: "localhost"],
  # Compress dynamic responses. `Plug.Static`'s `gzip:` covers pre-compressed
  # assets on disk and nothing else, so every HTML response left here
  # uncompressed: the landing page alone is hundreds of kilobytes, most of it
  # the hero's recorded frames, which are braille and repeated spans and so
  # compress about fortyfold.
  #
  # `compress: true` rather than a hand-written `stream_handlers` list under
  # `protocol_options`: `Plug.Cowboy` reads both as TOP-LEVEL options and
  # merges its own defaults last, so a nested list is silently overridden and
  # the page ships uncompressed anyway. This form also keeps
  # `cowboy_telemetry_h`, which naming the handlers by hand drops.
  http: [compress: true],
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
