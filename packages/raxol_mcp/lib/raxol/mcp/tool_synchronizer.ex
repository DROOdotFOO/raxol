defmodule Raxol.MCP.ToolSynchronizer do
  @moduledoc """
  Per-session GenServer that bridges the render pipeline to the MCP Registry.

  When an app module is provided, pulls the current model and derives its
  initial tools synchronously before startup returns. Subsequent
  `[:raxol, :runtime, :view_tree_updated]` telemetry events refresh tools from
  the rendered view tree. Rapid renders are debounced (`:debounce_ms`).

  Also manages model-projected resources when the app implements
  `Raxol.MCP.ResourceProvider`, and registers context tree + widget tree
  resources for the session.

  Started by `Raxol.Headless` when creating a session, which passes itself as
  `:owner`: when the owner exits, the synchronizer stops and its `terminate/2`
  unregisters the session's tools and resources.

  Every tool it registers is named under the session id: derived tools are
  `"session_id.widget_id.action"` and the meta-tool is
  `"session_id.discover_tools"`, so sessions rendering the same widget never
  share a tool. A tool `Raxol.MCP.Registry` refuses (its client-side name is
  already taken), the meta-tool included, is left out of the session's set
  and offered again on every sync; the refusals are logged when they change,
  not on every sync, and `name_collisions/1` answers them.

  A session whose id is not 1-32 characters of `[A-Za-z0-9_-]`
  (`Raxol.MCP.TreeWalker.id?/1`) registers no tools, its meta-tool included,
  and no resources (the id would be in their URIs and descriptions), and is
  warned about once. A derived tool whose name OMP would show hashed (longer
  than 64 characters with the `mcp__raxol_raxol_` prefix of the recommended
  `raxol:raxol` plugin key) is registered and warned about when a render
  first derives it. That warning and each widget refusal
  `Raxol.MCP.TreeWalker` reports are given once per session, also when the
  widget leaves the view and comes back; what was warned about is remembered
  for the 256 most recently rendered, so a view with per-item ids keeps
  memory bounded and is warned about again only for an item that comes back
  after 256 newer ones.

  ## Sticky tool sets

  A session's tool set is every tool its views have derived so far, keyed by
  name, provider module and a hash of the listed definition (description,
  input schema, annotations). A widget that leaves the view keeps its tools,
  so a modal opened, dismissed and opened again changes the set once; a tool
  whose provider or definition changes is registered again. Each change sends
  one `notifications/tools/list_changed` to the `:server`. The whole set is
  unregistered when the session stops, and the Registry removes it if this
  process dies without stopping (it registers as the tools' `:owner`).

  With an app module, a derived tool resolves its widget at call time from a
  fresh `view/1` of the dispatcher's current model, so it always acts on the
  widget as it is now (see `Raxol.MCP.TreeWalker`), and a call that dispatched
  messages syncs this session's tool set with their effect before it answers.

  ## Options

    * `:registry`, `:dispatcher_pid`, `:session_id` - required
    * `:app_module` - the session's TEA module
    * `:server` - the `Raxol.MCP.Server` that `list_changed` notifications go
      to (default `Raxol.MCP.Server`)
    * `:debounce_ms` - how long a render waits for the next before it is
      synced; `0` syncs each render as it arrives, with no timer. Default:
      `config :raxol_mcp, :tool_synchronizer, debounce_ms: ...`, else 50.

  ## Usage

      {:ok, pid} = ToolSynchronizer.start_link(
        registry: Raxol.MCP.Registry,
        dispatcher_pid: dispatcher_pid,
        session_id: "demo",
        app_module: MyApp
      )
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @compile {:no_warn_undefined, [Raxol.Adaptive.BehaviorTracker]}

  alias Raxol.MCP.{ContextTree, Diff, FocusLens, Registry, StructuredScreenshot, TreeWalker}

  @default_debounce_ms 50

  # Below `GenServer.call/2`'s default 5 s, so a flush whose sender does not
  # answer still answers its caller.
  @flush_sender_timeout_ms 4_000

  defstruct [
    :registry,
    :dispatcher_pid,
    :session_id,
    :app_module,
    :telemetry_handler_id,
    :owner_ref,
    :debounce_ref,
    server: Raxol.MCP.Server,
    debounce_ms: @default_debounce_ms,
    # The session's tool set: name => {provider, definition hash}.
    tools: %{},
    # Tool name => the name holding its client-side name, from the last sync.
    name_collisions: %{},
    current_resource_uris: MapSet.new(),
    current_view_tree: nil,
    current_model: nil,
    previous_projections: %{},
    pending_view_tree: nil,
    pending_model: nil,
    focused_id: nil,
    hover_id: nil,
    # Each TreeWalker refusal (`{:refusal, refusal}`, see
    # `TreeWalker.derive_with_refusals/2`) and derived name OMP would show
    # hashed (`{:long_name, name}`) warned about, => the render that last
    # derived it. Only the @max_warned most recent are kept.
    warned: %{},
    renders: 0
  ]

  @doc "Start a ToolSynchronizer linked to the calling process."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Force an immediate tool sync from the current view tree."
  @spec sync(GenServer.server(), map()) :: :ok
  def sync(synchronizer, view_tree) do
    GenServer.cast(synchronizer, {:sync_now, view_tree})
  end

  @doc """
  Applies a view-tree update still waiting out the debounce now, and returns
  once the registry reflects it.

  A barrier: once `flush/2` returns, the session's tool set includes every
  tool the last view tree that reached this process derives. Messages from one
  process to another arrive in the order sent, but nothing orders the
  caller's flush after a view tree another process sent. `sender` names that
  process (the session's rendering engine, whose render casts the view tree):
  the synchronizer takes a reply from `sender` first, which arrives after
  every view tree `sender` sent before it, so a render that answered before
  `flush/2` was called is always applied. `sender` must not be the caller,
  which cannot answer while it waits. Without `sender` only view trees
  already received are applied.
  """
  @spec flush(GenServer.server(), pid() | nil) :: :ok
  def flush(synchronizer, sender \\ nil) do
    GenServer.call(synchronizer, {:flush, sender})
  end

  @doc """
  The session's tools the registry refused at the last sync because another
  tool, `holder`, has the same client-side name
  (`Raxol.MCP.Registry.omp_name/1`), as `{name, holder}`. Only name
  collisions: a widget id or action name `Raxol.MCP.TreeWalker` refuses, or
  a session id that names no tools, is not here.
  """
  @spec name_collisions(GenServer.server()) :: [{String.t(), String.t()}]
  def name_collisions(synchronizer) do
    GenServer.call(synchronizer, :name_collisions)
  end

  @doc """
  Record the focused widget ID.

  When a widget gains focus (keyboard or mouse click), call this. It does
  not change which tools are registered: every derived tool stays
  registered whatever has focus.

  Emits `:pane_focus` behavior data with the focused ID in `:pane_id`, plus
  `[:raxol, :mcp, :focus_changed]` telemetry.
  """
  @spec update_focus(GenServer.server(), String.t() | nil) :: :ok
  def update_focus(synchronizer, widget_id) do
    GenServer.cast(synchronizer, {:focus_changed, widget_id})
  end

  @doc """
  Record the hovered widget ID.

  Like `update_focus/2`, it does not change which tools are registered: the
  ID is only stored. Hover emits a separate `:widget_hover` behavior event
  and `[:raxol, :mcp, :hover_changed]` telemetry; it does not change adaptive
  keyboard focus.
  """
  @spec update_hover(GenServer.server(), String.t() | nil) :: :ok
  def update_hover(synchronizer, widget_id) do
    GenServer.cast(synchronizer, {:hover_changed, widget_id})
  end

  # -- GenServer callbacks --

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    registry = Keyword.fetch!(opts, :registry)
    dispatcher_pid = Keyword.fetch!(opts, :dispatcher_pid)
    session_id = Keyword.fetch!(opts, :session_id)
    app_module = Keyword.get(opts, :app_module)

    owner_ref =
      case Keyword.get(opts, :owner) do
        nil -> nil
        owner -> Process.monitor(owner)
      end

    handler_id = "tool_sync_#{session_id}_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol, :runtime, :view_tree_updated],
      &__MODULE__.handle_telemetry_event/4,
      %{synchronizer: self(), dispatcher_pid: dispatcher_pid}
    )

    state = %__MODULE__{
      registry: registry,
      dispatcher_pid: dispatcher_pid,
      session_id: session_id,
      app_module: app_module,
      server: Keyword.get(opts, :server, Raxol.MCP.Server),
      debounce_ms: Keyword.get_lazy(opts, :debounce_ms, &configured_debounce_ms/0),
      telemetry_handler_id: handler_id,
      owner_ref: owner_ref
    }

    # A registry call that exits (a registry too busy to answer within the
    # call timeout) stops this init, and an init that stops runs no
    # `terminate/2`: the telemetry handler would outlive this process, and
    # what the registry took before it stalled, or takes once it resumes,
    # would go only once the registry handles this process's exit.
    try do
      {:ok, register_session(state)}
    catch
      kind, reason ->
        :telemetry.detach(handler_id)
        withdraw_session(state)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp configured_debounce_ms do
    :raxol_mcp
    |> Application.get_env(:tool_synchronizer, [])
    |> Keyword.get(:debounce_ms, @default_debounce_ms)
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:name_collisions, _from, state) do
    {:reply, Enum.sort(state.name_collisions), state}
  end

  def handle_manager_call({:flush, nil}, _from, state) do
    {:reply, :ok, apply_pending(state)}
  end

  # Any reply `sender` sends comes after the view trees it cast before it, so
  # once it is in, those casts are queued here; the self-sent message then
  # lines up behind them and the reply goes out after they are applied.
  def handle_manager_call({:flush, sender}, from, state) when is_pid(sender) do
    await_reply_from(sender)
    send(self(), {:flush_reply, from})
    {:noreply, state}
  end

  # A derived tool's call has dispatched its messages: bring the tool set up
  # to date with the model they produced before the call answers. A render
  # still waiting out the debounce is older than that model, so it is dropped.
  def handle_manager_call(:sync_view, _from, %{app_module: nil} = state) do
    {:reply, :ok, apply_pending(state)}
  end

  def handle_manager_call(:sync_view, _from, state) do
    state = cancel_pending(state)

    case live_view(state) do
      {:ok, view_tree, model} -> {:reply, :ok, apply_sync(view_tree, model, state)}
      :none -> {:reply, :ok, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:view_tree_updated, view_tree, model}, state) do
    {:noreply, pend(state, view_tree, model)}
  end

  def handle_manager_cast({:view_tree_updated, view_tree}, state) do
    {:noreply, pend(state, view_tree, state.pending_model)}
  end

  def handle_manager_cast({:sync_now, view_tree}, state) do
    model = state.pending_model || state.current_model
    {:noreply, apply_sync(view_tree, model, cancel_pending(state))}
  end

  def handle_manager_cast({:focus_changed, widget_id}, state) do
    if widget_id != state.focused_id do
      emit_behavior_event(
        :pane_focus,
        %{pane_id: widget_id, source: :keyboard},
        :focus_changed
      )

      {:noreply, %{state | focused_id: widget_id}}
    else
      {:noreply, state}
    end
  end

  def handle_manager_cast({:hover_changed, widget_id}, state) do
    if widget_id != state.hover_id do
      emit_behavior_event(
        :widget_hover,
        %{widget_id: widget_id, source: :mouse},
        :hover_changed
      )

      {:noreply, %{state | hover_id: widget_id}}
    else
      {:noreply, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:debounce_fire, %{pending_view_tree: nil} = state) do
    {:noreply, %{state | debounce_ref: nil}}
  end

  def handle_manager_info(:debounce_fire, state) do
    {:noreply, apply_pending(state)}
  end

  def handle_manager_info({:flush_reply, from}, state) do
    state = apply_pending(state)
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  def handle_manager_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state),
    do: {:stop, :normal, state}

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.telemetry_handler_id)

    # The session's whole tool set goes with it, but only what this process
    # still owns: a name another synchronizer registered since is that one's.
    names = Map.keys(state.tools)

    if names != [] do
      try do
        Registry.unregister_tools(state.registry, names, owner: self())
        notify_tools_changed(state)
      catch
        :exit, _ -> :ok
      end
    end

    # Clean up resources
    uris = MapSet.to_list(state.current_resource_uris)

    if uris != [] do
      try do
        Registry.unregister_resources(state.registry, uris, owner: self())
      catch
        :exit, _ -> :ok
      end
    end

    :ok
  end

  # -- Telemetry handler (called in the emitting process) --

  @doc false
  def handle_telemetry_event(
        _event_name,
        _measurements,
        %{view_tree: view_tree, dispatcher_pid: dispatcher_pid} = metadata,
        %{synchronizer: synchronizer, dispatcher_pid: expected_pid}
      ) do
    # Only handle events from our session's dispatcher
    if dispatcher_pid == expected_pid do
      model = Map.get(metadata, :model)
      GenServer.cast(synchronizer, {:view_tree_updated, view_tree, model})
    end
  end

  def handle_telemetry_event(_event_name, _measurements, _metadata, _config), do: :ok

  # `:sys.statistics/3` is a request every OTP process answers, cheaply. A
  # sender that is gone has nothing more to deliver; one that does not answer
  # within the bound is not waited on further.
  defp await_reply_from(sender) do
    _ = :sys.statistics(sender, :get, @flush_sender_timeout_ms)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp apply_pending(%{pending_view_tree: nil} = state), do: state

  defp apply_pending(state) do
    view_tree = state.pending_view_tree
    model = state.pending_model || state.current_model
    apply_sync(view_tree, model, cancel_pending(state))
  end

  # -- Private: sync --

  # A render to sync: now with no debounce, else when the renders pause.
  defp pend(%{debounce_ms: 0} = state, view_tree, model) do
    apply_sync(view_tree, model || state.current_model, state)
  end

  defp pend(state, view_tree, model) do
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    ref = Process.send_after(self(), :debounce_fire, state.debounce_ms)
    %{state | pending_view_tree: view_tree, pending_model: model, debounce_ref: ref}
  end

  defp cancel_pending(state) do
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    %{state | debounce_ref: nil, pending_view_tree: nil, pending_model: nil}
  end

  defp apply_sync(view_tree, model, state) do
    {changed?, state} = do_sync(view_tree, model, state)
    if changed?, do: notify_tools_changed(state)
    state
  end

  defp register_session(%{session_id: session_id} = state) do
    if not TreeWalker.id?(session_id), do: TreeWalker.warn_refused_session_id(session_id)

    # Register the session's discover_tools meta-tool
    {meta_registered?, state} = offer(state, discover_tool(state))

    # Register session-level resources (context tree, widget tree)
    resource_uris =
      if TreeWalker.id?(session_id), do: register_session_resources(state), else: MapSet.new()

    state = %{state | current_resource_uris: resource_uris}

    # Seed tools synchronously so callers never observe a meta-tool-only
    # session when the engine's first render preceded telemetry attachment.
    {changed?, state} = sync_initial_view(state)
    if changed? or meta_registered?, do: notify_tools_changed(state)
    state
  end

  defp sync_initial_view(%{app_module: nil} = state), do: {false, state}

  defp sync_initial_view(state) do
    case live_view(state) do
      {:ok, view_tree, model} -> do_sync(view_tree, model, state)
      :none -> {false, state}
    end
  end

  # The app's view of the dispatcher's current model, as the engine renders it.
  defp live_view(state) do
    case GenServer.call(state.dispatcher_pid, :get_model) do
      {:ok, model} ->
        case state.app_module.view(model) do
          nil -> :none
          view_tree -> {:ok, view_tree, model}
        end

      {:error, reason} ->
        Logger.warning(
          "[MCP.ToolSynchronizer] Model pull failed for #{inspect(state.session_id)}: #{inspect(reason)}"
        )

        :none
    end
  rescue
    exception ->
      Logger.warning(
        "[MCP.ToolSynchronizer] View sync failed for #{inspect(state.session_id)}: #{Exception.message(exception)}"
      )

      :none
  catch
    kind, reason ->
      Logger.warning(
        "[MCP.ToolSynchronizer] View sync failed for #{inspect(state.session_id)}: #{inspect({kind, reason})}"
      )

      :none
  end

  # Answers whether the session's tool set changed, and the state.
  defp do_sync(view_tree, model, state) do
    {changed?, state} = sync_tools(view_tree, state)

    # Resource sync (model projections)
    state = sync_model_resources(model, state)

    {changed?, %{state | current_view_tree: view_tree, current_model: model}}
  end

  # The meta-tool is offered with the derived tools, so a refused one is
  # registered as soon as its client-side name is free.
  defp sync_tools(view_tree, state) do
    {derived, state} = derive_tools(view_tree, state)
    offer(state, discover_tool(state) ++ derived)
  end

  # The set only grows: a tool is registered when its name is new to the
  # session or its provider or listed definition changed, and is never
  # unregistered here because its widget left the view. Answers whether any
  # was registered, and the state, holding the tools refused.
  defp offer(state, offered) do
    changed = Enum.reject(offered, &(Map.get(state.tools, &1.name) == definition_key(&1)))

    refused =
      state.registry
      |> register(changed)
      |> note_refused(state.session_id, state.name_collisions)

    registered = Enum.reject(changed, &Map.has_key?(refused, &1.name))
    tools = Enum.reduce(registered, state.tools, &Map.put(&2, &1.name, definition_key(&1)))
    {registered != [], %{state | tools: tools, name_collisions: refused}}
  end

  # What the client lists for a tool, as a provider and a 32-bit hash of the
  # listed definition (the meta-tool has no provider), so the set keeps no
  # second copy of every schema. Two definitions of one name that hash alike
  # (about 1 in 2^32 per change) leave the earlier one registered: its
  # description, schema and annotations, `sensitive` included, stay as they
  # were until another change, while calls still act on the live widget.
  defp definition_key(tool) do
    definition = {tool.description, tool.inputSchema, Map.get(tool, :annotations)}
    {Map.get(tool, :provider), :erlang.phash2(definition, 4_294_967_296)}
  end

  # The session's `discover_tools` meta-tool, or none for a session whose id
  # names no tools (`TreeWalker.id?/1`).
  defp discover_tool(state) do
    if TreeWalker.id?(state.session_id),
      do: [FocusLens.discover_tools_spec(state.registry, state.session_id)],
      else: []
  end

  # OMP prefixes `mcp__<server>_` to a tool's sanitized name, `<server>` being
  # the sanitized server key: `raxol_raxol` for the `raxol:raxol` plugin key
  # `docs/features/MCP.md` recommends. Past 64 characters it shows the first
  # 55, `_` and an 8-character hash instead, so the end of the name, the
  # action that tells a widget's tools apart, is what a reader loses.
  @omp_prefix "mcp__raxol_raxol_"
  @omp_name_limit 64

  # Each refusal TreeWalker reports, and each name OMP would show hashed, is
  # warned about on the first render that derives it, not again while it
  # stays or when it leaves the view and comes back (a modal, a conditional
  # widget), unless @max_warned more recently derived ones pushed it out.
  defp derive_tools(view_tree, state) do
    {tools, refusals} = TreeWalker.derive_with_refusals(view_tree, tool_context(state))

    long_names =
      for %{name: name} <- tools,
          String.length(omp_visible_name(name)) > @omp_name_limit,
          uniq: true,
          do: {:long_name, name}

    derived = Enum.map(refusals, &{:refusal, &1}) ++ long_names

    derived
    |> Enum.reject(&Map.has_key?(state.warned, &1))
    |> Enum.each(&warn(&1, state.session_id))

    {tools, remember_warned(state, derived)}
  end

  defp warn({:refusal, refusal}, _session_id), do: TreeWalker.warn_refusal(refusal)
  defp warn({:long_name, name}, session_id), do: warn_long_name(name, session_id)

  # Bounds `warned` for a view with per-item ids, which derives new refusals
  # or long names on every render; what this render derived is the most
  # recent, so it is the last to go.
  @max_warned 256

  defp remember_warned(state, derived) do
    render = state.renders + 1
    warned = Enum.reduce(derived, state.warned, &Map.put(&2, &1, render))
    %{state | warned: drop_oldest(warned), renders: render}
  end

  defp drop_oldest(warned) when map_size(warned) <= @max_warned, do: warned

  defp drop_oldest(warned) do
    warned
    |> Enum.sort_by(fn {_derived, render} -> render end, :desc)
    |> Enum.take(@max_warned)
    |> Map.new()
  end

  defp omp_visible_name(name), do: @omp_prefix <> Registry.omp_name(name)

  defp warn_long_name(name, session_id) do
    visible = omp_visible_name(name)

    Logger.warning(
      "[MCP.ToolSynchronizer] Session #{inspect(session_id)}: tool #{inspect(name)} " <>
        "reaches OMP as #{visible} (#{String.length(visible)} characters), past " <>
        "OMP's #{@omp_name_limit}, so OMP lists it under a truncated, hashed name; " <>
        "a shorter session or widget id keeps it readable"
    )
  end

  defp tool_context(%{app_module: nil} = state) do
    %{dispatcher_pid: state.dispatcher_pid, session_id: state.session_id}
  end

  # Calls resolve their widget from the app's view of the current model, and
  # a call that dispatched messages syncs this process before it answers.
  defp tool_context(state) do
    %{dispatcher_pid: dispatcher_pid, app_module: app_module, session_id: session_id} = state
    synchronizer = self()

    %{
      dispatcher_pid: dispatcher_pid,
      session_id: session_id,
      view: fn -> current_view(dispatcher_pid, app_module) end,
      synced: fn -> sync_after_write(synchronizer, session_id) end
    }
  end

  defp current_view(dispatcher_pid, app_module) do
    with {:ok, model} <- GenServer.call(dispatcher_pid, :get_model),
         do: {:ok, app_module.view(model)}
  end

  # The call's messages have reached update/2 by now, so its answer stands
  # whether or not the tool set can follow: a session stopping meanwhile
  # takes its tool set with it.
  defp sync_after_write(synchronizer, session_id) do
    GenServer.call(synchronizer, :sync_view)
  catch
    :exit, reason ->
      Logger.warning(
        "[MCP.ToolSynchronizer] Session #{inspect(session_id)}: tool set not synced after a call: " <>
          Exception.format_exit(reason)
      )
  end

  defp notify_tools_changed(state) do
    server_notify(state.server, "notifications/tools/list_changed", %{})
  end

  # Answers the registry's refusals as `{name, holder}`. A refused tool is not
  # the session's, so it is neither listed in its set nor unregistered with
  # it; the next sync offers it again. Every tool of a session, its meta-tool
  # included, comes and goes with it, so each is registered as derived.
  defp register(_registry, []), do: []

  defp register(registry, tools) do
    case Registry.register_tools(registry, tools, derived: true, owner: self()) do
      :ok -> []
      {:error, {:name_collision, collisions}} -> collisions
    end
  end

  # Answers the refused tools, name => holder. They are logged only when they
  # differ from the last sync's: a refused tool is offered and refused again
  # on every sync for as long as it stays on screen.
  defp note_refused(collisions, session_id, previous) do
    refused = Map.new(collisions)

    if collisions != [] and refused != previous do
      Logger.warning(
        "[MCP.ToolSynchronizer] Session #{inspect(session_id)}: refused " <>
          Enum.map_join(collisions, ", ", fn {name, holder} ->
            "#{inspect(name)} (its client-side name is taken by #{inspect(holder)})"
          end)
      )
    end

    refused
  end

  # -- Private: model resources --

  defp sync_model_resources(nil, state), do: state

  defp sync_model_resources(model, state) do
    projections = session_projections(state)

    if projections == [] do
      state
    else
      new_projection_values =
        projections
        |> Enum.reduce(%{}, fn {key, proj_fn}, acc ->
          try do
            Map.put(acc, key, proj_fn.(model))
          rescue
            e ->
              Logger.warning(
                "[MCP.ToolSynchronizer] Projection #{inspect(key)} failed: #{Exception.message(e)}"
              )

              acc
          end
        end)

      diff = Diff.diff(state.previous_projections, new_projection_values)

      if Diff.changed?(diff) do
        # Unregister resources for removed projections
        removed_uris =
          Enum.map(diff.removed, fn key -> model_uri(state.session_id, key) end)

        if removed_uris != [] do
          Registry.unregister_resources(state.registry, removed_uris)
        end

        # Re-register resources with updated callbacks
        resources =
          Enum.map(new_projection_values, fn {key, value} ->
            uri = model_uri(state.session_id, key)

            %{
              uri: uri,
              name: "Model: #{key}",
              description: "Model projection '#{key}' for session #{state.session_id}",
              callback: fn -> {:ok, value} end
            }
          end)

        if resources != [] do
          Registry.register_resources(state.registry, resources, owner: self())
        end

        new_uris = Enum.map(resources, & &1.uri) |> MapSet.new()
        removed_uri_set = MapSet.new(removed_uris)

        updated_resource_uris =
          state.current_resource_uris
          |> MapSet.difference(removed_uri_set)
          |> MapSet.union(new_uris)

        server_notify(state.server, "notifications/raxol/model_changed", %{
          session_id: state.session_id,
          changed_keys: Map.keys(diff.changed),
          added_keys: Map.keys(diff.added),
          removed_keys: diff.removed
        })

        %{
          state
          | previous_projections: new_projection_values,
            current_resource_uris: updated_resource_uris
        }
      else
        state
      end
    end
  end

  # A session id that names no tools names no resources either.
  defp session_projections(state) do
    if TreeWalker.id?(state.session_id), do: get_projections(state.app_module), else: []
  end

  defp get_projections(nil), do: []

  defp get_projections(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :mcp_resources, 0) do
      try do
        module.mcp_resources()
      rescue
        e ->
          Logger.warning(
            "[MCP.ToolSynchronizer] #{inspect(module)}.mcp_resources/0 raised: #{Exception.message(e)}"
          )

          []
      end
    else
      []
    end
  end

  # -- Private: session resources --

  defp register_session_resources(state) do
    session_id = state.session_id
    registry = state.registry

    [context_uri, widgets_uri] = session_resource_uris(session_id)

    self_pid = self()

    resources = [
      %{
        uri: context_uri,
        name: "Context Tree",
        description: "Full context tree for session #{session_id}",
        callback: fn ->
          sync_state = :sys.get_state(self_pid)

          ctx = %{
            registry: registry,
            session_id: session_id,
            view_tree: sync_state.current_view_tree,
            model: sync_state.current_model
          }

          {:ok, ContextTree.build_all(ctx)}
        end
      },
      %{
        uri: widgets_uri,
        name: "Widget Tree",
        description: "Current widget tree for session #{session_id}",
        callback: fn ->
          sync_state = :sys.get_state(self_pid)
          tree = sync_state.current_view_tree

          {:ok, StructuredScreenshot.from_view_tree(tree)}
        end
      }
    ]

    Registry.register_resources(registry, resources, owner: self())
    MapSet.new([context_uri, widgets_uri])
  end

  defp session_resource_uris(session_id),
    do: ["raxol://session/#{session_id}/context", "raxol://session/#{session_id}/widgets"]

  # Undoes what `register_session/1` registers, sent and not awaited: the
  # registry may be the process that stopped answering. Each request comes
  # from this process, so it queues behind the registration it undoes, the
  # one that timed out included, and is queued before the start is answered,
  # ahead of this process's exit signal. Owner-scoped, so a name or URI
  # another owner holds stays. The registry drops anything else this owner
  # held (tools of an initial view whose registration timed out) when it
  # sees the exit. `{:unregister_tools, names, owner}` and
  # `{:unregister_resources, uris, owner}` are `Registry.unregister_tools/3`'s
  # and `Registry.unregister_resources/3`'s requests. An id outside the rule
  # registered nothing.
  defp withdraw_session(state) do
    if TreeWalker.id?(state.session_id) do
      names = state |> discover_tool() |> Enum.map(& &1.name)
      _ = :gen_server.send_request(state.registry, {:unregister_tools, names, self()})
      uris = session_resource_uris(state.session_id)
      _ = :gen_server.send_request(state.registry, {:unregister_resources, uris, self()})
    end

    :ok
  end

  defp emit_behavior_event(event_type, data, telemetry_event) do
    if Code.ensure_loaded?(Raxol.Adaptive.BehaviorTracker) and
         function_exported?(Raxol.Adaptive.BehaviorTracker, :record, 3) do
      try do
        Raxol.Adaptive.BehaviorTracker.record(
          Raxol.Adaptive.BehaviorTracker,
          event_type,
          data
        )
      catch
        :exit, _ -> :ok
      end
    end

    :telemetry.execute(
      [:raxol, :mcp, telemetry_event],
      %{},
      Map.put(data, :type, event_type)
    )
  end

  defp model_uri(session_id, key), do: "raxol://session/#{session_id}/model/#{key}"

  defp server_notify(server, method, params) do
    Raxol.MCP.Server.notify(server, method, params)
  catch
    :exit, _ -> :ok
  end
end
