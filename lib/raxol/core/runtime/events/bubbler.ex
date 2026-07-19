defmodule Raxol.Core.Runtime.Events.Bubbler do
  require Logger

  @moduledoc """
  Implements capture and bubbling event dispatch through the view tree.

  The full event flow follows the W3C model:

  1. **Capture phase** (root -> target): walks down from root, checking
     `:on_capture` handlers. A capture handler can intercept the event
     before it reaches the target.

  2. **Target + Bubble phase** (target -> root): the focused element and
     its ancestors get a chance to handle via inline handlers (`:on_click`,
     `:on_event`, `:on_change`) and component `handle_event/3`.
     `:passthrough` continues to the next ancestor.

  If no handler in either phase consumes the event, it falls through to
  the app-level `update/2`.
  """

  alias Raxol.Core.Events.Event

  @type element :: map()
  @type dispatch_result ::
          {:handled, term()}
          | {:commands, [term()]}
          | :passthrough

  @doc """
  Dispatches an event through the full capture + bubble cycle.

  Returns:
    - `{:handled, result}` if a handler consumed the event
    - `{:commands, commands}` if a handler returned commands
    - `:passthrough` if no handler consumed the event
  """
  @spec dispatch(Event.t(), element(), term(), map()) :: dispatch_result()
  def dispatch(%Event{} = event, view_tree, focused_id, context) do
    case find_ancestor_path(view_tree, focused_id) do
      nil ->
        :passthrough

      path ->
        # path is bottom-up: [target, parent, ..., root]
        capture_path = Enum.reverse(path)

        case run_capture_phase(event, capture_path, context) do
          :passthrough ->
            walk_path(event, path, context)

          result ->
            result
        end
    end
  end

  @doc """
  Attempts to bubble an event through the view tree starting at the focused element.
  Does NOT run the capture phase. Use `dispatch/4` for the full cycle.

  Returns:
    - `{:handled, result}` if a component consumed the event
    - `{:commands, commands}` if a component returned commands to process
    - `:passthrough` if no component handled the event
  """
  @spec bubble(Event.t(), element(), term(), map()) :: dispatch_result()
  def bubble(%Event{} = event, view_tree, focused_id, context) do
    case find_ancestor_path(view_tree, focused_id) do
      nil ->
        :passthrough

      path ->
        walk_path(event, path, context)
    end
  end

  @doc """
  Finds the path from the root to the target element (inclusive).
  Returns the path in bottom-up order (target first, root last) for bubbling.
  Returns nil if the element is not found.
  """
  @spec find_ancestor_path(element(), term()) :: [element()] | nil
  def find_ancestor_path(tree, target_id) do
    case do_find_path(tree, target_id) do
      nil -> nil
      path -> Enum.reverse(path)
    end
  end

  # --- Capture Phase ---

  # Walk top-down (root -> target), checking :on_capture handlers.
  # Excludes the target itself (capture is for ancestors only).
  defp run_capture_phase(_event, [], _context), do: :passthrough

  defp run_capture_phase(_event, [_target], _context), do: :passthrough

  defp run_capture_phase(event, capture_path, context) do
    # All elements except the last (target) participate in capture
    ancestors = Enum.drop(capture_path, -1)
    walk_capture(event, ancestors, context)
  end

  defp walk_capture(_event, [], _context), do: :passthrough

  defp walk_capture(event, [element | rest], context) do
    case try_capture_handler(event, element, context) do
      :passthrough ->
        walk_capture(event, rest, context)

      result ->
        result
    end
  end

  # Check for :on_capture handler on the element.
  # on_capture can be:
  #   - an atom/tuple message to send to app.update/2
  #   - a function/1 that receives the event and returns a result
  defp try_capture_handler(%Event{} = event, %{on_capture: handler}, _context)
       when is_function(handler, 1) do
    case handler.(event) do
      :passthrough -> :passthrough
      :halt -> {:handled, :ok}
      {:halt, message} -> {:handled, {:message, message}}
      _ -> :passthrough
    end
  rescue
    e ->
      Logger.debug("Capture handler raised: #{Exception.message(e)}")
      :passthrough
  end

  defp try_capture_handler(%Event{}, %{on_capture: handler}, _context)
       when not is_nil(handler) do
    {:handled, {:message, handler}}
  end

  defp try_capture_handler(_event, _element, _context), do: :passthrough

  # --- Path Finding ---

  # Returns path from root to target (root first) or nil
  defp do_find_path(%{id: id} = element, target_id) when id == target_id do
    [element]
  end

  defp do_find_path(%{children: children} = element, target_id)
       when is_list(children) do
    Enum.find_value(children, fn child ->
      case do_find_path(child, target_id) do
        nil -> nil
        path -> [element | path]
      end
    end)
  end

  # Single child (not wrapped in list)
  defp do_find_path(%{children: child} = element, target_id)
       when is_map(child) do
    case do_find_path(child, target_id) do
      nil -> nil
      path -> [element | path]
    end
  end

  defp do_find_path(_, _target_id), do: nil

  # --- Bubble Phase ---

  # Walk the ancestor path bottom-up, trying each element's handler
  defp walk_path(_event, [], _context), do: :passthrough

  defp walk_path(event, [element | rest], context) do
    case try_element_handler(event, element, context) do
      :passthrough ->
        walk_path(event, rest, context)

      result ->
        result
    end
  end

  # Try to handle an event at a specific element.
  # First checks inline handlers, then the component module.
  defp try_element_handler(event, element, context) do
    case try_inline_handler(event, element) do
      :passthrough ->
        try_component_handler(event, element, context)

      result ->
        result
    end
  end

  # Check inline event handlers on the element map
  defp try_inline_handler(%Event{type: :click}, %{on_click: handler})
       when not is_nil(handler) do
    {:handled, {:message, handler}}
  end

  defp try_inline_handler(%Event{type: :key, data: %{key: key}}, %{
         on_click: handler
       })
       when key in [:enter, :space] and not is_nil(handler) do
    {:handled, {:message, handler}}
  end

  defp try_inline_handler(%Event{type: type}, %{on_event: handler})
       when not is_nil(handler) do
    {:handled, {:message, {handler, type}}}
  end

  defp try_inline_handler(%Event{}, %{on_change: handler} = element)
       when not is_nil(handler) do
    value = Map.get(element, :value, Map.get(element, :content))
    {:handled, {:message, {handler, value}}}
  end

  defp try_inline_handler(_event, _element), do: :passthrough

  # Try the component module's handle_event/3 if the element maps to one
  defp try_component_handler(event, element, context) do
    case component_module(element) do
      nil ->
        :passthrough

      module ->
        state = component_state_from_element(element)
        dispatch_component_event(module, event, state, context)
    end
  rescue
    e ->
      Logger.debug("Component handle_event raised: #{Exception.message(e)}")
      :passthrough
  end

  defp dispatch_component_event(module, event, state, context) do
    case module.handle_event(event, state, context) do
      :passthrough -> :passthrough
      {:handled, _state} -> {:handled, :ok}
      {:ok, _state} -> {:handled, :ok}
      {_state, []} -> {:handled, :ok}
      {_state, commands} when is_list(commands) -> {:commands, commands}
      {:update, _state, commands} -> {:commands, commands}
      {:noreply, _state, _term} -> {:handled, :ok}
      _ -> :passthrough
    end
  end

  # Map element types to their component modules
  @component_modules %{
    button: Raxol.UI.Components.Input.Button,
    text_input: Raxol.UI.Components.Input.TextInput,
    text_field: Raxol.UI.Components.Input.TextField,
    checkbox: Raxol.UI.Components.Input.Checkbox,
    select_list: Raxol.UI.Components.Input.SelectList,
    menu: Raxol.UI.Components.Input.Menu,
    tabs: Raxol.UI.Components.Input.Tabs,
    tree: Raxol.UI.Components.Display.Tree,
    viewport: Raxol.UI.Components.Display.Viewport
  }

  defp component_module(%{type: type}) do
    Map.get(@component_modules, type)
  end

  defp component_module(_), do: nil

  # Build a minimal component state from the element's attributes
  defp component_state_from_element(element) do
    element
    |> Map.drop([:children, :position])
    |> Map.put_new(:focused, false)
    |> Map.put_new(:disabled, false)
  end
end
