defmodule Raxol.MCP.ToolSynchronizer do
  @moduledoc """
  Per-session GenServer that bridges the render pipeline to the MCP Registry.

  Listens for `[:raxol, :runtime, :view_tree_updated]` telemetry events,
  derives tools from the view tree via `TreeWalker`, diffs against the
  previously registered set, and updates the Registry. Debounces rapid
  renders (50ms) to avoid thrashing.

  Also manages model-projected resources when the app implements
  `Raxol.MCP.ResourceProvider`, and registers context tree + widget tree
  resources for the session.

  Started by `Raxol.Headless` when creating a session. Linked to the
  session lifecycle -- dies when the session dies, cleaning up its tools.

  ## Usage

      {:ok, pid} = ToolSynchronizer.start_link(
        registry: Raxol.MCP.Registry,
        dispatcher_pid: dispatcher_pid,
        session_id: :my_session,
        app_module: MyApp
      )
  """

  use Raxol.Core.Behaviours.BaseManager

  require Logger

  @compile {:no_warn_undefined, [Raxol.Adaptive.BehaviorTracker]}

  alias Raxol.MCP.{ContextTree, Diff, FocusLens, Registry, StructuredScreenshot, TreeWalker}

  @debounce_ms 50

  defstruct [
    :registry,
    :dispatcher_pid,
    :session_id,
    :app_module,
    :telemetry_handler_id,
    :debounce_ref,
    current_tool_names: MapSet.new(),
    current_resource_uris: MapSet.new(),
    current_view_tree: nil,
    current_model: nil,
    previous_projections: %{},
    pending_view_tree: nil,
    pending_model: nil,
    focused_id: nil,
    hover_id: nil
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
  Update the focused widget ID for FocusLens filtering.

  When a widget gains focus (keyboard or mouse click), call this to
  adjust which tools are exposed via `FocusLens`.
  """
  @spec update_focus(GenServer.server(), String.t() | nil) :: :ok
  def update_focus(synchronizer, widget_id) do
    GenServer.cast(synchronizer, {:focus_changed, widget_id})
  end

  @doc """
  Update the hovered widget ID for anticipatory tool exposure.

  When the mouse hovers over a widget, call this so `FocusLens`
  can pre-expose that widget's tools alongside the focused widget's.
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

    # Register the discover_tools meta-tool
    discover_tool = FocusLens.discover_tools_spec(registry)
    Registry.register_tools(registry, [discover_tool])

    state = %__MODULE__{
      registry: registry,
      dispatcher_pid: dispatcher_pid,
      session_id: session_id,
      app_module: app_module,
      telemetry_handler_id: handler_id,
      current_tool_names: MapSet.new(["discover_tools"])
    }

    # Register session-level resources (context tree, widget tree)
    resource_uris = register_session_resources(state)

    {:ok, %{state | current_resource_uris: resource_uris}}
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
      emit_behavior_event(:pane_focus, %{widget_id: widget_id, source: :keyboard})
      {:noreply, %{state | focused_id: widget_id}}
    else
      {:noreply, state}
    end
  end

  def handle_manager_cast({:hover_changed, widget_id}, state) do
    if widget_id != state.hover_id do
      emit_behavior_event(:pane_focus, %{widget_id: widget_id, source: :mouse})
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

  # -- Private: sync --

  defp do_sync(view_tree, model, state) do
    context = %{
      dispatcher_pid: state.dispatcher_pid,
      session_id: state.session_id
    }

    # Tool sync (existing behavior)
    new_tools = TreeWalker.derive_tools(view_tree, context)
    new_tool_names = MapSet.new(Enum.map(new_tools, & &1.name))
    new_tool_names = MapSet.put(new_tool_names, "discover_tools")

    removed = MapSet.difference(state.current_tool_names, new_tool_names)
    added_tools = Enum.filter(new_tools, &(not MapSet.member?(state.current_tool_names, &1.name)))
    tools_changed? = MapSet.size(removed) > 0 or added_tools != []

    if MapSet.size(removed) > 0 do
      Registry.unregister_tools(state.registry, MapSet.to_list(removed))
    end

    if added_tools != [] do
      Registry.register_tools(state.registry, added_tools)
    end

    if tools_changed? do
      server_notify("notifications/tools/list_changed", %{})
    end

    # Resource sync (model projections)
    state = sync_model_resources(model, state)

    %{
      state
      | current_tool_names: new_tool_names,
        current_view_tree: view_tree,
        current_model: model
    }
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
              Logger.warning("[MCP.ToolSynchronizer] Projection #{inspect(key)} failed: #{Exception.message(e)}")
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
        _ -> []
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

  defp emit_behavior_event(event_type, data) do
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
      [:raxol, :mcp, :focus_changed],
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
