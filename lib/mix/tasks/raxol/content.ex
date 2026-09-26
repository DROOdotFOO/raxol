defmodule Mix.Raxol.Content do
  @moduledoc """
  Boilerplate content generators for `mix raxol.new`.

  All functions return strings of generated file content.
  """

  @doc "Generates mix.exs content."
  def mix_exs(%{
        app: app,
        module: module,
        sup: sup?,
        ssh: ssh?,
        liveview: liveview?,
        version: version
      }) do
    extra_deps =
      []
      |> maybe_add(ssh?, ~s|{:ssh_subsystem_fwup, "~> 0.6", optional: true}|)
      |> maybe_add(liveview?, ~s|{:phoenix_live_view, "~> 1.0"}|)
      |> maybe_add(liveview?, ~s|{:phoenix, "~> 1.7"}|)

    all_deps = [~s|{:raxol, "~> #{version}"}| | extra_deps]
    deps_lines = Enum.map_join(all_deps, ",\n", &("      " <> &1))

    # A --sup app is started by its application callback, so `mix run` starts
    # it. Without `mod:` the supervision tree in `Application` never runs.
    application_lines =
      ["extra_applications: [:logger]"]
      |> maybe_add(sup?, "mod: {#{module}.Application, []}")
      |> Enum.map_join(",\n", &("      " <> &1))

    """
    defmodule #{module}.MixProject do
      use Mix.Project

      def project do
        [
          app: :#{app},
          version: "0.1.0",
          elixir: "~> 1.17",
          start_permanent: Mix.env() == :prod,
          deps: deps()
        ]
      end

      def application do
        [
    #{application_lines}
        ]
      end

      defp deps do
        [
    #{deps_lines}
        ]
      end
    end
    """
  end

  @doc """
  Generates config/config.exs content.

  A --sup app's `Application` reads the TUI's options from
  `config :<app>, :raxol` and, with --ssh, the SSH server's from
  `config :<app>, :ssh`, so those sections are live config for it.
  """
  def config_exs(%{app: app, sup: sup?, ssh: ssh?, liveview: liveview?}) do
    sections =
      [base_config(app)]
      |> maybe_add(sup? and not ssh?, tui_config(app))
      |> maybe_add(sup? and ssh?, ssh_server_config(app))
      |> maybe_add(ssh? and not sup?, ssh_config_hint(app))
      |> maybe_add(liveview?, liveview_config_hint(app))

    Enum.join(sections, "\n")
  end

  @doc "Generates .formatter.exs content."
  def formatter do
    """
    [
      inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
    ]
    """
  end

  @doc "Generates .gitignore content."
  def gitignore do
    """
    /_build/
    /deps/
    /doc/
    *.beam
    .fetch
    erl_crash.dump
    """
  end

  @doc "Generates .mise.toml content."
  def mise_toml do
    elixir_vsn = System.version()
    otp_vsn = :erlang.system_info(:otp_release) |> to_string()

    """
    [tools]
    elixir = "#{elixir_vsn}"
    erlang = "#{otp_vsn}"
    """
  end

  @doc "Generates README.md content."
  def readme(%{module: module, template: template} = bindings) do
    run_cmd = Mix.Raxol.AppTemplates.run_command(bindings)

    """
    # #{module}

    A terminal UI application built with [Raxol](https://hexdocs.pm/raxol).

    ## Getting Started

    ```bash
    mix deps.get
    #{run_cmd}
    ```

    ## About

    This app was generated with `mix raxol.new` using the `#{template}` template.
    It follows The Elm Architecture (TEA) with four callbacks:

    - `init/1` - Set up initial state
    - `update/2` - Handle messages and events
    - `view/1` - Render the UI from state
    - `subscribe/1` - Set up recurring events

    ## Learn More

    - [Raxol Documentation](https://hexdocs.pm/raxol)
    - [The Elm Architecture](https://guide.elm-lang.org/architecture/)
    """
  end

  @doc "Generates GitHub Actions CI workflow YAML."
  def ci_workflow(_bindings) do
    """
    name: CI

    on:
      push:
        branches: [main, master]
      pull_request:
        branches: [main, master]

    jobs:
      test:
        runs-on: ubuntu-latest

        steps:
          - uses: actions/checkout@v4

          - name: Set up Elixir
            uses: erlef/setup-beam@v1
            with:
              elixir-version: "1.17"
              otp-version: "27"

          - name: Restore dependencies cache
            uses: actions/cache@v4
            with:
              path: deps
              key: ${{ runner.os }}-mix-${{ hashFiles('mix.lock') }}
              restore-keys: ${{ runner.os }}-mix-

          - name: Install dependencies
            run: mix deps.get

          - name: Check formatting
            run: mix format --check-formatted

          - name: Compile with warnings as errors
            run: mix compile --warnings-as-errors

          - name: Run tests
            run: mix test
            env:
              MIX_ENV: test
    """
  end

  @doc "Generates the main module when --sup is used."
  def app_module_sup(%{module: module, app: app}) do
    """
    defmodule #{module} do
      @moduledoc \"\"\"
      #{module} entrypoint. See `#{module}.Application` for the supervision tree.
      \"\"\"

      @doc "Starts the application, which starts the supervision tree."
      def start do
        Application.ensure_all_started(:#{app})
      end

      defdelegate version, to: Raxol
    end
    """
  end

  @doc """
  Generates Application module for --sup.

  Its children are what `mix run --no-halt` runs: the TUI, or with --ssh the
  SSH server that runs the TUI per connection. The TUI child is `:transient`
  and `significant`, so quitting it is not a crash to restart: it shuts the
  supervisor down, and `stop/1` then stops the VM that `--no-halt` would
  otherwise keep up.
  """
  def application_module(%{module: module, app: app, ssh: true}) do
    """
    defmodule #{module}.Application do
      @moduledoc false

      use Application

      @impl true
      def start(_type, _args) do
        # Serves #{module}.App over SSH, one instance per connection, with the
        # options under `config :#{app}, :ssh`.
        children = [
          {Raxol.SSH.Server,
           [app_module: #{module}.App] ++ Application.get_env(:#{app}, :ssh, [])}
        ]

        opts = [strategy: :one_for_one, name: #{module}.Supervisor]
        Supervisor.start_link(children, opts)
      end
    end
    """
  end

  def application_module(%{module: module, app: app}) do
    """
    defmodule #{module}.Application do
      @moduledoc false

      use Application

      @impl true
      def start(_type, _args) do
        # Runs #{module}.App in this terminal, with the options under
        # `config :#{app}, :raxol`. Quitting it ends it normally, which is not
        # a crash to restart: being significant, it takes the supervisor down.
        children = [
          %{
            id: #{module}.App,
            start: {Raxol, :start_link, [#{module}.App, Application.get_env(:#{app}, :raxol, [])]},
            restart: :transient,
            significant: true
          }
        ]

        opts = [
          strategy: :one_for_one,
          auto_shutdown: :any_significant,
          name: #{module}.Supervisor
        ]

        Supervisor.start_link(children, opts)
      end

      # The app has quit. `mix run --no-halt` would keep the VM running without it.
      @impl true
      def stop(_state), do: System.stop()
    end
    """
  end

  @doc "Generates TEA app module (lib/app/app.ex with --sup)."
  def tea_module(%{template: template} = bindings) do
    module_name = "#{bindings.module}.App"
    do_tea_module(template, %{bindings | module: module_name})
  end

  @doc """
  Generates standalone TEA app module (lib/app.ex without --sup).

  The module starts itself through `start/0`; nothing runs at the top level,
  which `mix compile` would execute.
  """
  def tea_module_standalone(%{template: template} = bindings) do
    do_tea_module(template, bindings)
  end

  @doc "Generates SSH server module."
  def ssh_module(%{module: module}) do
    app_mod =
      if String.ends_with?(module, ".App"), do: module, else: "#{module}.App"

    """
    defmodule #{module}.SSH do
      @moduledoc \"\"\"
      SSH server for #{module}.

      Start with:

          #{module}.SSH.start()

      Then connect:

          ssh localhost -p 2222
      \"\"\"

      def start(opts \\\\ []) do
        port = Keyword.get(opts, :port, 2222)
        Raxol.SSH.Server.serve(#{app_mod}, port: port)
      end
    end
    """
  end

  @doc "Generates Phoenix LiveView bridge module."
  def liveview_module(%{module: module}) do
    app_mod =
      if String.ends_with?(module, ".App"), do: module, else: "#{module}.App"

    """
    defmodule #{module}.Live do
      @moduledoc \"\"\"
      Phoenix LiveView bridge for #{module}.

      Add to your Phoenix router:

          live "/app", #{module}.Live
      \"\"\"

      use Phoenix.LiveView

      @impl true
      def mount(params, session, socket) do
        Raxol.LiveView.TEALive.mount(params, session, socket,
          app_module: #{app_mod}
        )
      end

      @impl true
      def handle_info(msg, socket) do
        Raxol.LiveView.TEALive.handle_info(msg, socket)
      end

      @impl true
      def handle_event(event, params, socket) do
        Raxol.LiveView.TEALive.handle_event(event, params, socket)
      end

      @impl true
      def render(assigns) do
        Raxol.LiveView.TEALive.render(assigns)
      end
    end
    """
  end

  @doc "Generates test/test_helper.exs content."
  def test_helper do
    """
    ExUnit.start()
    """
  end

  @doc "Generates the app test file content based on template."
  def app_test(%{module: module, template: template, sup: sup?}) do
    test_module = if sup?, do: "#{module}.App", else: module

    case template do
      "blank" ->
        """
        defmodule #{module}Test do
          use ExUnit.Case

          test "init returns initial state" do
            assert #{test_module}.init(%{}) == %{}
          end

          test "update ignores unknown messages" do
            model = %{}
            assert {%{}, []} = #{test_module}.update(:unknown, model)
          end
        end
        """

      "counter" ->
        """
        defmodule #{module}Test do
          use ExUnit.Case

          test "init returns initial state" do
            assert #{test_module}.init(%{}) == %{count: 0}
          end

          test "update handles increment" do
            model = %{count: 0}
            assert {%{count: 1}, []} = #{test_module}.update(:increment, model)
          end

          test "update handles decrement" do
            model = %{count: 5}
            assert {%{count: 4}, []} = #{test_module}.update(:decrement, model)
          end

          test "update ignores unknown messages" do
            model = %{count: 0}
            assert {%{count: 0}, []} = #{test_module}.update(:unknown, model)
          end
        end
        """

      "todo" ->
        """
        defmodule #{module}Test do
          use ExUnit.Case

          test "init returns empty todo list" do
            model = #{test_module}.init(%{})
            assert model.todos == []
            assert model.mode == :normal
          end

          test "adding a todo" do
            model = #{test_module}.init(%{})
            {model, []} = #{test_module}.update(:start_input, model)
            assert model.mode == :input
            {model, []} = #{test_module}.update({:input_char, "B"}, model)
            {model, []} = #{test_module}.update({:input_char, "u"}, model)
            {model, []} = #{test_module}.update({:input_char, "y"}, model)
            {model, []} = #{test_module}.update(:input_submit, model)
            assert length(model.todos) == 1
            assert hd(model.todos).text == "Buy"
            assert model.mode == :normal
          end

          test "toggling a todo" do
            model = %{#{test_module}.init(%{}) |
              todos: [%#{test_module}.Todo{id: 1, text: "Test", done: false}],
              selected: 0
            }
            {model, []} = #{test_module}.update(:toggle_done, model)
            assert hd(model.todos).done == true
          end

          test "deleting a todo" do
            model = %{#{test_module}.init(%{}) |
              todos: [%#{test_module}.Todo{id: 1, text: "Test"}],
              selected: 0
            }
            {model, []} = #{test_module}.update(:delete_todo, model)
            assert model.todos == []
          end
        end
        """

      "dashboard" ->
        """
        defmodule #{module}Test do
          use ExUnit.Case

          test "init returns dashboard state" do
            model = #{test_module}.init(%{})
            assert model.active_panel == 0
            assert length(model.panels) == 3
          end

          test "switching panels" do
            model = #{test_module}.init(%{})
            {model, []} = #{test_module}.update(:next_panel, model)
            assert model.active_panel == 1
            {model, []} = #{test_module}.update(:next_panel, model)
            assert model.active_panel == 2
            {model, []} = #{test_module}.update(:next_panel, model)
            assert model.active_panel == 0
          end

          test "tick updates stats" do
            model = #{test_module}.init(%{})
            {model, []} = #{test_module}.update(:tick, model)
            assert model.stats.uptime == 1
            assert model.tick == 1
          end
        end
        """
    end
  end

  # --- Private ---

  defp do_tea_module(template, bindings) do
    Mix.Raxol.AppTemplates.render(template, bindings)
  end

  defp base_config(app) do
    """
    import Config

    # Raxol application configuration
    #
    # config :#{app}, :raxol,
    #   fps: 60,                           # Target frames per second
    #   title: "#{Macro.camelize(app)}",    # Window title
    #   quit_keys: [{:ctrl, ?c}]            # Keys that quit the app

    # Accessibility options
    # config :#{app}, :accessibility,
    #   screen_reader: true,
    #   high_contrast: false,
    #   large_text: false,
    #   reduced_motion: false

    # Theme configuration
    # config :raxol, :theme, Raxol.UI.Theming.Theme.dark_theme()
    """
  end

  defp tui_config(app) do
    """
    # `mix test` starts the application, and with it the TUI. Run it headless
    # there, so it leaves the terminal to the test run.
    if config_env() == :test do
      config :#{app}, :raxol, environment: :agent
    end
    """
  end

  defp ssh_server_config(app) do
    """
    # The SSH server the application starts (see Raxol.SSH.serve/2). Anonymous
    # access binds loopback only and has to state its limits.
    config :#{app}, :ssh,
      port: 2222,
      allow_anonymous: true,
      max_connections: 10,
      max_per_ip: 2,
      idle_timeout: :timer.minutes(5),
      max_session_duration: :timer.hours(1)

    # `mix test` starts the application too. Port 0 takes any free port, so
    # tests run while the app is serving on 2222.
    if config_env() == :test do
      config :#{app}, :ssh, port: 0
    end
    """
  end

  defp ssh_config_hint(app) do
    """
    # SSH server configuration
    # config :#{app}, :ssh,
    #   port: 2222,
    #   host_keys_dir: "/tmp/#{app}_ssh_keys"
    """
  end

  defp liveview_config_hint(app) do
    """
    # LiveView configuration
    # config :#{app}, :liveview,
    #   pubsub: #{Macro.camelize(app)}.PubSub
    """
  end

  # credo:disable-for-next-line Credo.Check.Refactor.AppendSingleItem
  defp maybe_add(list, true, item), do: list ++ [item]
  defp maybe_add(list, false, _item), do: list
end
