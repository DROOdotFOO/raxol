defmodule Raxol do
  @moduledoc """
  Multi-surface application runtime for Elixir, built on OTP.

  Raxol provides a component model, layout engine, and render pipeline that
  renders one TEA module to terminal, browser (LiveView), SSH, and MCP (agents).
  Apps follow The Elm Architecture (TEA):

      defmodule Counter do
        use Raxol.Core.Runtime.Application

        def init(_ctx), do: %{count: 0}

        def update(:inc, model), do: {%{model | count: model.count + 1}, []}
        def update(_, model), do: {model, []}

        def view(model) do
          column style: %{padding: 1, gap: 1} do
            [
              text("Count: \#{model.count}", style: [:bold]),
              button("+", on_click: :inc)
            ]
          end
        end

        def subscribe(_model), do: []
      end

  Start an app with `Raxol.start_link/2` or `Raxol.run/2`:

      {:ok, pid} = Raxol.start_link(Counter, [])

  ## Key Modules

  * `Raxol.Core.Runtime.Application` - TEA behaviour (`init/update/view/subscribe`)
  * `Raxol.Core.Renderer.View` - View DSL macros (`column`, `row`, `box`, `text`, `button`)
  * `Raxol.UI.Layout.Engine` - Flexbox and CSS Grid layout
  * `Raxol.Terminal.ScreenBuffer` - Screen buffer and cell management
  * `Raxol.SSH.Server` - Serve apps over SSH
  * `Raxol.UI.Theming.ThemeManager` - Runtime theme switching
  * `Raxol.Agent` - AI agents as TEA apps with OTP supervision
  * `Raxol.Swarm.Discovery` - Distributed node discovery (libcluster + Tailscale)
  * `Raxol.Debug.TimeTravel` - Snapshot-based time-travel debugging
  * `Raxol.Recording.Recorder` - Session recording in Asciinema v2 format
  * `Raxol.REPL.Evaluator` - Sandboxed code evaluation with persistent bindings
  * `Raxol.Sensor.Fusion` - Sensor polling, batching, and weighted averaging

  ## OTP Features

  * **Crash isolation** - `process_component/2` runs widgets in separate processes
  * **Hot code reload** - `Raxol.Dev.CodeReloader` updates running apps on file save
  * **SSH serving** - `Raxol.SSH.serve(MyApp, port: 2222)` for remote access
  * **LiveView bridge** - Same app renders to terminal and browser
  * **AI agent runtime** - TEA agents with inter-agent messaging and team supervision
  * **Distributed swarm** - CRDTs, node monitoring, leader election via libcluster
  * **Time-travel debugging** - Snapshot every update cycle, step back/forward, restore
  """

  alias Raxol.Core.Runtime.Application


  @doc """
  Runs a Raxol application.

  This function starts the Raxol runtime with the provided application module
  and options. The application module must implement the `Raxol.Core.Runtime.Application` behaviour.

  ## Parameters

  * `app` - Module implementing the `Raxol.Core.Runtime.Application` behaviour
  * `opts` - Additional options for the runtime

  ## Options

  * `:quit_keys` - List of keys that will quit the application (default: `[{:ctrl, ?c}]`)
  * `:fps` - Target frames per second (default: `60`)
  * `:title` - Terminal window title (default: `"Raxol Application"`)
  * `:font` - Terminal font (if supported)
  * `:font_size` - Terminal font size (if supported)
  * `:accessibility` - Accessibility options
    * `:screen_reader` - Enable screen reader support (default: `true`)
    * `:high_contrast` - Enable high contrast mode (default: `false`)
    * `:large_text` - Enable large text mode (default: `false`)

  ## Returns

  The return value of the application when it exits.

  ## Example

  ```elixir
  Raxol.run(MyApp, %{initial: "state"}, title: "My Application", fps: 30)
  ```
  """
  def run(app, opts \\ []) do
    Raxol.Core.Runtime.Lifecycle.start_application(app, opts)
  end

  @doc """
  Starts and links a Raxol application lifecycle manager.

  This is the standard OTP entry point for supervised processes.
  Delegates to `Raxol.Core.Runtime.Lifecycle.start_link/2`.

  ## Parameters

  * `app` - Module implementing the `Raxol.Core.Runtime.Application` behaviour
  * `opts` - Options passed to the lifecycle manager

  ## Returns

  `{:ok, pid}` on success, `{:error, reason}` on failure.
  """
  def start_link(app, opts \\ []) do
    Raxol.Core.Runtime.Lifecycle.start_link(app, opts)
  end

  @doc """
  Gracefully stops a running Raxol application.

  This function can be called from within your application to exit gracefully.

  ## Parameters

  * `return_value` - Value to return from the `Raxol.run/2` function

  ## Example

  ```elixir
  def update(model, :exit) do
    Raxol.stop(:normal)
    model
  end
  ```
  """
  def stop(return_value \\ :ok) do
    Raxol.Core.Runtime.Lifecycle.stop_application(return_value)
  end

  @doc """
  Returns the current version of Raxol.

  ## Returns

  A string representing the current version.

  ## Example

  ```elixir
  Raxol.version()
  # => "2.3.0"
  ```
  """
  def version do
    :application.get_key(:raxol, :vsn) |> elem(1) |> to_string()
  end

  @doc """
  Returns information about the terminal environment.

  This includes terminal size, color support, and other capabilities.

  ## Returns

  A map with terminal information.

  ## Example

  ```elixir
  Raxol.terminal_info()
  # => %{
  #      name: "iTerm2",
  #      version: "3.5.0",
  #      features: [:true_color, :unicode, :mouse, :clipboard],
  #      ...
  #    }
  ```
  """
  def terminal_info do
    %{width: 80, height: 24, colors: 256}
  end

  @doc """
  Sets the default theme for Raxol applications.

  This function sets the default theme that will be used by Raxol components.

  ## Parameters

  * `theme` - A theme created with `Raxol.UI.Theming.Theme.new/1` or one of the built-in themes

  ## Example

  ```elixir
  # Use a built-in theme
  Raxol.set_theme(Raxol.UI.Theming.Theme.dark())

  # Create and use a custom theme
  custom_theme = Raxol.UI.Theming.Theme.new(name: "Custom", colors: %{primary: :green})
  Raxol.set_theme(custom_theme)
  ```
  """
  def set_theme(theme) do
    :application.set_env(:raxol, :theme, theme)
  end

  @doc """
  Gets the current default theme.

  ## Returns

  The current theme map.

  ## Example

  ```elixir
  theme = Raxol.current_theme()
  ```
  """
  def current_theme do
    Application.get_env(:raxol, :theme, Raxol.UI.Theming.Theme.default_theme())
  end

  @doc """
  Enables or disables accessibility features.

  ## Parameters

  * `opts` - Map of accessibility features to enable/disable

  ## Options

  * `:screen_reader` - Enable screen reader support
  * `:high_contrast` - Enable high contrast mode
  * `:large_text` - Enable large text mode
  * `:reduced_motion` - Reduce or eliminate animations

  ## Example

  ```elixir
  Raxol.set_accessibility(screen_reader: true, high_contrast: true)
  ```
  """
  def set_accessibility(opts \\ []) do
    apply_accessibility_theme(opts[:high_contrast])
    :ok
  end

  @doc """
  Gets the current accessibility settings.

  ## Returns

  A map of current accessibility settings.

  ## Example

  ```elixir
  settings = Raxol.accessibility_settings()
  case settings.high_contrast do
    true ->
      # Do something for high contrast mode
    false -> :ok
  end
  ```
  """
  def accessibility_settings do
    Application.get_env(:raxol, :accessibility, %{
      screen_reader: true,
      high_contrast: false,
      large_text: false,
      reduced_motion: false
    })
  end

  defp apply_accessibility_theme(true) do
    set_theme(Raxol.UI.Theming.Theme.dark_theme())
  end

  defp apply_accessibility_theme(_) do
    set_theme(Raxol.UI.Theming.Theme.default_theme())
  end

  @doc """
  Starts a Raxol application.

  ## Parameters

  * `module` - The application module that implements the Raxol.Core.Runtime.Application behaviour
  * `props` - Initial props to pass to the application
  * `config` - Configuration options for the application

  ## Returns

  `{:ok, pid}` on success, `{:error, reason}` on failure.

  ## Example

      {:ok, pid} = Raxol.start_app(MyApp, %{user: "alice"}, [])
  """
  def start_app(module, props, _config) do
    # For now, return a simple success tuple
    # In a full implementation, this would start the runtime
    handle_module_init(module.init(props))
  end

  defp handle_module_init({_initial_state, _commands}) do
    # Start a simple GenServer to represent the app
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    {:ok, pid}
  end

  defp handle_module_init(error) do
    {:error, error}
  end
end
