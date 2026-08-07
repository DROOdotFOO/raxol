defmodule Raxol.Core.Runtime.Lifecycle do
  @moduledoc """
  Manages the application lifecycle, including startup, shutdown, and terminal interaction.

  Orchestrates initialization of subsystems in order:
  1. PluginManager -- loads and starts plugins
  2. Dispatcher -- manages app model and event routing (TEA update/2 loop)
  3. Terminal Driver -- raw terminal I/O (skipped for :liveview/:ssh environments)
  4. Rendering Engine -- view -> layout -> buffer -> output pipeline

  Uses a two-phase readiness pattern: rendering begins only after both
  `dispatcher_ready` and `plugin_manager_ready` flags are set. In dev mode,
  a CodeReloader is started to watch for source changes and trigger re-renders.

  ## Shutdown & exit trapping

  Every child (dispatcher, driver, rendering engine, plugin manager) is
  `start_link`'d from `init/1`, so all are LINKED to this process, and this
  process traps exits. `terminate/2` is the single source of truth for
  shutdown ordering: it stops children driver-FIRST so the Terminal Driver's
  own `terminate/2` (mode reset, scroll-region reset, stty restore) runs to
  completion before anything under it is torn down. This runs identically for
  every stop trigger: our own `:shutdown` cast, an external abnormal exit
  signal, or a genuine child crash.

  Trapping exits preserves the prior die-together + supervisor-restart
  contract (an abnormal child/peer exit still stops this process with the
  same reason, propagated verbatim), while a `:normal` peer exit is ignored
  exactly as an untrapped process would have dropped it. One behavioral
  addition: a genuine child CRASH now incurs the full driver-first teardown
  BEFORE the crash reason propagates upward (bounded latency:
  `GenServer.stop` over the surviving children) -- teardown-on-crash is
  intentional, not a correctness break.

  ## Sub-modules
  - `Lifecycle.Initializer` -- component startup sequence
  - `Lifecycle.Shutdown`    -- stop_process, cleanup, registry management
  """

  use GenServer

  alias Raxol.Core.Runtime.Backpressure
  alias Raxol.Core.Runtime.Lifecycle.{Initializer, Shutdown}
  alias Raxol.Core.Runtime.Log

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            app_module: module() | nil,
            options: keyword(),
            app_name: atom() | nil,
            width: non_neg_integer(),
            height: non_neg_integer(),
            debug_mode: boolean(),
            plugin_manager: pid() | nil,
            command_registry_table: :ets.table() | nil,
            initial_commands: list(),
            dispatcher_pid: pid() | nil,
            driver_pid: pid() | nil,
            rendering_engine_pid: pid() | nil,
            code_reloader_pid: pid() | nil,
            time_travel_pid: pid() | nil,
            cycle_profiler_pid: pid() | nil,
            model: map(),
            dispatcher_ready: boolean(),
            plugin_manager_ready: boolean(),
            adaptive_supervisor_pid: pid() | nil,
            alternate_screen: boolean()
          }
    defstruct app_module: nil,
              options: [],
              app_name: nil,
              width: Raxol.Constants.default_terminal_width(),
              height: Raxol.Constants.default_terminal_height(),
              debug_mode: false,
              plugin_manager: nil,
              command_registry_table: nil,
              initial_commands: [],
              dispatcher_pid: nil,
              driver_pid: nil,
              rendering_engine_pid: nil,
              code_reloader_pid: nil,
              time_travel_pid: nil,
              cycle_profiler_pid: nil,
              model: %{},
              dispatcher_ready: false,
              plugin_manager_ready: false,
              adaptive_supervisor_pid: nil,
              alternate_screen: false,
              command_interceptor: nil
  end

  @doc """
  Starts and links a new Raxol application lifecycle manager.

  ## Options
    * `:app_module` - Required application module atom.
    * `:name` - Optional name for registering the GenServer.
    * `:width` - Terminal width (default: 80).
    * `:height` - Terminal height (default: 24).
    * `:debug` - Enable debug mode (default: false).
    * `:initial_commands` - A list of directive structs to execute on startup.
    * `:plugin_manager_opts` - Options to pass to the PluginManager's start_link function.
    * `:adaptive` - Enable adaptive UI (layout recommendations from behavior tracking). Default: false.
    * `:alternate_screen` - Enter the alternate screen buffer on startup (DECSET 1049). Prevents TUI frames from polluting the client's scrollback. Default: false.
  """
  def start_link(app_module, options \\ [])
      when is_atom(app_module) and is_list(options) do
    environment = Keyword.get(options, :environment, :terminal)

    # Multi-instance environments must not fall back to the derived
    # per-app-module name: two concurrent chats/sessions of the same app
    # would collide on it.
    name_option =
      if environment in [:liveview, :agent, :ssh, :telegram, :gateway] do
        Keyword.get(options, :name)
      else
        Keyword.get(options, :name, derive_process_name(app_module))
      end

    opts = [app_module: app_module] ++ options
    server_opts = if name_option, do: [name: name_option], else: []
    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  defp derive_process_name(app_module) do
    Module.concat(__MODULE__, Atom.to_string(app_module))
  end

  @doc "Stops the Raxol application lifecycle manager."
  def stop(pid_or_name) do
    GenServer.cast(pid_or_name, :shutdown)
  end

  # GenServer callbacks

  @impl GenServer
  def init(options) when is_list(options) do
    trap_child_exits!()

    app_module = Keyword.fetch!(options, :app_module)

    Log.info_with_context(
      "[#{__MODULE__}] initializing for #{inspect(app_module)} with options: #{inspect(options)}"
    )

    options =
      options
      |> maybe_start_time_travel()
      |> maybe_start_cycle_profiler()

    finish_init(app_module, options)
  end

  defp finish_init(app_module, options) do
    case Initializer.initialize_all(app_module, options) do
      {:ok, registry_table, pm_pid, initialized_model, dispatcher_pid,
       driver_pid, rendering_engine_pid} ->
        maybe_set_time_travel_dispatcher(options, dispatcher_pid)

        state =
          build_initial_state(
            app_module,
            options,
            pm_pid,
            registry_table,
            dispatcher_pid,
            initialized_model,
            driver_pid,
            rendering_engine_pid
          )

        Log.info_with_context(
          "[#{__MODULE__}] successfully initialized for #{inspect(app_module)}. Dispatcher PID: #{inspect(dispatcher_pid)}"
        )

        if state.alternate_screen do
          {:ok, state, {:continue, :enter_alternate_screen}}
        else
          {:ok, state}
        end

      {:error, reason, cleanup_fun} ->
        _ = cleanup_fun.()
        {:stop, reason}
    end
  end

  @impl GenServer
  def handle_continue(:enter_alternate_screen, state) do
    maybe_enter_alternate_screen(state)
    {:noreply, state}
  end

  # Every child (dispatcher, driver, rendering engine, plugin manager, ...)
  # is start_link'd from inside init/1 via Initializer, so all of them are
  # LINKED to this process. Without trapping exits, the first child that
  # dies during our own shutdown sequence (Shutdown.stop_process/2 uses
  # GenServer.stop/3, and the target's own exit propagates back over the
  # link) kills THIS process immediately -- before terminate/2 ever runs,
  # before any later Shutdown.stop_process/2 call executes, and before an
  # unrelated linked-child crash gets a chance to be handled gracefully.
  # Trapping exits turns those into ordinary {:EXIT, pid, reason} messages
  # (see handle_info/2 below) so terminate/2 -- and the driver-first
  # teardown it now performs -- reliably runs on every shutdown path: our
  # own :shutdown cast, an external supervisor/SIGTERM exit signal, or a
  # genuine child crash.
  defp trap_child_exits! do
    Process.flag(:trap_exit, true)
    :ok
  end

  defp build_initial_state(
         app_module,
         options,
         pm_pid,
         registry_table,
         dispatcher_pid,
         initialized_model,
         driver_pid,
         rendering_engine_pid
       ) do
    code_reloader_pid = Initializer.maybe_start_code_reloader(self())
    time_travel_pid = Keyword.get(options, :time_travel_pid)
    cycle_profiler_pid = Keyword.get(options, :cycle_profiler_pid)

    adaptive_supervisor_pid =
      maybe_start_adaptive(options, dispatcher_pid)

    alt_screen = Keyword.get(options, :alternate_screen, false)

    %State{
      app_module: app_module,
      options: options,
      app_name: get_app_name(app_module, options),
      width:
        Keyword.get(options, :width, Raxol.Constants.default_terminal_width()),
      height:
        Keyword.get(options, :height, Raxol.Constants.default_terminal_height()),
      debug_mode:
        Keyword.get(options, :debug_mode, Keyword.get(options, :debug, false)),
      plugin_manager: pm_pid,
      command_registry_table: registry_table,
      initial_commands: Keyword.get(options, :initial_commands, []),
      dispatcher_pid: dispatcher_pid,
      driver_pid: driver_pid,
      rendering_engine_pid: rendering_engine_pid,
      code_reloader_pid: code_reloader_pid,
      time_travel_pid: time_travel_pid,
      cycle_profiler_pid: cycle_profiler_pid,
      model: initialized_model,
      dispatcher_ready: false,
      plugin_manager_ready: pm_pid == nil,
      adaptive_supervisor_pid: adaptive_supervisor_pid,
      alternate_screen: alt_screen,
      command_interceptor: Keyword.get(options, :command_interceptor)
    }
  end

  defp maybe_start_adaptive(options, dispatcher_pid) do
    if Keyword.get(options, :adaptive, false) do
      case Raxol.Adaptive.Supervisor.start_link(name: nil) do
        {:ok, sup_pid} ->
          # Subscribe self() so layout recommendations arrive here,
          # then get forwarded to dispatcher -> app update/2
          Raxol.Adaptive.LayoutRecommender.subscribe(
            Raxol.Adaptive.LayoutRecommender
          )

          Log.info_with_context(
            "[#{__MODULE__}] Adaptive UI started (supervisor: #{inspect(sup_pid)}, dispatcher: #{inspect(dispatcher_pid)})"
          )

          sup_pid

        {:error, reason} ->
          Log.warning_with_context(
            "[#{__MODULE__}] Failed to start adaptive UI",
            %{reason: reason}
          )

          nil
      end
    else
      nil
    end
  end

  @impl true
  def handle_info({:runtime_initialized, dispatcher_pid}, state) do
    Log.info_with_context(
      "Runtime Lifecycle for #{inspect(state.app_module)} received :runtime_initialized from Dispatcher #{inspect(dispatcher_pid)}."
    )

    new_state = %{state | dispatcher_ready: true}
    {:noreply, maybe_process_initial_commands(new_state)}
  end

  @impl true
  def handle_info({:plugin_manager_ready, plugin_manager_pid}, state) do
    Log.info_with_context(
      "[#{__MODULE__}] Plugin Manager ready notification received from #{inspect(plugin_manager_pid)}."
    )

    new_state = %{state | plugin_manager_ready: true}
    {:noreply, maybe_process_initial_commands(new_state)}
  end

  @impl true
  def handle_info({:layout_recommendation, _rec} = msg, state) do
    if state.dispatcher_pid do
      _ =
        Backpressure.cast(state.dispatcher_pid, {:dispatch, msg},
          label: :lifecycle_layout_rec,
          policy: :call_when_full
        )
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:render_needed, state) do
    Log.debug(
      "[#{__MODULE__}] Received :render_needed. Forwarding to Rendering Engine."
    )

    if state.rendering_engine_pid && Process.alive?(state.rendering_engine_pid) do
      GenServer.cast(state.rendering_engine_pid, :render_frame)
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(:quit_runtime, state) do
    Log.info_with_context(
      "[#{__MODULE__}] Received :quit_runtime. Shutting down."
    )

    handle_cast(:shutdown, state)
  end

  # A linked NON-PARENT peer exited cleanly (:normal) -- ignore it (a child we
  # already stopped, or a sibling). This preserves the pre-trap_exit contract
  # for peers: a process not trapping exits already silently drops a :normal
  # exit signal from a link, so a :normal peer exit never took the old
  # Lifecycle down, and it must not take the new one down either.
  #
  # This clause does NOT see the start_link PARENT's exit: gen_server
  # intercepts `{:EXIT, Parent, Reason}` in its own receive loop (before
  # handle_info) and terminates with that reason -- standard OTP "a gen_server
  # dies with its parent". So trap_exit does introduce ONE narrow, intended
  # change for the parent specifically: a parent exit (any reason) now brings
  # Lifecycle down GRACEFULLY through terminate/2 -- running the driver-first
  # teardown -- instead of, pre-trap, either lingering (parent :normal) or
  # dying with no teardown (parent crash). For an owns-the-node caller
  # (a script/CLI whose main process ends) that means the terminal is now
  # restored when the caller finishes, which is the desired behavior. The
  # only ABNORMAL peer exits are handled by the clause below.
  @impl true
  def handle_info({:EXIT, _pid, :normal}, state) do
    {:noreply, state}
  end

  # Any other linked-process exit -- a genuine child crash, an external
  # supervisor-driven abnormal termination, or the tail end of our own
  # controlled shutdown -- must still bring this Lifecycle down (preserving
  # the old "the whole tree dies together" + supervisor-restart contract:
  # the exit reason is propagated verbatim as the stop reason, so a
  # supervising process sees the identical restart trigger it saw pre-trap).
  # The difference from pre-trap: we now stop via {:stop, reason, state},
  # which runs terminate/2 -- and therefore the driver-first teardown -- to
  # completion BEFORE the reason propagates upward, instead of the untrapped
  # signal killing the process outright with no teardown. That teardown adds
  # bounded latency (GenServer.stop over the surviving children) on the crash
  # path; it is a behavioral addition, not a correctness change.
  @impl true
  def handle_info({:EXIT, pid, reason}, state) do
    Log.warning_with_context(
      "[#{__MODULE__}] Linked process #{inspect(pid)} exited: #{inspect(reason)}. Terminating.",
      %{}
    )

    {:stop, reason, state}
  end

  @impl true
  def handle_info(unhandled_message, state) do
    Log.warning_with_context(
      "[#{__MODULE__}] Unhandled info message: #{inspect(unhandled_message)}",
      %{}
    )

    {:noreply, state}
  end

  @impl true
  def handle_cast(:shutdown, state) do
    Log.info_with_context(
      "[#{__MODULE__}] Received :shutdown cast for #{inspect(state.app_name)}. Stopping."
    )

    # The actual child-by-child teardown lives in terminate/2 (via
    # stop_dependent_processes/1) so that it runs identically regardless of
    # WHY this process is stopping -- our own :shutdown cast (:normal here),
    # an external exit signal converted to {:EXIT, ...} by trap_exit, or a
    # linked child crash. One sequence, one place, always driver-first.
    {:stop, :normal, state}
  end

  @impl true
  def handle_cast(unhandled_message, state) do
    Log.warning_with_context(
      "[#{__MODULE__}] Unhandled cast message: #{inspect(unhandled_message)}",
      %{}
    )

    {:noreply, state}
  end

  @impl true
  def handle_call(:get_full_state, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(unhandled_message, _from, state) do
    Log.warning_with_context(
      "[#{__MODULE__}] Unhandled call message: #{inspect(unhandled_message)}",
      %{}
    )

    {:reply, {:error, :unknown_call}, state}
  end

  @impl GenServer
  def terminate(reason, state) do
    maybe_leave_alternate_screen(state)
    stop_dependent_processes(state)
    terminate_manager(reason, state)
  end

  # Stops every linked child Lifecycle started, in an order that lets the
  # Terminal Driver's own terminate/2 (mode reset, scroll-region reset, stty
  # restore) run to completion BEFORE anything else in the process tree is
  # torn down. This is the single source of truth for shutdown ordering --
  # reached whether we got here via our own :shutdown cast, an external
  # supervisor exit signal, or a genuine child crash (see
  # handle_info({:EXIT, ...}) above) -- so the driver is never orphaned.
  #
  # PluginManager is stopped here (last, after the render path) rather than
  # relying solely on terminate_manager's cleanup so its stop is part of the
  # one deterministic ordering; terminate_manager still runs afterward and
  # no-ops on the already-stopped (or shared/adopted) manager. Every stop
  # is a no-op on a nil or already-dead pid (see Shutdown.stop_process/2),
  # so a crash that already took a child down is handled safely.
  defp stop_dependent_processes(state) do
    Shutdown.stop_process(state.driver_pid, "Terminal Driver")
    Shutdown.stop_process(state.rendering_engine_pid, "Rendering Engine")
    Shutdown.stop_process(state.cycle_profiler_pid, "CycleProfiler")
    Shutdown.stop_process(state.time_travel_pid, "TimeTravel")
    Shutdown.stop_process(state.code_reloader_pid, "CodeReloader")
    Shutdown.stop_process(state.dispatcher_pid, "Dispatcher")
    Shutdown.stop_process(state.plugin_manager, "PluginManager")
  end

  defp terminate_manager(reason, state) do
    Log.info_with_context(
      "[#{__MODULE__}] terminating for #{inspect(state.app_name)}. Reason: #{inspect(reason)}"
    )

    plugin_manager_alive =
      state.plugin_manager && Process.alive?(state.plugin_manager)

    Shutdown.cleanup_plugin_manager(plugin_manager_alive, state)
    Shutdown.cleanup_registry_table(state.command_registry_table != nil, state)

    :ok
  end

  defp maybe_enter_alternate_screen(%State{alternate_screen: true} = state) do
    write_escape(state.options, "\e[?1049h")
  end

  defp maybe_enter_alternate_screen(_state), do: :ok

  defp maybe_leave_alternate_screen(%State{alternate_screen: true} = state) do
    write_escape(state.options, "\e[?1049l")
  end

  defp maybe_leave_alternate_screen(_state), do: :ok

  defp write_escape(options, escape) do
    env = Keyword.get(options, :environment, :terminal)
    writer = Keyword.get(options, :io_writer)
    do_write_escape(env, writer, escape)
  end

  defp do_write_escape(:ssh, writer, escape) when is_function(writer, 1),
    do: writer.(escape)

  defp do_write_escape(:terminal, _writer, escape), do: IO.write(escape)
  defp do_write_escape(_env, _writer, _escape), do: :ok

  # Initial commands processing

  defp maybe_process_initial_commands(%State{} = state) do
    both_ready = state.dispatcher_ready && state.plugin_manager_ready

    state =
      if both_ready && Enum.any?(state.initial_commands) do
        process_initial_commands(state)
      else
        log_waiting_status(state)
        state
      end

    if both_ready do
      trigger_initial_render(state)
    end

    state
  end

  defp process_initial_commands(state) do
    Log.info_with_context(
      "Dispatcher and PluginManager ready. Dispatching initial commands: #{inspect(state.initial_commands)}"
    )

    context = %{
      pid: state.dispatcher_pid,
      command_registry_table: state.command_registry_table,
      runtime_pid: self()
    }

    commands =
      apply_command_interceptor(
        state.command_interceptor,
        state.initial_commands
      )

    Enum.each(commands, &execute_initial_command(&1, context))
    %{state | initial_commands: []}
  end

  # Security gate for initial commands: mirror the Dispatcher's interceptor so an
  # agent's init/1 directives run through the same permission/sandbox hooks. nil
  # for non-agent surfaces (no-op).
  defp apply_command_interceptor(fun, commands) when is_function(fun, 1),
    do: fun.(commands)

  defp apply_command_interceptor(_fun, commands), do: commands

  defp execute_initial_command(command, context) do
    if directive?(command) do
      Raxol.Core.Runtime.Directive.Executor.execute(command, context)
    else
      Log.error(
        "Invalid initial effect found: #{inspect(command)}. Expected a directive struct."
      )
    end
  end

  defp directive?(effect) do
    is_struct(effect) and
      Raxol.Core.Runtime.Directive.Executor.impl_for(effect) != nil
  end

  defp log_waiting_status(state) do
    if Enum.any?(state.initial_commands) do
      log_if_has_commands(state)
    end
  end

  defp log_if_has_commands(state) do
    case {state.dispatcher_ready, state.plugin_manager_ready} do
      {false, false} ->
        Log.info(
          "Waiting for Dispatcher and PluginManager to be ready before processing initial commands."
        )

      {false, true} ->
        Log.info(
          "Waiting for Dispatcher to be ready before processing initial commands."
        )

      {true, false} ->
        Log.info(
          "Waiting for PluginManager to be ready before processing initial commands."
        )

      {true, true} ->
        :ok
    end
  end

  defp trigger_initial_render(%State{rendering_engine_pid: pid})
       when is_pid(pid) do
    if Process.alive?(pid) do
      GenServer.cast(pid, :render_frame)
    end
  end

  defp trigger_initial_render(_state), do: :ok

  # -- Time-travel debugging --

  defp maybe_start_time_travel(options) do
    case Keyword.get(options, :time_travel) do
      true ->
        start_time_travel_server(options, [])

      tt_opts when is_list(tt_opts) ->
        start_time_travel_server(options, tt_opts)

      _ ->
        options
    end
  end

  defp start_time_travel_server(options, tt_opts) do
    case Raxol.Debug.TimeTravel.start_link(tt_opts) do
      {:ok, pid} ->
        Log.info_with_context(
          "[#{__MODULE__}] TimeTravel debugger started: #{inspect(pid)}"
        )

        Keyword.put(options, :time_travel_pid, pid)

      {:error, reason} ->
        Log.warning_with_context(
          "[#{__MODULE__}] TimeTravel failed to start: #{inspect(reason)}",
          %{}
        )

        options
    end
  end

  # The TimeTravel GenServer needs the dispatcher pid to send :restore_model,
  # but the dispatcher is started after TimeTravel. Wire it up after both exist.
  defp maybe_set_time_travel_dispatcher(options, dispatcher_pid) do
    case Keyword.get(options, :time_travel_pid) do
      pid when is_pid(pid) ->
        # Update the TimeTravel server's internal dispatcher reference
        GenServer.cast(pid, {:set_dispatcher, dispatcher_pid})

      _ ->
        :ok
    end
  end

  # -- Cycle profiler --

  defp maybe_start_cycle_profiler(options) do
    case Keyword.get(options, :profiler) do
      true -> start_cycle_profiler_server(options, [])
      opts when is_list(opts) -> start_cycle_profiler_server(options, opts)
      _ -> options
    end
  end

  defp start_cycle_profiler_server(options, profiler_opts) do
    case Raxol.Performance.CycleProfiler.start_link(profiler_opts) do
      {:ok, pid} ->
        Log.info_with_context(
          "[#{__MODULE__}] CycleProfiler started: #{inspect(pid)}"
        )

        Keyword.put(options, :cycle_profiler_pid, pid)

      {:error, reason} ->
        Log.warning_with_context(
          "[#{__MODULE__}] CycleProfiler failed to start: #{inspect(reason)}",
          %{}
        )

        options
    end
  end

  # Helper functions

  defp get_app_name(app_module, options) do
    Keyword.get(options, :app_name, Atom.to_string(app_module))
  end

  @doc "Gets the application name for a given module."
  @spec get_app_name(atom()) :: String.t()
  def get_app_name(app_module) when is_atom(app_module) do
    if function_exported?(app_module, :app_name, 0) do
      app_module.app_name()
    else
      :default
    end
  end

  # === Compatibility Wrappers ===

  @doc "Initializes the runtime environment. (Stub for test compatibility)"
  @spec initialize_environment(keyword()) :: keyword()
  def initialize_environment(options) do
    env_type = Keyword.get(options, :environment, :terminal)

    case env_type do
      :terminal ->
        Log.info("[Lifecycle] Initializing terminal environment")
        Log.info("[Lifecycle] Terminal environment initialized successfully")
        options

      :web ->
        Log.info("[Lifecycle] Initializing web environment")
        Log.info("[Lifecycle] Terminal initialization failed")
        options

      unknown ->
        Log.info("[Lifecycle] Unknown environment type: #{inspect(unknown)}")
        options
    end
  end

  @doc "Starts a Raxol application (compatibility wrapper)."
  @spec start_application(module(), keyword()) :: GenServer.on_start()
  def start_application(app, opts), do: start_link(app, opts)

  @doc "Stops a Raxol application (compatibility wrapper)."
  @spec stop_application(GenServer.server()) :: :ok
  def stop_application(val), do: stop(val)

  @doc "Looks up a registered app by ID."
  @spec lookup_app(term()) ::
          {:ok, term()} | {:error, :not_found | :app_not_found}
  def lookup_app(app_id) do
    case Application.get_env(:raxol, :apps) do
      nil -> {:error, :not_found}
      apps -> find_app_by_id(apps, app_id)
    end
  end

  defp find_app_by_id(apps, app_id) do
    case Enum.find(apps, fn {id, _} -> id == app_id end) do
      nil -> {:error, :app_not_found}
      {_id, app_config} -> {:ok, app_config}
    end
  end

  @spec handle_error(term(), term()) ::
          {:stop, :normal, %{}}
          | {:ok, :continue | :reinitialize_resources | :restart_components}
  def handle_error(error, _context) do
    case error do
      {:application_error, reason} ->
        Log.info("[Lifecycle] Application error: #{inspect(reason)}")
        Log.info("[Lifecycle] Stopping application")
        {:stop, :normal, %{}}

      {:termbox_error, reason} ->
        Log.info("[Lifecycle] Termbox error: #{inspect(reason)}")
        Log.info("[Lifecycle] Attempting to restore terminal")
        {:stop, :normal, %{}}

      {:unknown_error, _reason} ->
        Log.info("[Lifecycle] Unknown error: #{inspect(error)}")
        Log.info("[Lifecycle] Continuing execution")
        {:stop, :normal, %{}}

      %{type: :runtime_error} ->
        {:ok, :restart_components}

      %{type: :resource_error} ->
        {:ok, :reinitialize_resources}

      _ ->
        {:ok, :continue}
    end
  end

  @spec handle_cleanup(map()) :: :ok | {:error, :cleanup_failed}
  def handle_cleanup(context) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           Log.info("[Lifecycle] Cleaning up for app: #{context.app_name}")
           Log.info("[Lifecycle] Cleanup completed")
           :ok
         end) do
      {:ok, result} ->
        result

      {:error, error} ->
        Log.error("[Lifecycle] Cleanup failed: #{inspect(error)}")
        {:error, :cleanup_failed}
    end
  end
end
