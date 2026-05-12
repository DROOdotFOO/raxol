defmodule Raxol.MixProject do
  use Mix.Project

  @version "2.4.0"
  @source_url "https://github.com/DROOdotFOO/raxol"

  def project do
    [
      app: :raxol,
      version: @version,
      elixir: "~> 1.17 or ~> 1.18 or ~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      elixirc_options: [
        warnings_as_errors: Mix.env() == :prod,
        compile_order: [:cell, :operations]
      ],
      compilers: compilers(),
      consolidate_protocols: Mix.env() != :test,
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Raxol",
      source_url: @source_url,
      test_coverage: [
        tool: ExCoveralls,
        ignore_modules: [
          :termbox2_nif,
          Termbox2Nif,
          # OTP 26 cover tool crashes on this module's abstract code
          # (Elixir 1.19 column-annotated forms + Logger macro expansion)
          Raxol.Core.Runtime.Log
        ]
      ],
      # NIF compilation moved to packages/raxol_terminal

      usage_rules: usage_rules(),
      dialyzer: [
        # PLT Configuration for caching
        plt_core_path: "priv/plts/core.plt",
        plt_local_path: "priv/plts/local.plt",

        # Add applications to PLT for better analysis
        plt_add_apps: [
          :ex_unit,
          :mix,
          :iex,
          :tools,
          :phoenix,
          :phoenix_live_view,
          :ecto,
          :postgrex,
          :jason,
          :plug
        ],

        # Analysis flags for comprehensive checking
        flags: [
          :error_handling,
          :underspecs,
          :unmatched_returns,
          :unknown
        ],

        # Ignore warnings file
        ignore_warnings: ".dialyzer_ignore.exs",

        # List of paths to include in analysis
        paths: [
          "_build/#{Mix.env()}/lib/raxol/ebin"
        ],

        # Modules to ignore (can be added as needed)
        ignore_modules: [
          # Add modules that consistently produce false positives
        ]
      ]
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # NIF compilation now handled by raxol_terminal package
  defp compilers do
    Mix.compilers()
  end

  # Raxol is primarily a library/toolkit; applications using it define their own OTP app.
  def application do
    [
      mod: {Raxol.Application, []},
      extra_applications:
        [
          :kernel,
          :stdlib,
          # Phoenix/PubSub: only autoload outside :test. The `Code.ensure_loaded?`
          # guards in `Raxol.Core.Runtime.Rendering.Backends` and `Raxol.PubSub`
          # mean the modules are referenced lazily, and no test exercises them.
          # Loading them on every test run added ~50-100MB of supervisor state
          # for zero benefit.
          # :ecto_sql,  # Removed to prevent auto-starting Repo
          # :postgrex,  # Removed to prevent auto-starting Repo
          :runtime_tools,
          # NIF integration now working with elixir_make
          # :termbox2_nif,
          :toml,
          :jason,
          :telemetry,
          :file_system,
          # :mnesia, :os_mon -- removed: unused at runtime in tests, os_mon
          # also produces misleading process_memory_high_watermark log noise.
          :ssh,
          :public_key,
          :crypto
        ] ++ phoenix_applications() ++ test_applications()
    ]
  end

  defp elixirc_paths(:test),
    do: [
      "lib",
      "test/support",
      "examples/demos"
    ]

  defp elixirc_paths(_), do: ["lib"]

  defp test_applications do
    if Mix.env() == :test do
      # Removed :ecto_sql to prevent auto-starting Repo
      [:mox]
    else
      []
    end
  end

  # Phoenix is auto-started in dev and prod (the dev endpoint serves Tidewave;
  # prod can use the LiveView bridge). In test, no test references Phoenix
  # directly, so skip it -- saves significant memory on the GitHub runner.
  defp phoenix_applications do
    if Mix.env() == :test do
      []
    else
      [:phoenix, :phoenix_html, :phoenix_live_view, :phoenix_pubsub]
    end
  end

  defp deps do
    [
      # Modular Raxol Packages (path deps for development, version deps for publishing)
      modular_packages(),

      # Core Terminal Dependencies
      core_deps(),

      # Phoenix Web Framework
      phoenix_deps(),

      # Database Dependencies
      database_deps(),

      # Visualization & UI
      visualization_deps(),

      # Development & Testing
      development_deps(),

      # Utilities & System
      utility_deps(),

      # Internationalization
      i18n_deps()
    ]
    |> List.flatten()
  end

  defp modular_packages do
    [
      raxol_dep(:raxol_core, "~> 2.4", "packages/raxol_core"),
      raxol_dep(:raxol_terminal, "~> 2.4", "packages/raxol_terminal"),
      raxol_dep(:raxol_sensor, "~> 2.4", "packages/raxol_sensor"),
      raxol_dep(:raxol_mcp, "~> 2.4", "packages/raxol_mcp"),
      raxol_dep(:raxol_liveview, "~> 2.4", "packages/raxol_liveview"),
      raxol_dep(:raxol_plugin, "~> 2.4", "packages/raxol_plugin")
    ]
  end

  defp raxol_dep(name, version, path) do
    if System.get_env("HEX_BUILD") || !File.dir?(path) do
      {name, version}
    else
      {name, version, path: path, override: true}
    end
  end

  defp core_deps do
    [
      # Connection pooling library (optional)
      {:poolboy, "~> 1.5", optional: true},
      # Tutorial loading frontmatter parser
      {:yaml_elixir, "~> 2.12"},
      # Syntax highlighting core
      {:makeup, "~> 1.2"},
      # Elixir syntax highlighting
      {:makeup_elixir, "~> 1.0.1"},
      # System clipboard access
      {:clipboard, "~> 0.2.1"},
      # Efficient circular buffer implementation
      {:circular_buffer, "~> 1.0"},
      # Plugin dependencies (optional - only needed for specific plugins)
      {:req, "~> 0.5", optional: true}
      # {:oauth2, "~> 2.1", optional: true}  # Removed - unused
    ]
  end

  defp phoenix_deps do
    [
      {:phoenix, "~> 1.8.1"},
      {:phoenix_pubsub, "~> 2.1"},
      {:phoenix_ecto, "~> 4.4", optional: true},
      {:phoenix_live_view, "~> 1.1.13"},
      {:phoenix_html, "~> 4.3"},
      {:plug_cowboy, "~> 2.7"},
      {:phoenix_live_dashboard, "~> 0.8.7", only: :dev},
      {:phoenix_live_reload, "~> 1.6.1", only: :dev}
    ]
  end

  defp database_deps do
    [
      {:ecto_sql, "~> 3.12", optional: true},
      {:postgrex, "~> 0.22.0", optional: true, runtime: false}
      # Password hashing (removed - unused)
      # {:bcrypt_elixir, "~> 3.3", optional: true}
    ]
  end

  defp visualization_deps do
    [
      # Image processing (for terminal image rendering)
      {:mogrify, "~> 0.9.3", optional: true},
      # Charts and plots
      {:contex, "~> 0.5.0", optional: true}
    ]
  end

  defp development_deps do
    [
      # Build tools (web assets)
      {:esbuild, "~> 0.10", only: :dev, runtime: false},
      {:dart_sass, "~> 0.7", only: :dev, runtime: false},
      {:elixir_make, "~> 0.9", runtime: false},

      # Code quality
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:earmark, "~> 1.4", only: :dev},

      # Security scanning
      {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},

      # AI development tools
      {:tidewave, "~> 0.5.4", only: :dev},
      {:usage_rules, "~> 1.2", only: :dev},

      # Testing
      {:mox, "~> 1.2", only: :test},
      {:meck, "~> 1.0", only: :test},
      {:excoveralls, "~> 0.18", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},
      {:junit_formatter, "~> 3.4", only: :test},

      # Benchmarking suite
      {:benchee, "~> 1.3", only: [:dev, :test]},
      {:benchee_html, "~> 1.0", only: [:dev, :test]},
      {:benchee_json, "~> 1.0", only: [:dev, :test]}
    ]
  end

  defp utility_deps do
    [
      # JSON processing
      {:jason, "~> 1.4.4"},
      # UUID generation
      {:uuid, "~> 1.1"},
      # TOML configuration
      {:toml, "~> 0.7"},
      # MIME type detection (removed - unused)
      # {:mimerl, "~> 1.4"},
      # HTTP client (for optional integrations)
      {:httpoison, "~> 2.2", optional: true},
      # Localization
      {:gettext, "~> 1.0"},
      # File system watching
      {:file_system, "~> 1.1"},
      # Automatic cluster node discovery (optional, for Swarm)
      {:libcluster, "~> 3.4", optional: true},
      # Numerical computing (optional, for adaptive ML)
      {:nx, "~> 0.9", optional: true},
      # Neural network training (optional, for adaptive ML)
      {:axon, "~> 0.7", optional: true},

      # Telemetry & monitoring
      {:telemetry, "~> 1.3"},
      {:telemetry_metrics, "~> 1.1"},
      {:telemetry_poller, "~> 1.2"}
      # {:telemetry_metrics_prometheus, "~> 1.1"} # Removed - unused
    ]
  end

  defp i18n_deps do
    # ex_cldr deps removed - unused. Re-add when i18n is implemented.
    []
  end

  defp usage_rules do
    [
      file: "CLAUDE.md",
      usage_rules: [:elixir, :otp]
    ]
  end

  defp aliases do
    [
      setup: ["deps.get"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: [
        # "ecto.create -r Raxol.Repo --quiet",  # Removed to prevent Ecto.Repo requirement
        # "ecto.migrate -r Raxol.Repo",  # Removed to prevent Ecto.Repo requirement
        "test"
      ],
      "assets.setup": [
        "esbuild.install --if-missing",
        "sass.install --if-missing"
      ],
      "assets.deploy": ["sass.deploy"],
      "assets.build": [
        "sass default"
      ],
      "explain.credo": ["run scripts/explain_credo_warning.exs"],
      lint: ["credo"],
      # Verifies mix.lock is consistent with mix.exs without fetching new deps.
      # Run after editing mix.exs to confirm the lockfile is committed too.
      # This is the same check CI runs to prevent the failure mode where a new
      # dep was added but mix.lock was forgotten.
      "lockfile.check": ["deps.get --check-locked"],
      # Dialyzer commands
      "dialyzer.setup": ["dialyzer --plt"],
      "dialyzer.check": ["dialyzer --format dialyxir"],
      "dialyzer.clean": ["cmd rm -rf priv/plts/*.plt"],
      # Unified development commands
      "dev.test": ["cmd scripts/dev.sh test"],
      "dev.test-all": ["cmd scripts/dev.sh test-all"],
      "dev.check": ["cmd scripts/dev.sh check"],
      "dev.setup": ["cmd scripts/dev.sh setup"],
      # Release commands
      "release.dev": ["run scripts/release.exs --env dev"],
      "release.prod": ["run scripts/release.exs --env prod"],
      "release.all": ["run scripts/release.exs --env prod --all"],
      "release.clean": ["run scripts/release.exs --clean"],
      "release.tag": ["run scripts/release.exs --tag"],
      # AI development tools
      "usage_rules.update": ["usage_rules.sync"]
    ]
  end

  defp description do
    """
    Multi-surface application runtime for Elixir. One TEA module renders to
    terminal, browser (LiveView), SSH, and MCP (agents). 30+ widgets, flexbox +
    CSS grid, AI agent runtime, distributed swarm with CRDTs, time-travel
    debugging, session recording, sandboxed REPL, and agentic commerce.
    """
  end

  defp package do
    [
      name: "raxol",
      files:
        ~w(lib priv/themes .formatter.exs mix.exs README* LICENSE* CHANGELOG.md),
      exclude_patterns: [~r/\.so$/, ~r/\.o$/, ~r/\.dylib$/],
      maintainers: ["DROO AMOR"],
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/DROOdotFOO/raxol",
        "Documentation" => "https://hexdocs.pm/raxol",
        "Changelog" =>
          "https://github.com/DROOdotFOO/raxol/blob/master/CHANGELOG.md"
      },
      description: description(),
      source_url: @source_url,
      homepage_url: "https://raxol.io",
      build_tools: ["mix", "make"]
    ]
  end

  defp docs do
    [
      main: "readme",
      logo: "assets/logo.svg",
      extras: [
        {"README.md", [title: "Overview"]},
        {"CHANGELOG.md", [title: "Changelog"]},
        {"LICENSE.md", [title: "License"]},
        {"ROADMAP.md", [title: "Roadmap"]},
        {".github/CONTRIBUTING.md", [title: "Contributing"]},
        {"docs/getting-started/QUICKSTART.md", [title: "Quickstart"]},
        {"docs/getting-started/COMPONENT_GALLERY.md", [title: "Component Gallery"]},
        {"docs/getting-started/CORE_CONCEPTS.md", [title: "Core Concepts"]},
        {"docs/getting-started/MIGRATION_FROM_DIY.md",
         [title: "Migration Guide"]},
        {"docs/core/BUFFER_API.md", [title: "Buffer API"]},
        {"docs/core/ARCHITECTURE.md", [title: "Architecture"]},
        {"docs/cookbook/README.md", [title: "Cookbook", filename: "cookbook"]},
        {"docs/cookbook/BUILDING_APPS.md", [title: "Building Apps"]},
        {"docs/cookbook/SSH_DEPLOYMENT.md", [title: "SSH Deployment"]},
        {"docs/cookbook/LIVEVIEW_INTEGRATION.md",
         [title: "LiveView Integration"]},
        {"docs/cookbook/THEMING.md", [title: "Theming"]},
        {"docs/cookbook/PERFORMANCE_OPTIMIZATION.md", [title: "Performance"]},
        {"docs/bench/README.md", [title: "Benchmarks", filename: "benchmarks"]},
        {"docs/features/README.md", [title: "Features", filename: "features"]},
        {"docs/features/FILESYSTEM.md", [title: "Virtual Filesystem"]},
        {"docs/features/CURSOR_EFFECTS.md", [title: "Cursor Effects"]},
        {"docs/features/AGENT_FRAMEWORK.md", [title: "Agent Framework"]},
        {"docs/features/SENSOR_FUSION.md", [title: "Sensor Fusion"]},
        {"docs/features/DISTRIBUTED_SWARM.md", [title: "Distributed Swarm"]},
        {"docs/features/ADAPTIVE_UI.md", [title: "Adaptive UI"]},
        {"docs/features/RECORDING_REPLAY.md", [title: "Recording & Replay"]},
        {"docs/features/REPL.md", [title: "REPL"]},
        {"docs/features/TIME_TRAVEL_DEBUGGING.md",
         [title: "Time-Travel Debugging"]},
        {"docs/WHY_OTP.md", [title: "Why OTP"]},
        {"examples/core/README.md",
         [title: "Core Examples", filename: "core-examples"]}
      ],
      groups_for_extras: [
        "Getting Started": ~w(
          README.md
          docs/getting-started/QUICKSTART.md
          docs/getting-started/CORE_CONCEPTS.md
          docs/getting-started/COMPONENT_GALLERY.md
          docs/getting-started/MIGRATION_FROM_DIY.md
        ),
        Architecture: ~w(
          docs/core/ARCHITECTURE.md
          docs/core/BUFFER_API.md
          docs/bench/README.md
        ),
        Cookbook: ~w(
          docs/cookbook/README.md
          docs/cookbook/BUILDING_APPS.md
          docs/cookbook/SSH_DEPLOYMENT.md
          docs/cookbook/THEMING.md
          docs/cookbook/LIVEVIEW_INTEGRATION.md
          docs/cookbook/PERFORMANCE_OPTIMIZATION.md
        ),
        Features: ~w(
          docs/features/README.md
          docs/features/FILESYSTEM.md
          docs/features/CURSOR_EFFECTS.md
          docs/features/AGENT_FRAMEWORK.md
          docs/features/SENSOR_FUSION.md
          docs/features/DISTRIBUTED_SWARM.md
          docs/features/ADAPTIVE_UI.md
          docs/features/RECORDING_REPLAY.md
          docs/features/REPL.md
          docs/features/TIME_TRAVEL_DEBUGGING.md
          docs/WHY_OTP.md
        ),
        "Project Info": ~w(
          CHANGELOG.md
          ROADMAP.md
          .github/CONTRIBUTING.md
          LICENSE.md
          examples/core/README.md
        )
      ],
      groups_for_modules: [
        Core: [
          Raxol,
          Raxol.Application,
          Raxol.Component,
          Raxol.Minimal
        ],
        "Core Runtime": [
          ~r/^Raxol\.Core\..*/
        ],
        "Terminal Emulation": [
          ~r/^Raxol\.Terminal\..*/
        ],
        "UI Components": [
          ~r/^Raxol\.UI\..*/
        ],
        "AI Agents": [
          ~r/^Raxol\.Agent.*/
        ],
        "Distributed Swarm": [
          ~r/^Raxol\.Swarm\..*/
        ],
        "Sensor Fusion": [
          ~r/^Raxol\.Sensor\..*/
        ],
        "Adaptive UI": [
          ~r/^Raxol\.Adaptive\..*/
        ],
        "Debugging & Recording": [
          ~r/^Raxol\.Debug\..*/,
          ~r/^Raxol\.Recording\..*/
        ],
        REPL: [
          ~r/^Raxol\.REPL\..*/
        ],
        SSH: [
          ~r/^Raxol\.SSH\..*/
        ],
        Playground: [
          ~r/^Raxol\.Playground\..*/
        ],
        Plugins: [
          ~r/^Raxol\.Plugin.*/
        ],
        Performance: [
          ~r/^Raxol\.Performance\..*/
        ],
        Security: [
          ~r/^Raxol\.Security\..*/
        ],
        "LiveView & Web": [
          ~r/^Raxol\.LiveView\..*/,
          ~r/^RaxolWeb\..*/
        ]
      ],
      source_url: "https://github.com/DROOdotFOO/raxol",
      source_ref: "v#{@version}",
      formatters: ["html"],
      api_reference: true,
      nest_modules_by_prefix: [
        Raxol.Core,
        Raxol.Terminal,
        Raxol.UI,
        Raxol.Agent,
        Raxol.Swarm,
        Raxol.Sensor,
        Raxol.Adaptive,
        Raxol.Debug,
        Raxol.Recording,
        Raxol.REPL,
        Raxol.SSH,
        Raxol.Playground,
        Raxol.Security,
        Raxol.Performance,
        Raxol.LiveView
      ]
    ]
  end
end
