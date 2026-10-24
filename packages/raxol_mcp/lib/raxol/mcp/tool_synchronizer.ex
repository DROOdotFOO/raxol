defmodule Raxol.MCP.ToolSynchronizer do
  @moduledoc """
  Per-session GenServer that bridges the render pipeline to the MCP Registry.

  When an app module is provided, pulls the current model and derives its
  initial tools synchronously before startup returns. Subsequent
  `[:raxol, :runtime, :view_tree_updated]` telemetry events refresh tools from
  the rendered view tree. Rapid renders are debounced for 50ms.

  Also manages model-projected resources when the app implements
  `Raxol.MCP.ResourceProvider`, and registers context tree + widget tree
  resources for the session.

  Started by `Raxol.Headless` when creating a session. Linked to the
  session lifecycle -- dies when the session dies, cleaning up its tools.

  Every tool it registers is named under the session id: derived tools are
  `"session_id.widget_id.action"` and the meta-tool is
  `"session_id.discover_tools"`, so sessions rendering the same widget never
  share a tool. A tool `Raxol.MCP.Registry` refuses (its client-side name is
  already taken) is left out of the session's set and offered again on the
  next sync; the refusals are logged when they change, not on every sync.

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

  @debounce_ms 50

  # Below `GenServer.call/2`'s default 5 s, so a flush whose sender does not
  # answer still answers its caller.
  @flush_sender_timeout_ms 4_000

  defstruct [
    :registry,
    :dispatcher_pid,
    :session_id,
    :app_module,
    :telemetry_handler_id,
    :debounce_ref,
    current_tool_names: MapSet.new(),
    refused_tool_names: MapSet.new(),
    current_resource_uris: MapSet.new(),
    current_view_tree: nil,
    current_model: nil,
    previous_projections: %{},
    pending_view_tree: nil,
    pending_model: nil,
    focused_id: nil,
    hover_id: nil,
    # What `TreeWalker` refused on the last render (see
    # `TreeWalker.derive_with_refusals/2`). Only that render's are kept, so a
    # view with per-item ids does not grow it.
    refusals: MapSet.new()
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

  A barrier: once `flush/2` returns, the session's tool set (the tool names)
  matches the last view tree that reached this process. Messages from one
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
  Update the focused widget ID for FocusLens filtering.

  When a widget gains focus (keyboard or mouse click), call this to
  adjust which tools are exposed via `FocusLens`.

  Emits `:pane_focus` behavior data with the focused ID in `:pane_id`, plus
  `[:raxol, :mcp, :focus_changed]` telemetry.
  """
  @spec update_focus(GenServer.server(), String.t() | nil) :: :ok
  def update_focus(synchronizer, widget_id) do
    GenServer.cast(synchronizer, {:focus_changed, widget_id})
  end

  @doc """
  Update the hovered widget ID for anticipatory tool exposure.

  When the mouse hovers over a widget, call this so `FocusLens`
  can pre-expose that widget's tools alongside the focused widget's.

  Hover emits a separate `:widget_hover` behavior event and
  `[:raxol, :mcp, :hover_changed]` telemetry; it does not change adaptive
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

    handler_id = "tool_sync_#{session_id}_#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:raxol, :runtime, :view_tree_updated],
      &__MODULE__.handle_telemetry_event/4,
      %{synchronizer: self(), dispatcher_pid: dispatcher_pid}
    )

    # Register the session's discover_tools meta-tool
    discover_tool = FocusLens.discover_tools_spec(registry, session_id)
    refused = registry |> register([discover_tool]) |> note_refused(session_id, MapSet.new())

    state = %__MODULE__{
      registry: registry,
      dispatcher_pid: dispatcher_pid,
      session_id: session_id,
      app_module: app_module,
      telemetry_handler_id: handler_id,
      current_tool_names: MapSet.difference(MapSet.new([discover_tool.name]), refused),
      refused_tool_names: refused
    }

    # Register session-level resources (context tree, widget tree)
    resource_uris = register_session_resources(state)
    state = %{state | current_resource_uris: resource_uris}

    # Seed tools synchronously so callers never observe a meta-tool-only
    # session when the engine's first render preceded telemetry attachment.
    {:ok, sync_initial_view(state)}
  end

  @impl Raxol.Core.Behaviours.BaseManager
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

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_cast({:view_tree_updated, view_tree, model}, state) do
    # Debounce: cancel previous timer, start new one
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)

    ref = Process.send_after(self(), :debounce_fire, @debounce_ms)
    {:noreply, %{state | pending_view_tree: view_tree, pending_model: model, debounce_ref: ref}}
  end

  def handle_manager_cast({:view_tree_updated, view_tree}, state) do
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)

    ref = Process.send_after(self(), :debounce_fire, @debounce_ms)
    {:noreply, %{state | pending_view_tree: view_tree, debounce_ref: ref}}
  end

  def handle_manager_cast({:sync_now, view_tree}, state) do
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)
    new_state = do_sync(view_tree, state.pending_model || state.current_model, state)
    {:noreply, %{new_state | debounce_ref: nil, pending_view_tree: nil, pending_model: nil}}
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
    new_state =
      do_sync(state.pending_view_tree, state.pending_model || state.current_model, state)

    {:noreply, %{new_state | debounce_ref: nil, pending_view_tree: nil, pending_model: nil}}
  end

  def handle_manager_info({:flush_reply, from}, state) do
    state = apply_pending(state)
    GenServer.reply(from, :ok)
    {:noreply, state}
  end

  def handle_manager_info(_msg, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    :telemetry.detach(state.telemetry_handler_id)

    # Clean up all tools registered by this session
    names = MapSet.to_list(state.current_tool_names)

    if names != [] do
      try do
        Registry.unregister_tools(state.registry, names)
      catch
        :exit, _ -> :ok
      end
    end

    # Clean up resources
    uris = MapSet.to_list(state.current_resource_uris)

    if uris != [] do
      try do
        Registry.unregister_resources(state.registry, uris)
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
    if state.debounce_ref, do: Process.cancel_timer(state.debounce_ref)

    new_state =
      do_sync(state.pending_view_tree, state.pending_model || state.current_model, state)

    %{new_state | debounce_ref: nil, pending_view_tree: nil, pending_model: nil}
  end

  # -- Private: sync --

  defp sync_initial_view(%{app_module: nil} = state), do: state

  defp sync_initial_view(state) do
    case GenServer.call(state.dispatcher_pid, :get_model) do
      {:ok, model} ->
        case state.app_module.view(model) do
          nil -> state
          view_tree -> do_sync(view_tree, model, state)
        end

      {:error, reason} ->
        Logger.warning(
          "[MCP.ToolSynchronizer] Initial model pull failed for #{inspect(state.session_id)}: #{inspect(reason)}"
        )

        state
    end
  rescue
    exception ->
      Logger.warning(
        "[MCP.ToolSynchronizer] Initial view sync failed for #{inspect(state.session_id)}: #{Exception.message(exception)}"
      )

      state
  catch
    kind, reason ->
      Logger.warning(
        "[MCP.ToolSynchronizer] Initial view sync failed for #{inspect(state.session_id)}: #{inspect({kind, reason})}"
      )

      state
  end

  defp do_sync(view_tree, model, state) do
    # Tool sync (existing behavior)
    {current_tool_names, state} = sync_tools(view_tree, state)

    # Resource sync (model projections)
    state = sync_model_resources(model, state)

    %{
      state
      | current_tool_names: current_tool_names,
        current_view_tree: view_tree,
        current_model: model
    }
  end

  # Answers the session's tool names after the sync, and the state, holding
  # the names refused.
  defp sync_tools(view_tree, state) do
    {new_tools, state} = derive_tools(view_tree, state)

    new_tool_names =
      new_tools
      |> MapSet.new(& &1.name)
      |> MapSet.put(FocusLens.discover_tools_name(state.session_id))

    removed = MapSet.difference(state.current_tool_names, new_tool_names)
    added_tools = Enum.filter(new_tools, &(not MapSet.member?(state.current_tool_names, &1.name)))
    {added_names, refused} = apply_tool_changes(state, removed, added_tools)

    current = state.current_tool_names |> MapSet.difference(removed) |> MapSet.union(added_names)
    {current, %{state | refused_tool_names: refused}}
  end

  # A refusal TreeWalker reports is warned about on the render it appears in,
  # not on every render that keeps it; one that leaves the view and comes
  # back is warned about again.
  defp derive_tools(view_tree, state) do
    context = %{dispatcher_pid: state.dispatcher_pid, session_id: state.session_id}
    {tools, refusals} = TreeWalker.derive_with_refusals(view_tree, context)
    Enum.each(MapSet.difference(refusals, state.refusals), &TreeWalker.warn_refusal/1)
    {tools, %{state | refusals: refusals}}
  end

  # Answers the names of the added tools the registry took, and of those it
  # refused.
  defp apply_tool_changes(state, removed, added_tools) do
    if MapSet.size(removed) > 0 do
      Registry.unregister_tools(state.registry, MapSet.to_list(removed))
    end

    refused =
      state.registry
      |> register(added_tools)
      |> note_refused(state.session_id, state.refused_tool_names)

    added_names = added_tools |> MapSet.new(& &1.name) |> MapSet.difference(refused)

    if MapSet.size(removed) > 0 or MapSet.size(added_names) > 0 do
      server_notify("notifications/tools/list_changed", %{})
    end

    {added_names, refused}
  end

  # Answers the registry's refusals as `{name, holder}`. A refused tool is not
  # the session's, so it is neither listed in its set nor unregistered with
  # it; the next sync offers it again. Every tool of a session, its meta-tool
  # included, comes and goes with it, so each is registered as derived.
  defp register(_registry, []), do: []

  defp register(registry, tools) do
    case Registry.register_tools(registry, tools, derived: true) do
      :ok -> []
      {:error, {:name_collision, collisions}} -> collisions
    end
  end

  # Answers the refused names. They are logged only when they differ from
  # the last sync's: a refused tool is offered and refused again on every
  # sync for as long as it stays on screen.
  defp note_refused(collisions, session_id, previous) do
    refused = MapSet.new(collisions, fn {name, _holder} -> name end)

    if collisions != [] and not MapSet.equal?(refused, previous) do
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
    projections = get_projections(state.app_module)

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
          Registry.register_resources(state.registry, resources)
        end

        new_uris = Enum.map(resources, & &1.uri) |> MapSet.new()
        removed_uri_set = MapSet.new(removed_uris)

        updated_resource_uris =
          state.current_resource_uris
          |> MapSet.difference(removed_uri_set)
          |> MapSet.union(new_uris)

        server_notify("notifications/raxol/model_changed", %{
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

    context_uri = "raxol://session/#{session_id}/context"
    widgets_uri = "raxol://session/#{session_id}/widgets"

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

    Registry.register_resources(registry, resources)
    MapSet.new([context_uri, widgets_uri])
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

  defp server_notify(method, params) do
    if Code.ensure_loaded?(Raxol.MCP.Server) and
         function_exported?(Raxol.MCP.Server, :notify, 3) do
      try do
        Raxol.MCP.Server.notify(Raxol.MCP.Server, method, params)
      catch
        :exit, _ -> :ok
      end
    end
  end
end
