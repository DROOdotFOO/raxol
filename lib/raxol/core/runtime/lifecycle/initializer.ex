defmodule Raxol.Core.Runtime.Lifecycle.Initializer do
  @moduledoc """
  Component startup sequence for the Raxol application lifecycle.
  Extracted from Lifecycle to reduce file size.
  """

  alias Raxol.Core.CompilerState
  alias Raxol.Core.Runtime.Events.Dispatcher
  alias Raxol.Core.Runtime.Log
  alias Raxol.Core.Runtime.Plugins.PluginManager, as: Manager

  @doc """
  Initializes all components in order: registry table, plugin manager, app model,
  dispatcher, terminal driver, rendering engine.
  Returns `{:ok, registry_table, pm_pid, model, dispatcher_pid, driver_pid, engine_pid}`
  or `{:error, reason, cleanup_fun}`.
  """
  def initialize_all(app_module, options) do
    {:module, _} = Code.ensure_loaded(app_module)

    with {:ok, registry_table, pm_pid, model} <- init_core(app_module, options),
         {:ok, dispatcher_pid, driver_pid, engine_pid} <-
           init_runtime(app_module, model, options, pm_pid, registry_table) do
      GenServer.cast(dispatcher_pid, {:set_rendering_engine, engine_pid})

      {:ok, registry_table, pm_pid, model, dispatcher_pid, driver_pid,
       engine_pid}
    end
  end

  defp init_core(app_module, options) do
    environment = Keyword.get(options, :environment, :terminal)

    with {:ok, registry_table} <- initialize_registry_table(app_module),
         {:ok, pm_pid} <- start_plugin_manager(options, environment),
         {:ok, model} <-
           initialize_app_model(app_module, get_initial_model_args(options)) do
      {:ok, registry_table, pm_pid, model}
    end
  end

  defp init_runtime(app_module, model, options, pm_pid, registry_table) do
    environment = Keyword.get(options, :environment, :terminal)

    with {:ok, dispatcher_pid} <-
           start_dispatcher(app_module, model, options, pm_pid, registry_table),
         {:ok, driver_pid} <-
           maybe_start_driver(dispatcher_pid, environment, options),
         {:ok, engine_pid} <-
           start_rendering_engine(app_module, dispatcher_pid, options) do
      {:ok, dispatcher_pid, driver_pid, engine_pid}
    end
  end

  @doc "Starts the CodeReloader in dev mode; returns nil otherwise."
  def maybe_start_code_reloader(lifecycle_pid) do
    if Code.ensure_loaded?(Mix) and Mix.env() == :dev do
      case Raxol.Dev.CodeReloader.start_link(lifecycle_pid) do
        {:ok, pid} -> pid
        _ -> nil
      end
    else
      nil
    end
  rescue
    e ->
      Log.debug(
        "[Initializer] CodeReloader unavailable: #{Exception.message(e)}"
      )

      nil
  end

  @doc "Detects actual terminal size, falling back to options then 80x24."
  def detect_terminal_size(options) do
    default_w =
      Keyword.get(options, :width, Raxol.Constants.default_terminal_width())

    default_h =
      Keyword.get(options, :height, Raxol.Constants.default_terminal_height())

    case {:io.columns(), :io.rows()} do
      {{:ok, cols}, {:ok, rows}} when cols > 0 and rows > 0 ->
        {cols, rows}

      _ ->
        case Raxol.Terminal.Driver.Stty.size() do
          {:ok, cols, rows} -> {cols, rows}
          :error -> {default_w, default_h}
        end
    end
  end

  # --- private ---

  defp initialize_registry_table(app_module) do
    registry_table_name =
      Module.concat(CommandRegistryTable, Atom.to_string(app_module))

    case CompilerState.ensure_table(registry_table_name, [
           :set,
           :protected,
           :named_table,
           {:read_concurrency, true}
         ]) do
      :ok ->
        {:ok, registry_table_name}

      {:error, _reason} ->
        {:error, :registry_table_creation_failed,
         fn -> CompilerState.safe_delete_table(registry_table_name) end}
    end
  end

  defp start_plugin_manager(_options, :agent), do: {:ok, nil}
  defp start_plugin_manager(_options, :liveview), do: {:ok, nil}

  defp start_plugin_manager(options, _environment) do
    plugin_manager_opts = Keyword.get(options, :plugin_manager_opts, [])

    case Manager.start_link(plugin_manager_opts) do
      {:ok, pm_pid} ->
        Log.info_with_context(
          "[Lifecycle.Initializer] PluginManager started with PID: #{inspect(pm_pid)}"
        )

        {:ok, pm_pid}

      # PluginLifecycle is registered as a VM singleton (name: __MODULE__) and
      # all client calls go through the registered name, so concurrent Raxol
      # Lifecycles share one plugin manager. PluginRegistry is ETS-backed and
      # StateManager namespaces by plugin_id, so this is safe -- adopt the
      # existing pid rather than failing init.
      {:error, {:already_started, pm_pid}} ->
        {:ok, pm_pid}

      {:error, reason} ->
        {:error, {:plugin_manager_start_failed, reason}, fn -> :ok end}
    end
  end

  defp get_initial_model_args(options) do
    %{
      width:
        Keyword.get(options, :width, Raxol.Constants.default_terminal_width()),
      height:
        Keyword.get(options, :height, Raxol.Constants.default_terminal_height()),
      options: options
    }
  end

  defp initialize_app_model(app_module, initial_model_args) do
    if function_exported?(app_module, :init, 1) do
      call_app_init(app_module, initial_model_args)
    else
      Log.info(
        "[Lifecycle.Initializer] #{inspect(app_module)}.init/1 not exported. Using empty model."
      )

      {:ok, %{}}
    end
  end

  defp call_app_init(app_module, initial_model_args) do
    case app_module.init(initial_model_args) do
      {:ok, model} ->
        {:ok, model}

      {_, model} ->
        Log.warning_with_context(
          "[Lifecycle.Initializer] #{inspect(app_module)}.init returned a tuple, using model: #{inspect(model)}",
          %{}
        )

        {:ok, model}

      model when is_map(model) ->
        Log.info(
          "[Lifecycle.Initializer] #{inspect(app_module)}.init returned a map directly: #{inspect(model)}"
        )

        {:ok, model}

      _ ->
        Log.warning_with_context(
          "[Lifecycle.Initializer] #{inspect(app_module)}.init did not return {:ok, model} or a map. Using empty model.",
          %{}
        )

        {:ok, %{}}
    end
  end

  defp start_dispatcher(
         app_module,
         initialized_model,
         options,
         pm_pid,
         registry_table
       ) do
    dispatcher_initial_state = %{
      app_module: app_module,
      model: initialized_model,
      width:
        Keyword.get(options, :width, Raxol.Constants.default_terminal_width()),
      height:
        Keyword.get(options, :height, Raxol.Constants.default_terminal_height()),
      debug_mode:
        Keyword.get(options, :debug_mode, Keyword.get(options, :debug, false)),
      plugin_manager: pm_pid,
      command_registry_table: registry_table,
      time_travel: Keyword.get(options, :time_travel_pid),
      cycle_profiler: Keyword.get(options, :cycle_profiler_pid),
      command_interceptor: Keyword.get(options, :command_interceptor),
      # Harness keystone: a :session_id opt makes the Dispatcher publish typed
      # events to Raxol.Core.Runtime.EmitBus at both model-fold sites.
      session_id: Keyword.get(options, :session_id)
    }

    environment = Keyword.get(options, :environment, :terminal)

    # :ssh is multi-instance (one Lifecycle per channel). Without [name: nil]
    # the second concurrent SSH session collides on the registered Dispatcher
    # name. Callers always reach the Dispatcher via state.dispatcher_pid, so
    # dropping the registered name is safe.
    dispatcher_opts =
      if environment in [:agent, :liveview, :ssh],
        do: [name: nil],
        else: []

    case Dispatcher.start_link(
           self(),
           dispatcher_initial_state,
           dispatcher_opts
         ) do
      {:ok, dispatcher_pid} ->
        {:ok, dispatcher_pid}

      {:error, reason} ->
        {:error, {:dispatcher_start_failed, reason}, pm_cleanup_fn(pm_pid)}
    end
  end

  defp pm_cleanup_fn(nil), do: fn -> :ok end
  defp pm_cleanup_fn(pm_pid), do: fn -> Manager.stop(pm_pid) end

  defp maybe_start_driver(_dispatcher_pid, :liveview, _options), do: {:ok, nil}
  defp maybe_start_driver(_dispatcher_pid, :ssh, _options), do: {:ok, nil}
  defp maybe_start_driver(_dispatcher_pid, :agent, _options), do: {:ok, nil}

  # T2d: the inline driver profile (no alt-screen, no termbox ownership).
  # A sibling of the default branch below, not a replacement -- see
  # Raxol.Terminal.InlineDriver's moduledoc for the full option contract.
  # The pass-through keys below are the constructor's test/embedding seams
  # (output device, stty injection, probe control); everything else keeps
  # the driver's own defaults (real tty detection, real stty, real probe).
  @inline_driver_passthrough_opts [
    :device,
    :subscriber,
    :stty,
    :tty?,
    :stty_enabled?,
    :install_reader?,
    :rows,
    :probe?,
    :capabilities,
    :probe_opts,
    :probe_env
  ]

  defp maybe_start_driver(dispatcher_pid, :inline, options) do
    driver_opts =
      [dispatcher_pid: dispatcher_pid] ++
        Keyword.take(options, @inline_driver_passthrough_opts)

    case Raxol.Terminal.InlineDriver.start_link(driver_opts) do
      {:ok, driver_pid} ->
        Log.info_with_context(
          "[Lifecycle.Initializer] Inline Driver started with PID: #{inspect(driver_pid)}"
        )

        {:ok, driver_pid}

      {:error, reason} ->
        Log.warning_with_context(
          "[Lifecycle.Initializer] Inline Driver failed to start: #{inspect(reason)}. Continuing without driver.",
          %{}
        )

        {:ok, nil}
    end
  end

  defp maybe_start_driver(dispatcher_pid, _environment, options) do
    driver_opts =
      [
        dispatcher_pid: dispatcher_pid,
        mouse: Keyword.get(options, :mouse, true)
      ] ++ Keyword.get(options, :driver_start_opts, [])

    # Test seam only: production callers never pass :driver_module, so this
    # always resolves to Raxol.Terminal.Driver. Lets lifecycle shutdown-order
    # tests inject a recording double without touching packages/raxol_terminal
    # or standing up a real termbox2/tty session.
    driver_module = Keyword.get(options, :driver_module, Raxol.Terminal.Driver)

    case driver_module.start_link(driver_opts) do
      {:ok, driver_pid} ->
        Log.info_with_context(
          "[Lifecycle.Initializer] Terminal Driver started with PID: #{inspect(driver_pid)}"
        )

        {:ok, driver_pid}

      {:error, reason} ->
        Log.warning_with_context(
          "[Lifecycle.Initializer] Terminal Driver failed to start: #{inspect(reason)}. Continuing without driver.",
          %{}
        )

        {:ok, nil}
    end
  end

  defp start_rendering_engine(app_module, dispatcher_pid, options) do
    {actual_w, actual_h} = detect_terminal_size(options)

    engine_opts =
      [
        app_module: app_module,
        dispatcher_pid: dispatcher_pid,
        width: actual_w,
        height: actual_h,
        environment: Keyword.get(options, :environment, :terminal)
      ]
      |> maybe_add_opt(:liveview_topic, Keyword.get(options, :liveview_topic))
      |> maybe_add_opt(:io_writer, Keyword.get(options, :io_writer))
      |> maybe_add_opt(
        :cycle_profiler,
        Keyword.get(options, :cycle_profiler_pid)
      )
      |> Kernel.++(Keyword.get(options, :engine_start_opts, []))

    # Test seam only, mirrors :driver_module above -- production callers
    # never pass :engine_module.
    engine_module =
      Keyword.get(
        options,
        :engine_module,
        Raxol.Core.Runtime.Rendering.Engine
      )

    case engine_module.start_link(engine_opts) do
      {:ok, engine_pid} ->
        Log.info_with_context(
          "[Lifecycle.Initializer] Rendering Engine started with PID: #{inspect(engine_pid)}"
        )

        {:ok, engine_pid}

      {:error, reason} ->
        Log.warning_with_context(
          "[Lifecycle.Initializer] Rendering Engine failed to start: #{inspect(reason)}. Continuing without rendering engine.",
          %{}
        )

        {:ok, nil}
    end
  end

  defp maybe_add_opt(opts, _key, nil), do: opts
  defp maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)
end
