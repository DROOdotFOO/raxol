defmodule Raxol.Core do
  @moduledoc """
  Raxol Core - The main entry point and coordination layer for the Raxol framework.

  This module provides a unified API for:
  - Application lifecycle management
  - Runtime initialization and configuration
  - Core system coordination
  - Plugin management
  - Event system access
  - Performance monitoring
  - Configuration management

  ## Quick Start

  ```elixir
  # Start a simple application
  {:ok, pid} = Raxol.Core.start_application(MyApp)

  # Start with custom options
  {:ok, pid} = Raxol.Core.start_application(MyApp, [
    title: "My App",
    fps: 30,
    debug: true,
    plugins: [:accessibility, :performance]
  ])

  # Stop the application
  Raxol.Core.stop_application(pid)
  ```

  ## Architecture

  Raxol.Core coordinates several subsystems:
  - **Runtime**: Application lifecycle and state management
  - **Events**: Event dispatching and subscription system
  - **Plugins**: Plugin discovery, loading, and lifecycle management
  - **Renderer**: UI rendering and layout management
  - **Terminal**: Terminal interaction and input handling
  - **Performance**: Metrics collection and optimization
  """

  alias Raxol.Core.Runtime.{
    Lifecycle,
    Supervisor
  }

  alias Raxol.Core.{
    Accessibility,
    ColorSystem,
    Metrics,
    Performance,
    UserPreferences
  }

  @type app_module :: module()
  @type app_options :: keyword()
  @type runtime_state :: map()
  @type plugin_id :: atom() | String.t()
  @type metric_name :: String.t()
  @type metric_value :: number()
  @type metric_tags :: [{atom(), any()}]

  @doc """
  Creates a new Core instance with default configuration.
  """
  @spec new() :: %{plugins: %{}, config: %{}, state: %{}}
  def new do
    %{
      plugins: %{},
      config: %{},
      state: %{}
    }
  end

  # ============================================================================
  # Application Lifecycle Management
  # ============================================================================

  @doc """
  Starts a Raxol application with the given module and options.

  This is the primary entry point for starting Raxol applications. It handles
  the complete initialization process including runtime setup, plugin loading,
  and application startup.

  ## Parameters

  * `app_module` - The module implementing `Raxol.Core.Runtime.Application` behaviour
  * `options` - Configuration options for the application

  ## Options

  * `:title` - Application title (default: derived from module name)
  * `:fps` - Target frames per second (default: 60)
  * `:debug` - Enable debug mode (default: false)
  * `:width` - Terminal width (default: auto-detected)
  * `:height` - Terminal height (default: auto-detected)
  * `:plugins` - List of plugins to load (default: [])
  * `:theme` - Theme configuration (default: :default)
  * `:accessibility` - Accessibility options (default: enabled)
  * `:performance` - Performance monitoring options (default: enabled)

  ## Returns

  * `{:ok, pid}` - Application started successfully
  * `{:error, reason}` - Failed to start application

  ## Example

  ```elixir
  defmodule MyApp do
    use Raxol.Core.Runtime.Application

    def init(_opts), do: %{count: 0}
    def update(:increment, model), do: {%{model | count: model.count + 1}, []}
    def view(model), do: view(do: text("Count: \#{model.count}"))
  end

  {:ok, pid} = Raxol.Core.start_application(MyApp, [
    title: "Counter App",
    fps: 30,
    plugins: [:accessibility]
  ])
  ```
  """
  @spec start_application(app_module(), app_options()) ::
          {:ok, pid()} | {:error, term()}
  def start_application(app_module, options \\ []) when is_atom(app_module) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Starting application: #{inspect(app_module)}"
    )

    case validate_application_module(app_module) do
      :ok ->
        :ok = initialize_core_systems(options)
        start_runtime(app_module, options)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a running Raxol application.

  ## Parameters

  * `pid_or_name` - PID or registered name of the application

  ## Returns

  * `:ok` - Application stopped successfully
  * `{:error, reason}` - Failed to stop application

  ## Example

  ```elixir
  Raxol.Core.stop_application(app_pid)
  ```
  """
  @spec stop_application(pid() | atom()) :: :ok
  def stop_application(pid_or_name) do
    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Stopping application: #{inspect(pid_or_name)}"
    )

    Lifecycle.stop(pid_or_name)
  end

  @doc """
  Gets the current status of a Raxol application.

  ## Parameters

  * `pid_or_name` - PID or registered name of the application

  ## Returns

  * `{:ok, status}` - Application status information
  * `{:error, reason}` - Failed to get status

  ## Example

  ```elixir
  {:ok, status} = Raxol.Core.get_application_status(app_pid)
  # Returns: {:ok, %{state: :running, uptime: 1234, model: %{...}}}
  ```
  """
  @spec get_application_status(pid() | atom()) ::
          {:ok, map()} | {:error, term()}
  def get_application_status(pid_or_name) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           GenServer.call(pid_or_name, :get_status, 5000)
         end) do
      {:ok, {:ok, status}} -> {:ok, status}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, _} -> {:error, :not_found}
    end
  end

  # ============================================================================
  # Plugin Management
  # ============================================================================

  @doc """
  Loads a plugin into the current application.

  ## Parameters

  * `plugin_id` - Plugin identifier (module name or string)
  * `options` - Plugin-specific options

  ## Returns

  * `{:ok, plugin_info}` - Plugin loaded successfully
  * `{:error, reason}` - Failed to load plugin

  ## Example

  ```elixir
  {:ok, plugin_info} = Raxol.Core.load_plugin(:accessibility, [enabled: true])
  ```
  """
  @spec load_plugin(plugin_id(), keyword()) :: :ok | {:error, atom()}
  def load_plugin(plugin_id, _options \\ []) do
    case Raxol.Core.Runtime.Plugins.PluginManager.load_plugin(plugin_id) do
      :ok ->
        Raxol.Core.Runtime.Log.info(
          "[#{__MODULE__}] Plugin loaded: #{inspect(plugin_id)}"
        )

        :ok

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[#{__MODULE__}] Failed to load plugin #{inspect(plugin_id)}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Unloads a plugin from the current application.

  ## Parameters

  * `plugin_id` - Plugin identifier

  ## Returns

  * `:ok` - Plugin unloaded successfully
  * `{:error, reason}` - Failed to unload plugin

  ## Example

  ```elixir
  :ok = Raxol.Core.unload_plugin(:accessibility)
  ```
  """
  @spec unload_plugin(plugin_id()) :: :ok
  def unload_plugin(plugin_id) do
    :ok = Raxol.Core.Runtime.Plugins.PluginManager.unload_plugin(plugin_id)

    Raxol.Core.Runtime.Log.info(
      "[#{__MODULE__}] Plugin unloaded: #{inspect(plugin_id)}"
    )

    :ok
  end

  @doc """
  Lists all loaded plugins.

  ## Returns

  * `{:ok, plugins}` - List of loaded plugins
  * `{:error, reason}` - Failed to get plugin list

  ## Example

  ```elixir
  {:ok, plugins} = Raxol.Core.list_plugins()
  # Returns: {:ok, [:accessibility, :performance, :themes]}
  ```
  """
  @spec list_plugins() :: [map()]
  def list_plugins do
    Raxol.Core.Runtime.Plugins.PluginManager.list_plugins()
  end

  # ============================================================================
  # Performance and Metrics
  # ============================================================================

  @doc """
  Records a performance metric.

  ## Parameters

  * `name` - Metric name
  * `value` - Metric value
  * `tags` - Optional tags for the metric

  ## Example

  ```elixir
  Raxol.Core.record_metric("render.time", 15.5, [component: "button"])
  ```
  """
  @spec record_metric(metric_name(), metric_value(), metric_tags()) :: :ok
  def record_metric(name, value, tags \\ []) do
    Metrics.record(name, value, tags)
  end

  @doc """
  Gets performance statistics.

  ## Returns

  * `{:ok, stats}` - Performance statistics
  * `{:error, reason}` - Failed to get statistics

  ## Example

  ```elixir
  {:ok, stats} = Raxol.Core.get_performance_stats()
  ```
  """
  @spec get_performance_stats() :: {:ok, Performance.stats()}
  def get_performance_stats do
    Performance.get_stats()
  end

  # ============================================================================
  # Configuration and Preferences
  # ============================================================================

  @doc """
  Gets a user preference value.

  ## Parameters

  * `key` - Preference key
  * `default` - Default value if not set

  ## Returns

  The preference value or default

  ## Example

  ```elixir
  theme = Raxol.Core.get_preference(:theme, :default)
  ```
  """
  @spec get_preference(atom(), any()) :: any()
  def get_preference(key, default \\ nil) do
    UserPreferences.get(key, default)
  end

  @doc """
  Sets a user preference value.

  ## Parameters

  * `key` - Preference key
  * `value` - Preference value

  ## Returns

  * `:ok` - Preference set successfully
  * `{:error, reason}` - Failed to set preference

  ## Example

  ```elixir
  :ok = Raxol.Core.set_preference(:theme, :dark)
  ```
  """
  @spec set_preference(atom(), any()) :: :ok | {:error, term()}
  def set_preference(key, value) do
    UserPreferences.set(key, value)
  end

  @doc """
  Gets the current theme configuration.

  ## Returns

  * `{:ok, theme}` - Current theme configuration
  * `{:error, reason}` - Failed to get theme

  ## Example

  ```elixir
  {:ok, theme} = Raxol.Core.get_theme()
  ```
  """
  @spec get_theme() :: {:ok, map()} | {:error, term()}
  def get_theme do
    ColorSystem.get_current_theme()
  end

  @doc """
  Sets the current theme.

  ## Parameters

  * `theme_id` - Theme identifier

  ## Returns

  * `:ok` - Theme set successfully
  * `{:error, reason}` - Failed to set theme

  ## Example

  ```elixir
  :ok = Raxol.Core.set_theme(:dark)
  ```
  """
  @spec set_theme(atom()) :: :ok | {:error, :theme_not_found}
  def set_theme(theme_id) do
    ColorSystem.set_theme(theme_id)
  end

  # ============================================================================
  # Accessibility
  # ============================================================================

  @doc """
  Checks if accessibility features are enabled.

  ## Returns

  * `true` - Accessibility is enabled
  * `false` - Accessibility is disabled

  ## Example

  ```elixir
  case Raxol.Core.accessibility_enabled?() do
    true -> # Enable screen reader support
    false -> # Use default behavior
  end
  ```
  """
  @spec accessibility_enabled?() :: boolean()
  def accessibility_enabled? do
    Accessibility.enabled?()
  end

  @doc """
  Enables or disables accessibility features.

  ## Parameters

  * `enabled` - Whether to enable accessibility

  ## Returns

  * `:ok` - Accessibility setting updated
  * `{:error, reason}` - Failed to update setting

  ## Example

  ```elixir
  :ok = Raxol.Core.set_accessibility_enabled(true)
  ```
  """
  @spec set_accessibility_enabled(boolean()) :: :ok
  def set_accessibility_enabled(enabled) do
    Accessibility.set_enabled(enabled)
  end

  # ============================================================================
  # System Information
  # ============================================================================

  @doc """
  Gets system information about the current Raxol environment.

  ## Returns

  * `{:ok, info}` - System information
  * `{:error, reason}` - Failed to get system info

  ## Example

  ```elixir
  {:ok, info} = Raxol.Core.get_system_info()
  # Returns: {:ok, %{version: "1.0.0", terminal: "xterm", colors: 256}}
  ```
  """
  @spec get_system_info() ::
          {:ok,
           %{
             accessibility: boolean(),
             colors: 0 | 256,
             performance: Performance.stats(),
             terminal: binary(),
             version: binary()
           }}
  def get_system_info do
    info = %{
      version: get_version(),
      terminal: get_terminal_info(),
      colors: get_color_support(),
      accessibility: accessibility_enabled?(),
      performance: get_performance_info()
    }

    {:ok, info}
  end

  @doc """
  Gets the Raxol framework version.

  ## Returns

  The version string

  ## Example

  ```elixir
  version = Raxol.Core.get_version()
  # Returns: "1.0.0"
  ```
  """
  @spec get_version() :: String.t()
  def get_version do
    case :application.get_key(:raxol, :vsn) do
      {:ok, version} -> version
      _ -> "unknown"
    end
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  @spec validate_application_module(module()) ::
          :ok | {:error, :invalid_application_module}
  defp validate_application_module(app_module) do
    case {function_exported?(app_module, :init, 1),
          function_exported?(app_module, :update, 2),
          function_exported?(app_module, :view, 1)} do
      {true, true, true} ->
        :ok

      _ ->
        {:error, :invalid_application_module}
    end
  end

  defp initialize_core_systems(options) do
    _ = Performance.init(Keyword.get(options, :performance, []))
    _ = Metrics.init(Keyword.get(options, :metrics, []))
    _ = Raxol.Core.Accessibility.init(Keyword.get(options, :accessibility, []))
    _ = ColorSystem.init(Keyword.get(options, :theme, :default))

    :ok
  end

  defp start_runtime(app_module, options) do
    case Supervisor.start_link(%{
           app_module: app_module,
           options: options
         }) do
      {:ok, supervisor_pid} ->
        {:ok, supervisor_pid}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "[#{__MODULE__}] Failed to start runtime: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  defp get_terminal_info do
    case System.get_env("TERM") do
      nil -> "unknown"
      term -> term
    end
  end

  defp get_color_support do
    case IO.ANSI.enabled?() do
      true -> 256
      false -> 0
    end
  end

  defp get_performance_info do
    {:ok, stats} = Performance.get_stats()
    stats
  end
end
