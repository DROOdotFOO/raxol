defmodule Raxol.Core.Runtime.Rendering.Engine do
  @moduledoc """
  Provides the core rendering functionality for Raxol applications with functional error handling.

  This module is responsible for:
  * Rendering application views into screen buffers
  * Managing the rendering lifecycle
  * Coordinating with the output backends

  REFACTORED: All try/catch blocks replaced with functional error handling patterns.
  """

  use GenServer

  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Terminal.ScreenBuffer
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Renderer, as: UIRenderer
  alias Raxol.UI.Theming.Theme

  defmodule State do
    @moduledoc false
    defstruct app_module: nil,
              dispatcher_pid: nil,
              width: 80,
              height: 24,
              # Screen buffer
              buffer: nil,
              # Default rendering target
              environment: :terminal,
              # For VSCode, etc.
              stdio_interface_pid: nil,
              # PubSub topic for LiveView rendering
              liveview_topic: nil,
              # Writer function for SSH rendering
              io_writer: nil,
              # Registry of running process components {id => pid}
              process_components: %{},
              # Whether terminal supports Mode 2026 synchronized output
              sync_output: false,
              # Cycle profiler pid (nil when disabled)
              cycle_profiler: nil,
              # Cached prepared element tree (Pretext-inspired two-phase)
              prepared_tree: nil,
              # Force the next terminal frame to be a full keyframe (first frame,
              # resize, or Ctrl-L recovery). Set true so the first render always
              # paints a full frame; the terminal backend clears it after one frame.
              force_repaint: true
  end

  # --- Public API ---

  @doc "Starts the Rendering Engine process."
  # Support both map and list initialization
  def start_link(opts \\ [])

  def start_link(initial_state_map) when is_map(initial_state_map) do
    # Convert map to keyword list and add name option
    opts = [{:name, __MODULE__} | Map.to_list(initial_state_map)]
    start_link(opts)
  end

  def start_link(opts) when is_list(opts) do
    {server_opts, manager_opts} = normalize_and_split_opts(opts)
    GenServer.start_link(__MODULE__, manager_opts, server_opts)
  end

  defp normalize_and_split_opts(opts),
    do: Raxol.Core.Utils.GenServerHelpers.split_server_opts(opts)

  # --- BaseManager Callbacks ---

  # Default BaseManager init implementation
  @impl true
  def init(initial_state_map) do
    Raxol.Core.Runtime.Log.info("Rendering Engine initializing...")

    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine init state map: #{inspect(initial_state_map)}"
    )

    state = struct!(State, initial_state_map)
    # Initialize buffer with initial dimensions
    initial_buffer = ScreenBuffer.new(state.width, state.height)

    sync_supported =
      state.environment == :terminal and
        Raxol.Terminal.AdvancedFeatures.supports_synchronized_output?()

    new_state = %{state | buffer: initial_buffer, sync_output: sync_supported}

    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine init completed for #{inspect(new_state.app_module)}, buffer #{new_state.buffer.width}x#{new_state.buffer.height}"
    )

    {:ok, new_state}
  end

  @impl true
  def handle_cast(:render_frame, state) do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine received :render_frame for #{inspect(state.app_module)}"
    )

    # Fetch the latest model AND theme context from the Dispatcher
    case GenServer.call(state.dispatcher_pid, :get_render_context) do
      {:ok, %{model: current_model, theme_id: current_theme_id}} ->
        Raxol.Core.Runtime.Log.debug(
          "Rendering Engine got render context: Model=#{inspect(current_model)}, Theme=#{inspect(current_theme_id)}"
        )

        # Apply active animations to the model before rendering.
        # This injects interpolated values (opacity, color, etc.) into
        # model.elements so view/1 reads animated state naturally.
        # Falls back to unmodified model if animation system isn't running.
        animated_model =
          try do
            Raxol.Animation.Framework.apply_animations_to_state(current_model)
          catch
            :exit, _ -> current_model
          end

        # Fetch the actual theme struct using the ID
        theme =
          Theme.get(current_theme_id) || Theme.get(Theme.default_theme_id())

        case do_render_frame(animated_model, theme, state) do
          {:ok, new_state} ->
            {:noreply, new_state}

          {:error, _reason, current_state} ->
            # Logged inside do_render_frame, just keep current state
            {:noreply, current_state}
        end

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error(
          "RenderingEngine failed to get render context from Dispatcher: #{inspect(reason)}"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:update_size, %{width: w, height: h}}, state) do
    Raxol.Core.Runtime.Log.debug(
      "RenderingEngine received size update: #{w}x#{h}"
    )

    new_state = %{state | width: w, height: h}

    # Resize owns the keyframe. This handler swaps in a fresh blank buffer of the
    # new size, so by render time dims already match and a render-time dims check
    # can't fire -- and diffing against the blank would leave stale pre-resize
    # rows unpainted. Force a full repaint instead.
    resized_buffer = ScreenBuffer.new(w, h)
    {:noreply, %{new_state | buffer: resized_buffer, force_repaint: true}}
  end

  @impl true
  def handle_cast(:force_repaint, state) do
    {:noreply, %{state | force_repaint: true}}
  end

  @impl true
  def handle_call({:update_props, _new_props}, _from, state) do
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_state}, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_call(:render_frame_sync, _from, state) do
    case GenServer.call(state.dispatcher_pid, :get_render_context) do
      {:ok, %{model: current_model, theme_id: current_theme_id}} ->
        animated_model =
          try do
            Raxol.Animation.Framework.apply_animations_to_state(current_model)
          catch
            :exit, _ -> current_model
          end

        theme =
          Theme.get(current_theme_id) || Theme.get(Theme.default_theme_id())

        case do_render_frame(animated_model, theme, state) do
          {:ok, new_state} ->
            {:reply, :ok, new_state}

          {:error, _reason, current_state} ->
            {:reply, {:error, :render_failed}, current_state}
        end

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call(:get_buffer, _from, state) do
    {:reply, {:ok, state.buffer}, state}
  end

  # --- Private Helpers ---

  # Functional rendering pipeline replacing try/catch
  defp do_render_frame(model, theme, state) do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine do_render_frame for #{inspect(state.app_module)}, theme=#{inspect(Map.get(theme, :id))}"
    )

    case prepare_view_tree(model, state) do
      {:nil_view} ->
        {:ok, state}

      {:ok, view, prepared_tree, t0, t1, mem_before} ->
        render_prepared_view(
          view,
          prepared_tree,
          t0,
          t1,
          mem_before,
          theme,
          state
        )

      {:error, reason} ->
        log_render_error(reason, state)
    end
  end

  defp prepare_view_tree(model, state) do
    mem_before = profiler_memory(state.cycle_profiler)
    t0 = profiler_now(state.cycle_profiler)

    with {:ok, view} <- safe_get_view(state.app_module, model),
         false <- is_nil(view) do
      prepared_tree =
        Raxol.UI.Layout.Preparer.prepare_incremental(view, state.prepared_tree)

      t1 = profiler_now(state.cycle_profiler)
      {:ok, view, prepared_tree, t0, t1, mem_before}
    else
      true -> {:nil_view}
      {:error, reason} -> {:error, reason}
    end
  end

  defp render_prepared_view(
         view,
         prepared_tree,
         t0,
         t1,
         mem_before,
         theme,
         state
       ) do
    with {:ok, positioned_elements} <-
           safe_apply_layout(view, state, prepared_tree),
         t2 <- profiler_now(state.cycle_profiler),
         :ok <- sync_dispatcher(state.dispatcher_pid, view, positioned_elements),
         :continue <- agent_short_circuit(state),
         {:ok, new_state, t5} <-
           render_cells_to_backend(positioned_elements, theme, state, view) do
      maybe_record_cycle_render(
        state.cycle_profiler,
        t0,
        t1,
        t2,
        t5,
        t5,
        t5,
        mem_before
      )

      {:ok, %{new_state | prepared_tree: prepared_tree}}
    else
      {:error, reason} -> log_render_error(reason, state)
    end
  end

  defp sync_dispatcher(dispatcher_pid, view, positioned_elements) do
    with :ok <- update_dispatcher_view_tree(dispatcher_pid, view),
         :ok <- update_dispatcher_layout(dispatcher_pid, positioned_elements) do
      :telemetry.execute(
        [:raxol, :runtime, :view_tree_updated],
        %{},
        %{view_tree: view, dispatcher_pid: dispatcher_pid}
      )

      :ok
    end
  end

  defp render_cells_to_backend(positioned_elements, theme, state, view) do
    with {:ok, cells} <- safe_render_to_cells(positioned_elements, theme),
         {:ok, final_cells} <- safe_apply_plugin_transforms(cells, state),
         {:ok, beamed_cells} <-
           safe_apply_border_beam(final_cells, positioned_elements),
         {:ok, new_state} <-
           safe_render_to_backend(
             beamed_cells,
             state,
             positioned_elements,
             view
           ) do
      t5 = profiler_now(state.cycle_profiler)
      {:ok, new_state, t5}
    end
  end

  defp safe_apply_border_beam(cells, positioned_elements) do
    hints_with_bounds = collect_border_beam_hints(positioned_elements)

    case hints_with_bounds do
      [] ->
        {:ok, cells}

      hints ->
        Raxol.Core.ErrorHandling.safe_call(fn ->
          {:ok, Raxol.Effects.BorderBeam.CellApplier.apply_hints(cells, hints)}
        end)
        |> case do
          {:ok, result} -> result
          {:error, _reason} -> {:ok, cells}
        end
    end
  end

  defp collect_border_beam_hints(elements) when is_list(elements) do
    Enum.flat_map(elements, &border_beam_hints_for/1)
  end

  defp border_beam_hints_for(%{
         animation_hints: hints,
         x: x,
         y: y,
         width: w,
         height: h
       })
       when is_list(hints) and is_integer(x) and is_integer(y) and w > 0 and
              h > 0 do
    bounds = %{x: x, y: y, width: w, height: h}

    hints
    |> Enum.filter(&match?(%{type: :border_beam}, &1))
    |> Enum.map(&{&1, bounds})
  end

  defp border_beam_hints_for(_), do: []

  defp log_render_error(reason, state) do
    Raxol.Core.Runtime.Log.error_with_stacktrace(
      "Render error",
      reason,
      nil,
      %{module: __MODULE__, state: state}
    )

    {:error, {:render_error, reason}, state}
  end

  # -- Cycle profiler hooks --

  defp profiler_now(nil), do: 0
  defp profiler_now(_pid), do: System.monotonic_time(:microsecond)

  defp profiler_memory(nil), do: 0

  defp profiler_memory(_pid) do
    {:memory, mem} = Process.info(self(), :memory)
    mem
  end

  defp maybe_record_cycle_render(nil, _t0, _t1, _t2, _t3, _t4, _t5, _mem_b),
    do: :ok

  defp maybe_record_cycle_render(pid, t0, t1, t2, t3, t4, t5, mem_before)
       when is_pid(pid) do
    if Process.alive?(pid) do
      {:memory, mem_after} = Process.info(self(), :memory)

      Raxol.Performance.CycleProfiler.record_render(pid, %{
        view_us: t1 - t0,
        layout_us: t2 - t1,
        render_us: t3 - t2,
        plugin_us: t4 - t3,
        backend_us: t5 - t4,
        total_us: t5 - t0,
        memory_before: mem_before,
        memory_after: mem_after
      })
    end
  end

  # Agent environment renders cells to buffer (no IO) so headless sessions
  # can capture screenshots. Previously this short-circuited and skipped cells.
  defp agent_short_circuit(_state), do: :continue

  # Safe view retrieval using functional error handling
  defp safe_get_view(app_module, model) do
    if function_exported?(app_module, :view, 1) do
      Raxol.Core.Runtime.Log.debug(
        "Rendering Engine: Calling app_module.view(model)"
      )

      call_view_safely(app_module, model)
    else
      {:ok, nil}
    end
  end

  defp call_view_safely(app_module, model) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      resolve_view_result(app_module.view(model))
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:view_error, reason}}
    end
  end

  defp resolve_view_result(nil), do: {:ok, nil}

  defp resolve_view_result(view) do
    resolved = resolve_process_components(view)

    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Got view: #{inspect(resolved)}"
    )

    {:ok, resolved}
  end

  # Safe layout application using functional error handling
  defp safe_apply_layout(view, state, prepared_tree) do
    dimensions = %{width: state.width, height: state.height}

    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Calculating layout with dimensions: #{inspect(dimensions)}"
    )

    Raxol.Core.ErrorHandling.safe_call(fn ->
      positioned_elements =
        LayoutEngine.apply_layout(view, dimensions, prepared_tree)

      Raxol.Core.Runtime.Log.debug(
        "Rendering Engine: Got positioned elements: #{inspect(positioned_elements)}"
      )

      {:ok, positioned_elements}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:layout_error, reason}}
    end
  end

  # Safe cell rendering using functional error handling
  defp safe_render_to_cells(positioned_elements, theme) do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Rendering to cells, theme=#{inspect(Map.get(theme, :id))}, #{length(positioned_elements)} elements"
    )

    Raxol.Core.ErrorHandling.safe_call(fn ->
      cells = UIRenderer.render_to_cells(positioned_elements, theme)

      Raxol.Core.Runtime.Log.debug(
        "Rendering Engine: Got #{length(cells)} cells"
      )

      {:ok, cells}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:cell_rendering_error, reason}}
    end
  end

  # Safe plugin transforms using functional error handling
  defp safe_apply_plugin_transforms(cells, state) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      processed_cells = apply_plugin_transforms(cells, state)
      {:ok, processed_cells}
    end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, {:plugin_transform_error, reason}}
    end
  end

  # Safe backend rendering -- dispatches to Backends module.
  # positioned_elements carries the element tree with animation hints
  # for surfaces that can use them (LiveView emits CSS transitions).
  # `view` is the declaration tree; the LiveView backend projects it into an
  # accessibility map so the Browser bridge can emit per-element ARIA. The map
  # is computed only for the LiveView environment so the terminal path pays
  # nothing.
  defp safe_render_to_backend(final_cells, state, positioned_elements, view) do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Sending final cells to backend: #{state.environment}"
    )

    case state.environment do
      :terminal ->
        Backends.render_to_terminal(final_cells, state)

      :vscode ->
        Backends.render_to_vscode(final_cells, state)

      :liveview ->
        a11y_map = Raxol.Core.Accessibility.Projection.by_id(view)

        Backends.render_to_liveview(
          final_cells,
          state,
          positioned_elements,
          a11y_map
        )

      :ssh ->
        Backends.render_to_ssh(final_cells, state)

      :telegram ->
        Backends.render_to_telegram(final_cells, state)

      :agent ->
        # Agent environment: buffer maintained for inspection, no output written
        updated_buffer = Backends.apply_cells_to_buffer(final_cells, state)
        {:ok, %{state | buffer: updated_buffer}}

      :inline ->
        # T2d: the inline driver profile has no renderer of its own yet --
        # T2b (printed-history append) and T2c (pinned viewport) own that
        # emit vocabulary. Until they land, buffer is maintained for
        # inspection only, mirroring :agent, so registering the atom here
        # doesn't silently fall into `:unknown_environment` below.
        updated_buffer = Backends.apply_cells_to_buffer(final_cells, state)
        {:ok, %{state | buffer: updated_buffer}}

      other ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "Unknown rendering environment",
          other,
          nil,
          %{module: __MODULE__, state: state}
        )

        {:error, :unknown_environment}
    end
  end

  # --- Process Component Resolution ---

  defp resolve_process_components(
         %{type: :process_component, module: mod, props: props} = node
       ) do
    id = Map.get(node, :id, "pc-#{inspect(mod)}")

    pid =
      case DynamicSupervisor.start_child(
             Raxol.DynamicSupervisor,
             {Raxol.Core.Runtime.ProcessComponent,
              [module: mod, props: props, id: id]}
           ) do
        {:ok, pid} -> pid
        {:error, {:already_started, pid}} -> pid
        _ -> nil
      end

    if pid do
      Raxol.Core.Runtime.ProcessComponent.get_render_tree(pid, %{})
    else
      %{type: :text, content: "[#{id}: failed to start]", style: %{}}
    end
  end

  defp resolve_process_components(%{children: children} = node)
       when is_list(children) do
    %{node | children: Enum.map(children, &resolve_process_components/1)}
  end

  defp resolve_process_components(node), do: node

  defp apply_plugin_transforms(cells, state) do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Applying plugin transforms to #{length(cells)} cells"
    )

    # Get the plugin manager from the dispatcher
    case get_plugin_manager_from_dispatcher(state.dispatcher_pid) do
      {:ok, %Raxol.Plugins.Manager{} = plugin_manager} ->
        # Create emulator state context for plugins
        emulator_state = %{
          width: state.width,
          height: state.height,
          environment: state.environment,
          buffer: state.buffer
        }

        # Process cells through plugins using CellProcessor
        {:ok, updated_manager, processed_cells, collected_commands} =
          Raxol.Plugins.CellProcessor.process(
            plugin_manager,
            cells,
            emulator_state
          )

        # Execute any collected commands (like escape sequences)
        execute_plugin_commands(collected_commands)

        # Update plugin manager state in dispatcher if needed
        _ =
          update_plugin_manager_in_dispatcher(
            state.dispatcher_pid,
            updated_manager
          )

        Raxol.Core.Runtime.Log.debug(
          "Rendering Engine: Plugin transforms applied. Processed cells: #{length(processed_cells)}, Commands: #{length(collected_commands)}"
        )

        processed_cells

      {:ok, _non_struct_manager} ->
        # Plugin manager is a PID or other non-struct value; skip cell processing
        Raxol.Core.Runtime.Log.debug(
          "Rendering Engine: Plugin manager is not a Manager struct, skipping cell processing"
        )

        cells

      {:error, reason} ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Rendering Engine: Could not get plugin manager for transforms",
          %{reason: reason, module: __MODULE__}
        )

        # Return original cells if plugin manager unavailable
        cells
    end
  end

  # Functional wrapper for dispatcher plugin manager retrieval
  defp get_plugin_manager_from_dispatcher(dispatcher_pid)
       when is_pid(dispatcher_pid) do
    with {:ok, response} <-
           safe_genserver_call(
             dispatcher_pid,
             :get_plugin_manager,
             Raxol.Core.Defaults.timeout_ms()
           ),
         {:ok, plugin_manager} <- validate_plugin_manager_response(response) do
      {:ok, plugin_manager}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_plugin_manager_from_dispatcher(_), do: {:error, :invalid_dispatcher}

  # Safe GenServer call wrapper using functional error handling
  defp safe_genserver_call(pid, message, timeout) do
    Raxol.Core.ErrorHandling.safe_call(fn ->
      GenServer.call(pid, message, timeout)
    end)
    |> case do
      {:ok, response} ->
        {:ok, response}

      {:error, reason} ->
        Raxol.Core.Runtime.Log.error_with_stacktrace(
          "Rendering Engine: Error getting plugin manager from dispatcher",
          reason,
          nil,
          %{dispatcher_pid: pid}
        )

        {:error, :dispatcher_error}
    end
  end

  # Validate plugin manager response
  defp validate_plugin_manager_response({:ok, plugin_manager}) do
    {:ok, plugin_manager}
  end

  defp validate_plugin_manager_response({:error, reason}) do
    {:error, reason}
  end

  defp validate_plugin_manager_response(_) do
    {:error, :unexpected_response}
  end

  # Helper function to execute plugin commands (like escape sequences)
  defp execute_plugin_commands(commands)
       when is_list(commands) and commands != [] do
    Raxol.Core.Runtime.Log.debug(
      "Rendering Engine: Executing #{length(commands)} plugin commands"
    )

    Enum.each(commands, fn
      command when is_binary(command) ->
        IO.write(command)

      command ->
        Raxol.Core.Runtime.Log.warning_with_context(
          "Rendering Engine: Unknown plugin command format",
          %{command: command}
        )
    end)
  end

  defp execute_plugin_commands(_), do: :ok

  # Send the view tree to Dispatcher for event bubbling
  defp update_dispatcher_view_tree(dispatcher_pid, view)
       when is_pid(dispatcher_pid) do
    GenServer.cast(dispatcher_pid, {:update_view_tree, view})
    :ok
  end

  defp update_dispatcher_view_tree(_, _), do: :ok

  # Send positioned elements to Dispatcher for mouse hit testing
  defp update_dispatcher_layout(dispatcher_pid, positioned_elements)
       when is_pid(dispatcher_pid) do
    GenServer.cast(dispatcher_pid, {:update_layout, positioned_elements})
    :ok
  end

  defp update_dispatcher_layout(_, _), do: :ok

  # Update plugin manager state in dispatcher
  defp update_plugin_manager_in_dispatcher(dispatcher_pid, updated_manager)
       when is_pid(dispatcher_pid) do
    GenServer.cast(dispatcher_pid, {:update_plugin_manager, updated_manager})
    :ok
  end
end
