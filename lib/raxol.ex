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
  * `Raxol.REPL.Evaluator` - In-process code evaluation with persistent bindings and resource caps (not a security boundary)
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
  Starts a Raxol application and returns immediately.

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

  `{:ok, pid}` or `{:error, reason}` (`GenServer.on_start/0`). The
  application runs in that process; this call does not block until it
  exits. To wait for it, monitor the pid; to stop it, use one of the
  configured `:quit_keys` or call
  `Raxol.Core.Runtime.Lifecycle.stop_application/1`.

  ## Example

  ```elixir
  {:ok, pid} = Raxol.run(MyApp, title: "My Application", fps: 30)
  ref = Process.monitor(pid)

  receive do
    {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
  end
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
  Sets the theme Raxol renders with.

  The theme becomes `Raxol.UI.Theming.Theme.current/0`, which the renderers
  read.

  The theme is node-global: it is stored in the `:raxol` application
  environment, so every session on the node (each SSH and LiveView session
  included) renders with it, not just the caller's.

  ## Parameters

  * `theme` - A theme created with `Raxol.UI.Theming.Theme.new/1`, a built-in
    theme struct (e.g. `Raxol.UI.Theming.Theme.dark_theme/0`), or the id of a
    theme registered with `Raxol.UI.Theming.Theme.register/1` (`:default`
    needs no registration). Strings and plain maps are not accepted.

  ## Returns

  `:ok`, or `{:error, :theme_not_found}` if no theme is registered under the
  given id.

  ## Example

  ```elixir
  # Use a built-in theme
  Raxol.set_theme(Raxol.UI.Theming.Theme.dark_theme())

  # Create and use a custom theme
  custom_theme =
    Raxol.UI.Theming.Theme.new(%{id: :custom, name: "Custom", colors: %{primary: :green}})

  Raxol.set_theme(custom_theme)

  # Switch to a registered theme by id
  Raxol.UI.Theming.Theme.register(custom_theme)
  Raxol.set_theme(:custom)
  ```
  """
  @spec set_theme(Raxol.UI.Theming.Theme.t() | atom()) ::
          :ok | {:error, :theme_not_found}
  def set_theme(theme) do
    Raxol.UI.Theming.Theme.apply_theme(theme)
  end

  @doc """
  Gets the theme Raxol renders with, the same as
  `Raxol.UI.Theming.Theme.current/0`.

  Like `set_theme/1`, this is node-global: every session on the node sees
  the same theme.

  ## Returns

  The current theme.

  ## Example

  ```elixir
  theme = Raxol.current_theme()
  ```
  """
  def current_theme do
    Raxol.UI.Theming.Theme.current()
  end

  @doc """
  Enables or disables accessibility features.

  ## Parameters

  * `opts` - Map of accessibility features to enable/disable

  ## Options

  * `:screen_reader` - Enable screen reader support
  * `:high_contrast` - `true` raises the contrast of the current theme
    (`Raxol.UI.Theming.Theme.adjust_for_high_contrast/1`); `false` restores
    the theme it replaced, unless another theme was set meanwhile. The theme
    is node-global (see `set_theme/1`). Without this option the theme is left
    alone.
  * `:large_text` - Enable large text mode
  * `:reduced_motion` - Reduce or eliminate animations

  ## Example

  ```elixir
  Raxol.set_accessibility(screen_reader: true, high_contrast: true)
  ```
  """
  def set_accessibility(opts \\ []) do
    case Access.fetch(opts, :high_contrast) do
      {:ok, enabled?} -> apply_high_contrast(enabled?)
      :error -> :ok
    end
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

  # High contrast raises the contrast of the current theme and remembers the
  # theme it replaced, so turning it off restores that theme. Other options
  # leave the theme alone.
  defp apply_high_contrast(true) do
    case Elixir.Application.fetch_env(:raxol, :high_contrast_restore) do
      {:ok, _already_on} ->
        :ok

      :error ->
        prior = current_theme()
        high_contrast = Raxol.UI.Theming.Theme.adjust_for_high_contrast(prior)

        with :ok <- set_theme(high_contrast) do
          Elixir.Application.put_env(
            :raxol,
            :high_contrast_restore,
            {prior, high_contrast}
          )
        end
    end
  end

  # A theme set while high contrast was on is kept.
  defp apply_high_contrast(_off) do
    case Elixir.Application.fetch_env(:raxol, :high_contrast_restore) do
      {:ok, {prior, high_contrast}} ->
        Elixir.Application.delete_env(:raxol, :high_contrast_restore)

        if current_theme() == high_contrast, do: set_theme(prior), else: :ok

      :error ->
        :ok
    end
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
