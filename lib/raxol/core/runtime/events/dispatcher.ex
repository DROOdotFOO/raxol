defmodule Raxol.Core.Runtime.Events.Dispatcher do
  @moduledoc """
  Manages the application state (model) and dispatches events to the application's
  `update/2` function. It also handles commands returned by `update/2`.
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  alias Raxol.Core.Events.Event
  alias Raxol.Core.FocusManager
  alias Raxol.Core.Runtime.Application
  alias Raxol.Core.Runtime.Events.Bubbler
  alias Raxol.Core.Runtime.Events.DispatcherHooks
  alias Raxol.Core.UserPreferences

  @registry_name :raxol_event_subscriptions

  defmodule State do
    @moduledoc false
    defstruct runtime_pid: nil,
              app_module: nil,
              model: nil,
              # %{%Subscription{} => subscription_id} -- the subscriptions
              # currently running. Re-derived from the model after every update.
              active_subscriptions: %{},
              width: 0,
              height: 0,
              focused: true,
              debug_mode: false,
              plugin_manager: nil,
              plugin_manager_struct: nil,
              command_registry_table: nil,
              current_theme_id: :default,
              view_tree: nil,
              layout: [],
              rendering_engine: nil,
              time_travel: nil,
              cycle_profiler: nil,
              command_interceptor: nil,
              # Harness keystone: when set, both model-fold sites publish a
              # neutral event to Raxol.Core.Runtime.EmitBus keyed by this id.
              # nil (terminal/plain apps) makes emit/2 a no-op.
              session_id: nil,
              # Harness loop vocabulary: the turn currently in flight. Minted at
              # the agent-message dispatch (a prompt = a turn) and stamped onto
              # every event emitted while it is set, so all items within one turn
              # share a stable turn_id (U6's expected_turn_id CAS depends on it).
              turn_id: nil
  end

  # BaseManager provides start_link/1 and start_link/2 automatically
  # Custom start_link to handle the runtime_pid and initial_state parameters
  def start_link(runtime_pid, initial_state, opts \\ []) do
    server_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(
      __MODULE__,
      {runtime_pid, initial_state},
      server_opts
    )
  end

  @impl true
  def init_manager({runtime_pid, initial_state}) do
    state = %State{
      runtime_pid: runtime_pid,
      app_module: initial_state.app_module,
      model: initial_state.model,
      width: initial_state.width,
      height: initial_state.height,
      focused: true,
      debug_mode: initial_state.debug_mode,
      plugin_manager: initial_state.plugin_manager,
      plugin_manager_struct: Raxol.Plugins.Manager.new(),
      command_registry_table: initial_state.command_registry_table,
      rendering_engine: Map.get(initial_state, :rendering_engine),
      current_theme_id: safe_get_theme_id(),
      time_travel: Map.get(initial_state, :time_travel),
      cycle_profiler: Map.get(initial_state, :cycle_profiler),
      command_interceptor: Map.get(initial_state, :command_interceptor),
      session_id: Map.get(initial_state, :session_id)
    }

    send(runtime_pid, {:runtime_initialized, self()})

    send(runtime_pid, {:plugin_manager_ready, initial_state.plugin_manager})

    if test_env?(), do: send(self(), {:dispatcher_ready, self()})

    # Start app subscriptions (timers, event sources). Re-synced after every
    # update -- see sync_subscriptions/1.
    state = sync_subscriptions(state)

    {:ok, state}
  end

  @doc """
  Dispatches an event to the appropriate handler based on event type and target.
  """
  def dispatch_event(event, state) do
    case Raxol.Core.ErrorHandling.safe_call(fn ->
           do_dispatch_event(event, state)
         end) do
      {:ok, result} ->
        result

      {:error, error} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "Error dispatching event",
          error,
          nil,
          %{module: __MODULE__, event: event, state: state}
        )

        {:error, {:dispatch_error, error}, state}
    end
  end

  @doc """
  Handles an application-level event and updates the application state.
  """
  def handle_event(
        %Event{type: :mouse, data: %{action: :press, x: x, y: y}} = event,
        %State{} = state
      ) do
    case DispatcherHooks.hit_test(x, y, state.layout) do
      {:click, message} ->
        process_app_update(state, message, event)

      :miss ->
        do_handle_event(event, state)
    end
  end

  def handle_event(event, %State{} = state) do
    do_handle_event(event, state)
  end

  defp do_handle_event(event, state) do
    case try_bubble_event(event, state) do
      {:handled, {:message, message}} ->
        process_app_update(state, message, event)

      {:handled, _} ->
        send(state.runtime_pid, :render_needed)
        {:ok, state, []}

      {:commands, commands} ->
        context = build_command_context(state)
        process_commands(commands, context)
        send(state.runtime_pid, :render_needed)
        {:ok, state, commands}

      :passthrough ->
        # Pass the raw Event struct to update/2 — apps pattern-match on %Event{}
        process_app_update(state, event, event)
    end
  end

  defp try_bubble_event(_event, %State{view_tree: nil}), do: :passthrough

  defp try_bubble_event(event, state) do
    focused_id =
      if focus_manager_active?(),
        do: FocusManager.get_focused_element(),
        else: nil

    if focused_id do
      context = %{
        focused_element: focused_id,
        theme_id: state.current_theme_id
      }

      Bubbler.dispatch(event, state.view_tree, focused_id, context)
    else
      :passthrough
    end
  end

  defp process_app_update(state, message, event) do
    old_model = state.model

    {update_us, mem_before, mem_after, update_result} =
      DispatcherHooks.maybe_time_update(state.cycle_profiler, fn ->
        Application.delegate_update(state.app_module, message, state.model)
      end)

    case update_result do
      {updated_model, commands}
      when is_map(updated_model) and is_list(commands) ->
        DispatcherHooks.maybe_record_time_travel(
          state.time_travel,
          message,
          old_model,
          updated_model
        )

        DispatcherHooks.maybe_record_cycle_update(
          state.cycle_profiler,
          update_us,
          mem_before,
          mem_after,
          message
        )

        # Keystone: the same fold site TimeTravel taps also emits a typed
        # event. A synchronous update is a completed, durable step.
        emit(state, :app_update, :durable, %{message: message})

        process_successful_update(state, updated_model, commands)

      {:error, reason} ->
        log_update_error(state, message, event, reason)

      other ->
        log_unexpected_return(state, message, event, other)
    end
  end

  defp process_successful_update(state, updated_model, commands) do
    context = build_command_context(state)
    process_commands(commands, context)

    updated_state =
      state
      |> handle_theme_update(updated_model)
      |> sync_subscriptions()

    send(state.runtime_pid, :render_needed)
    {:ok, updated_state, commands}
  end

  defp build_command_context(state) do
    %{
      pid: self(),
      command_registry_table: state.command_registry_table,
      runtime_pid: state.runtime_pid,
      command_interceptor: state.command_interceptor
    }
  end

  defp handle_theme_update(state, updated_model) do
    case Map.get(updated_model, :current_theme_id, state.current_theme_id) do
      same when same == state.current_theme_id ->
        %{state | model: updated_model}

      new_theme_id ->
        try do
          UserPreferences.set("theme.active_id", new_theme_id)
        catch
          :exit, _ -> :ok
        end

        %{state | model: updated_model, current_theme_id: new_theme_id}
    end
  end

  defp log_update_error(state, message, event, reason) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "Application update failed",
      reason,
      nil,
      %{
        module: __MODULE__,
        app_module: state.app_module,
        message: message,
        current_model: state.model,
        event: event
      }
    )

    {:error, reason}
  end

  defp log_unexpected_return(state, message, event, other) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Unexpected return from #{state.app_module}.update",
      %{
        module: __MODULE__,
        app_module: state.app_module,
        message: message,
        current_model: state.model,
        event: event,
        other: other
      }
    )

    {:error, {:unexpected_return, other}}
  end

  @doc """
  Processes a system-level event. Resize is forwarded to the app's update/2
  like any other message; quit/focus/error stay runtime-only.
  """
  def process_system_event(event, state) do
    case event do
      %Event{type: :resize} -> handle_resize_event(event, state)
      %Event{type: :quit} -> {:quit, state}
      %Event{type: :focus, data: data} -> handle_focus_event(data, state)
      %Event{type: :error, data: data} -> handle_error_event(data, state)
      _ -> {:ok, state, []}
    end
  end

  defp handle_resize_event(
         %Event{data: %{width: width, height: height}} = event,
         state
       ) do
    # Forward size to the Rendering Engine so layout uses actual terminal dimensions
    if state.rendering_engine do
      GenServer.cast(
        state.rendering_engine,
        {:update_size, %{width: width, height: height}}
      )
    end

    sized_state = %{state | width: width, height: height}

    case resize_update(sized_state, event) do
      {:ok, updated_model, commands} ->
        process_successful_update(sized_state, updated_model, commands)

      :unhandled ->
        send(state.runtime_pid, :render_needed)
        {:ok, sized_state, []}
    end
  end

  # Calls update/2 directly (not through process_app_update) so a resize
  # clause that doesn't exist can degrade silently: most apps don't reflow
  # on resize, and a FunctionClauseError there isn't a bug worth logging on
  # every SIGWINCH. Genuinely malformed return values still get logged.
  defp resize_update(state, event) do
    case state.app_module.update(event, state.model) do
      {new_model, commands} when is_map(new_model) and is_list(commands) ->
        {:ok, new_model, commands}

      new_model when is_map(new_model) ->
        {:ok, new_model, []}

      other ->
        log_unexpected_return(state, event, event, other)
        :unhandled
    end
  rescue
    FunctionClauseError -> :unhandled
    UndefinedFunctionError -> :unhandled
  end

  defp handle_focus_event(%{focused: focused}, state) do
    {:ok, %{state | focused: focused}, []}
  end

  defp handle_error_event(%{error: error}, state) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "System error event",
      error,
      nil,
      %{module: __MODULE__, error: error, state: state}
    )

    {:error, error, state}
  end

  # --- Public API for PubSub ---

  @doc "Subscribes the calling process to a specific event topic."
  @spec subscribe(atom()) :: {:ok, pid()}
  def subscribe(topic) when is_atom(topic) do
    Registry.register(@registry_name, topic, {})
  end

  @doc "Unsubscribes the calling process from a specific event topic."
  @spec unsubscribe(atom()) :: :ok
  def unsubscribe(topic) when is_atom(topic) do
    Registry.unregister(@registry_name, topic)
  end

  @doc "Broadcasts an event payload to all subscribers of a topic."
  @spec broadcast(atom(), map()) :: :ok
  def broadcast(topic, payload) when is_atom(topic) and is_map(payload) do
    Raxol.Core.Runtime.Log.debug(
      "[#{__MODULE__}] Broadcasting on topic #{topic}"
    )

    # Find subscribers for the topic (registry may not exist in web-only deployments)
    @registry_name
    |> Registry.lookup(topic)
    |> Enum.each(fn {pid, _value} ->
      send(pid, {:event, topic, payload})
    end)

    :ok
  rescue
    ArgumentError ->
      # Registry not started (web-only deployment); not an error
      :ok
  end

  # --- BaseManager Callbacks ---

  @impl true
  def handle_manager_cast(
        {:dispatch, {:agent_message, _from, _payload} = msg, metadata},
        state
      )
      when is_map(metadata) do
    apply_causation(metadata)

    Raxol.Core.Runtime.Log.debug(
      "[Dispatcher] handle_cast :dispatch agent_message: #{inspect(msg)}"
    )

    with_dispatch_span(fn -> dispatch_agent_turn(msg, state) end)
  end

  @impl true
  def handle_manager_cast(
        {:dispatch, {:agent_message, _from, _payload} = msg},
        state
      ) do
    Raxol.Core.Runtime.Log.debug(
      "[Dispatcher] handle_cast :dispatch agent_message: #{inspect(msg)}"
    )

    # Agent messages go directly to update/2, bypassing event/plugin pipeline
    with_dispatch_span(fn -> dispatch_agent_turn(msg, state) end)
  end

  @impl true
  def handle_manager_cast(
        {:dispatch, {:layout_recommendation, _rec} = msg},
        state
      ) do
    # Layout recommendations go directly to update/2
    dispatch_raw_message(msg, state)
  end

  @impl true
  def handle_manager_cast({:dispatch, event}, state) do
    dispatch_full_event(event, state)
  end

  @impl true
  def handle_manager_cast({:set_rendering_engine, pid}, state)
      when is_pid(pid) do
    # Forward current dimensions immediately — the initial resize event from the
    # Driver arrived before we had the rendering engine PID, so it was lost.
    if state.width > 0 and state.height > 0 do
      GenServer.cast(
        pid,
        {:update_size, %{width: state.width, height: state.height}}
      )
    end

    {:noreply, %{state | rendering_engine: pid}}
  end

  @impl true
  def handle_manager_cast({:internal_event, event}, state) do
    # This is for events that are internal to the dispatcher or runtime system.
    Raxol.Core.Runtime.Log.warning_with_context(
      "Dispatcher received unhandled internal_event",
      %{module: __MODULE__, event: event, state: state}
    )

    {:noreply, state}
  end

  # Catch-all for other cast messages
  @impl true
  def handle_manager_cast(
        {:update_plugin_manager, %Raxol.Plugins.Manager{} = updated},
        state
      ) do
    {:noreply, %{state | plugin_manager_struct: updated}}
  end

  @impl true
  def handle_manager_cast({:restore_model, model}, state) when is_map(model) do
    send(state.runtime_pid, :render_needed)
    {:noreply, %{state | model: model}}
  end

  @impl true
  def handle_manager_cast({:update_view_tree, view_tree}, state) do
    {:noreply, %{state | view_tree: view_tree}}
  end

  @impl true
  def handle_manager_cast({:update_layout, positioned_elements}, state) do
    {:noreply, %{state | layout: positioned_elements}}
  end

  @impl true
  def handle_manager_cast(msg, state) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Dispatcher received unhandled cast message",
      %{module: __MODULE__, message: msg, state: state}
    )

    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:command_result, msg}, %State{} = state) do
    full_message = {:command_result, msg}
    process_command_result(state, full_message)
  end

  @impl true
  def handle_manager_info({:dispatcher_ready, _pid}, state) do
    # Acknowledge dispatcher initialization in test mode
    {:noreply, state}
  end

  @impl true
  def handle_manager_info({:subscription, msg}, state) do
    # Subscription timer fired — route message through app's update/2
    dispatch_raw_message(msg, state)
  end

  @impl true
  def handle_manager_info(msg, state) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "Dispatcher received unhandled info message",
      %{module: __MODULE__, message: msg, state: state}
    )

    {:noreply, state}
  end

  defp process_command_result(state, message) do
    case Application.delegate_update(state.app_module, message, state.model) do
      {updated_model, commands}
      when is_map(updated_model) and is_list(commands) ->
        # Keystone: the async command-result fold used to update the model
        # silently. It now emits a typed event. Async chunks (LLM stream /
        # shell / ticks) are live-render-only, hence :ephemeral.
        emit(state, :command_result, :ephemeral, %{message: message})

        process_command_commands(state, updated_model, commands)

      {:error, reason} ->
        log_command_failure(
          :error,
          "[Dispatcher] Error calling delegate_update in handle_info",
          reason,
          %{module: __MODULE__, msg: message, state: state}
        )

        {:noreply, state}

      other ->
        log_command_failure(
          :warning,
          "[Dispatcher] Unexpected return from delegate_update in handle_info",
          other,
          %{module: __MODULE__, msg: message, state: state, other: other}
        )

        {:noreply, state}
    end
  end

  defp process_command_commands(state, updated_model, commands) do
    context = build_command_context(state)

    case Raxol.Core.ErrorHandling.safe_call(fn ->
           process_commands(commands, context)
         end) do
      {:ok, _} ->
        :ok

      {:error, error} ->
        log_command_failure(
          :error,
          "[Dispatcher] Error processing commands from command result",
          error,
          %{module: __MODULE__}
        )
    end

    {:noreply, %{state | model: updated_model}}
  end

  # --- Harness keystone emit ---------------------------------------------
  # Single typed-emit seam shared by both model-fold sites. Publishes a
  # neutral event map to Raxol.Core.Runtime.EmitBus (main-package pub/sub, no
  # raxol_agent dependency). No-op unless the session was started with a
  # :session_id. Raxol.Agent.EmitBridge subscribes and maps these to the
  # agent Contract on the raxol_agent side.
  defp emit(%State{session_id: nil}, _type, _tier, _payload), do: :ok

  defp emit(%State{session_id: session_id, turn_id: turn_id}, type, tier, payload) do
    session_id
    |> Raxol.Core.Runtime.EmitBus.build(type, tier, payload, turn_id: turn_id)
    |> Raxol.Core.Runtime.EmitBus.publish()

    :ok
  end

  # --- Harness loop vocabulary: turn brackets ----------------------------
  # An inbound agent message is one turn. We mint a turn_id, emit a durable
  # `:turn_started` before the fold, run the model fold (whose own durable
  # `:app_update` emit now carries this turn_id), then bracket with a durable
  # `:turn_completed` on success or `:error` on failure. The turn_id persists
  # in state so any async `:command_result` deltas that stream out of the
  # turn's commands carry the same turn_id.
  #
  # NOTE (v0 limitation): turn_completed is emitted when the synchronous fold
  # returns. Agents that stream via async commands will emit their ephemeral
  # item_deltas after turn_completed (same turn_id). Tightening the boundary to
  # the last async chunk is a later unit — see the module TODO.
  defp dispatch_agent_turn(msg, state) do
    turn_state = %{state | turn_id: mint_turn_id()}
    emit(turn_state, :turn_started, :durable, %{message: msg})

    case process_app_update(turn_state, msg, msg) do
      {:ok, new_state, _commands} ->
        emit(new_state, :turn_completed, :durable, %{})
        {:noreply, new_state}

      {:error, reason} ->
        emit(turn_state, :error, :durable, %{reason: reason})
        {:noreply, turn_state}
    end
  end

  defp mint_turn_id, do: "turn-#{System.unique_integer([:positive])}"

  defp log_command_failure(:error, label, reason, context) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(label, reason, nil, context)
  end

  defp log_command_failure(:warning, label, _reason, context) do
    Raxol.Core.Runtime.Log.warning_with_context(label, context)
  end

  # Call-mode mirrors of the :dispatch cast clauses.
  # Backpressure escalates to GenServer.call/3 when the mailbox is hot;
  # the work is identical, only the reply contract differs.

  @impl true
  def handle_manager_call(
        {:dispatch, {:agent_message, _from, _payload} = msg},
        _from_caller,
        state
      ) do
    Raxol.Core.Runtime.Log.debug(
      "[Dispatcher] handle_call :dispatch agent_message: #{inspect(msg)}"
    )

    with_dispatch_span(fn ->
      msg |> dispatch_agent_turn(state) |> to_call_reply()
    end)
  end

  @impl true
  def handle_manager_call(
        {:dispatch, {:layout_recommendation, _rec} = msg},
        _from_caller,
        state
      ) do
    msg |> dispatch_raw_message(state) |> to_call_reply()
  end

  @impl true
  def handle_manager_call({:dispatch, event}, _from_caller, state) do
    event |> dispatch_full_event(state) |> to_call_reply()
  end

  @impl true
  def handle_manager_call(:get_plugin_manager, _from, state) do
    {:reply, {:ok, state.plugin_manager_struct}, state}
  end

  @impl true
  def handle_manager_call(:get_model, _from, state) do
    {:reply, {:ok, state.model}, state}
  end

  @impl true
  def handle_manager_call(:get_view_tree, _from, state) do
    {:reply, {:ok, state.view_tree}, state}
  end

  @impl true
  def handle_manager_call(:get_render_context, _from, state) do
    Raxol.Core.Runtime.Log.debug(
      "Dispatcher received :get_render_context call for #{inspect(state.app_module)}"
    )

    focused_element =
      if focus_manager_active?(),
        do: FocusManager.get_focused_element(),
        else: nil

    reduced_motion =
      try do
        if Code.ensure_loaded?(Raxol.Animation.Framework) do
          Raxol.Animation.Framework.should_reduce_motion?()
        else
          false
        end
      catch
        :exit, _ -> false
      end

    render_context = %{
      model: state.model,
      theme_id: state.current_theme_id,
      focused_element: focused_element,
      reduced_motion: reduced_motion
    }

    Raxol.Core.Runtime.Log.debug(
      "Dispatcher returning render context: #{inspect(render_context)}"
    )

    {:reply, {:ok, render_context}, state}
  end

  @impl true
  def terminate(reason, _state) do
    Raxol.Core.Runtime.Log.info(
      "Event Dispatcher terminating. Reason: #{inspect(reason)}"
    )

    :ok
  end

  defp do_dispatch_event(event, state) do
    log_debug_if_enabled(state.debug_mode, event)
    route_event_by_type(system_event?(event), event, state)
  end

  defp system_event?(%Event{type: type}) do
    type in [:resize, :quit, :focus, :error, :system]
  end

  defp system_event?(_), do: false

  defp apply_plugin_filters(event, state) do
    manager_pid = state.plugin_manager

    if is_pid(manager_pid) and Process.alive?(manager_pid) do
      case GenServer.call(manager_pid, {:filter_event, event}) do
        {:ok, filtered_event} -> filtered_event
        :halt -> nil
        {:error, _reason} -> nil
        _ -> event
      end
    else
      event
    end
  rescue
    e ->
      Logger.debug("Plugin filter failed: #{Exception.message(e)}")
      event
  end

  # --- Command Processing ---

  # --- Helper Functions for Pattern Matching ---

  defp safe_get_theme_id do
    UserPreferences.get_theme_id()
  catch
    :exit, _ -> :default
  end

  # Route a raw message (not an Event struct) directly through update/2
  defp dispatch_raw_message(msg, state) do
    case process_app_update(state, msg, msg) do
      {:ok, new_state, _commands} ->
        {:noreply, new_state}

      _ ->
        {:noreply, state}
    end
  end

  # Shared work for the generic {:dispatch, event} path. Returns a
  # standard GenServer cast reply tuple; to_call_reply/1 reshapes it
  # for the call clause.
  defp dispatch_full_event(event, state) do
    Raxol.Core.Runtime.Log.debug(
      "[Dispatcher] dispatching event: #{inspect(event)}"
    )

    # Record input events for session recording (zero-coupling)
    DispatcherHooks.maybe_record_input(event)

    case do_dispatch_event(event, state) do
      {:ok, new_state, _commands} ->
        broadcast_event_if_valid(event.type, event.data)
        {:noreply, new_state}

      {:quit, new_state} ->
        {:stop, :normal, new_state}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "[Dispatcher] Error handling event",
          reason,
          nil,
          %{module: __MODULE__, event: event, state: state}
        )

        {:noreply, state}

      other ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "[Dispatcher] Unexpected return from do_dispatch_event",
          %{module: __MODULE__, event: event, state: state, other: other}
        )

        {:noreply, state}
    end
  end

  defp to_call_reply({:noreply, state}), do: {:reply, :ok, state}
  defp to_call_reply({:stop, reason, state}), do: {:stop, reason, :ok, state}

  # Subscriptions are a function of the model, so they are re-derived after every
  # update and diffed against what is running: newly-declared ones are started,
  # no-longer-declared ones are stopped. Deriving them once at init would freeze
  # them against the initial model -- an app whose subscriptions depend on state
  # (poll only while a job runs; tick only the selected view) would never get
  # them started.
  #
  # A `%Subscription{type: t, data: d}` is its own identity: two structurally
  # equal subscriptions are the same subscription, so an unchanged one is left
  # running untouched rather than being torn down and restarted each update.
  defp sync_subscriptions(state) do
    desired = declared_subscriptions(state)
    active = state.active_subscriptions

    Enum.each(Map.drop(active, desired), fn {_sub, sub_id} ->
      Raxol.Core.Runtime.Subscription.stop(sub_id)
    end)

    started =
      desired
      |> Enum.reject(&Map.has_key?(active, &1))
      |> Enum.reduce(%{}, fn sub, acc ->
        case Raxol.Core.Runtime.Subscription.start(sub, %{pid: self()}) do
          {:ok, sub_id} -> Map.put(acc, sub, sub_id)
          _ -> acc
        end
      end)

    kept = Map.take(active, desired)
    %{state | active_subscriptions: Map.merge(kept, started)}
  end

  defp declared_subscriptions(state) do
    if function_exported?(state.app_module, :subscribe, 1) do
      case state.app_module.subscribe(state.model) do
        subs when is_list(subs) ->
          Enum.filter(subs, &match?(%Raxol.Core.Runtime.Subscription{}, &1))

        _ ->
          []
      end
    else
      []
    end
  rescue
    e ->
      Logger.debug("Subscription sync failed: #{Exception.message(e)}")
      []
  end

  defp broadcast_event_if_valid(event_type, event_data)
       when is_atom(event_type) and is_map(event_data) do
    Raxol.Core.Runtime.Log.debug(
      "[Dispatcher] Broadcasting event: #{inspect(event_type)} via internal broadcast"
    )

    _ = __MODULE__.broadcast(event_type, event_data)
  end

  defp broadcast_event_if_valid(event_type, event_data) do
    Raxol.Core.Runtime.Log.warning(
      "[Dispatcher] Event not broadcast due to invalid type/data: type=#{inspect(event_type)}, data=#{inspect(event_data)}"
    )
  end

  defp log_debug_if_enabled(true, event) do
    Raxol.Core.Runtime.Log.debug("Dispatching event: #{inspect(event)}")
  end

  defp log_debug_if_enabled(false, _event), do: :ok

  defp route_event_by_type(true, event, state) do
    process_system_event(event, state)
  end

  defp route_event_by_type(false, event, state) do
    filtered_event = apply_plugin_filters(event, state)
    handle_filtered_event(filtered_event, state)
  end

  defp handle_filtered_event(nil, state), do: {:ok, state, []}

  defp handle_filtered_event(filtered_event, state) do
    case maybe_handle_focus_navigation(filtered_event, state) do
      {:handled, result} -> result
      :pass -> handle_event(filtered_event, state)
    end
  end

  defp maybe_handle_focus_navigation(
         %Event{type: :key, data: %{key: :tab} = data},
         state
       ) do
    if focus_manager_active?() do
      shift = Map.get(data, :shift, false)
      old_focus = FocusManager.get_focused_element()

      result =
        if shift,
          do: FocusManager.focus_previous(),
          else: FocusManager.focus_next()

      case result do
        {:ok, new_focus_id} ->
          {:handled,
           process_app_update(
             state,
             {:focus_changed, old_focus, new_focus_id},
             nil
           )}

        {:error, _} ->
          :pass
      end
    else
      :pass
    end
  end

  defp maybe_handle_focus_navigation(_event, _state), do: :pass

  defp focus_manager_active? do
    Process.whereis(Raxol.Core.FocusManager.FocusServer) != nil
  end

  # --- Command Processing ---

  defp process_commands(commands, context) when is_list(commands) do
    # Security gate: an optional command interceptor (e.g. the agent
    # permission/sandbox hook chain) may inspect, modify, or deny directives
    # before they run. nil for non-agent surfaces, so this is a no-op there.
    commands = apply_command_interceptor(context, commands)

    Raxol.Core.Runtime.Log.debug(
      "[Dispatcher.process_commands] Processing commands: #{inspect(commands)} with context: #{inspect(context)}"
    )

    Enum.each(commands, fn command ->
      if directive?(command) do
        Raxol.Core.Runtime.Directive.Executor.execute(command, context)
      else
        Raxol.Core.Runtime.Log.warning_with_context(
          "[#{__MODULE__}] Invalid effect format: #{inspect(command)}. Expected a directive struct. Ignoring.",
          %{command: command}
        )
      end
    end)
  end

  defp apply_command_interceptor(%{command_interceptor: fun}, commands)
       when is_function(fun, 1),
       do: fun.(commands)

  defp apply_command_interceptor(_context, commands), do: commands

  defp directive?(effect) do
    is_struct(effect) and
      Raxol.Core.Runtime.Directive.Executor.impl_for(effect) != nil
  end

  defp test_env?, do: Code.ensure_loaded?(Mix) and Mix.env() == :test

  defp apply_causation(%{causation_id: id}) when is_binary(id) do
    Raxol.Core.Telemetry.TraceContext.set_causation(id)
  end

  defp apply_causation(_), do: :ok

  # Wrap an agent-message dispatch in a fresh span so that any
  # outbound Directive.SendAgent emitted from update/2 can attach
  # `causation_id == current().span_id` to its cast metadata. Without
  # this, multi-hop causation chains would collapse to the trace root.
  defp with_dispatch_span(fun) do
    _ = Raxol.Core.Telemetry.TraceContext.start_span("agent.dispatch")

    try do
      fun.()
    after
      _ = Raxol.Core.Telemetry.TraceContext.end_span()
    end
  end
end
