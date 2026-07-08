defmodule Raxol.UI.Components.Input.MultiLineInput do
  @moduledoc """
  A multi-line input component for text editing, supporting line wrapping, scrolling, selection, and accessibility.

  **BREAKING:** All styling is now theme-driven. The `style` field and `@default_style` are removed. Use the theme system for all appearance customization.

  Harmonized with modern Raxol component standards (style/theme merging, lifecycle hooks, accessibility props).
  """

  alias Raxol.UI.Components.Base.Component
  alias Raxol.UI.Components.Input.MultiLineInput.CursorMovement
  alias Raxol.UI.Components.Input.MultiLineInput.EditOps
  alias Raxol.UI.Components.Input.MultiLineInput.SelectionOps
  require Raxol.View.Elements

  @compile {:no_warn_undefined,
            [
              Raxol.UI.Components.Input.MultiLineInput.CursorMovement,
              Raxol.UI.Components.Input.MultiLineInput.EditOps,
              Raxol.UI.Components.Input.MultiLineInput.SelectionOps
            ]}

  @behaviour Component

  @default_width 40
  @default_height 10

  @typedoc "State for the MultiLineInput component. See @type t for field details."
  @type t :: %__MODULE__{
          id: String.t() | nil,
          value: String.t(),
          placeholder: String.t(),
          width: integer(),
          height: integer(),
          theme: map(),
          wrap: :none | :char | :word,
          cursor_pos: {integer(), integer()},
          scroll_offset: {integer(), integer()},
          selection_start: {integer(), integer()} | nil,
          selection_end: {integer(), integer()} | nil,
          history: %{undo: list(), redo: list()},
          shift_held: boolean(),
          focused: boolean(),
          on_change: (String.t() -> any()) | nil,
          on_submit: (-> any()) | nil,
          aria_label: String.t() | nil,
          tooltip: String.t() | nil,
          lines: [String.t()],
          desired_col: integer() | nil
        }

  defstruct id: nil,
            value: "",
            placeholder: "",
            width: @default_width,
            height: @default_height,
            theme: %{},
            wrap: :word,
            cursor_pos: {0, 0},
            scroll_offset: {0, 0},
            selection_start: nil,
            selection_end: nil,
            history: %{undo: [], redo: []},
            shift_held: false,
            focused: false,
            on_change: nil,
            on_submit: nil,
            aria_label: nil,
            tooltip: nil,
            lines: [""],
            desired_col: nil

  @spec init(map()) :: {:ok, __MODULE__.t()}
  @impl true
  @doc """
  Initializes the MultiLineInput state, splitting value into lines for editing.
  """
  def init(props) do
    props = Map.put_new_lazy(props, :id, &Raxol.Core.ID.generate/0)
    state = struct(__MODULE__, props)

    lines =
      Raxol.UI.Components.Input.MultiLineInput.TextHelper.split_into_lines(
        state.value,
        state.width,
        state.wrap
      )

    {:ok, %{state | lines: lines}}
  end

  @doc """
  Mounts the MultiLineInput component. Performs any setup needed after initialization.
  """
  @spec mount(__MODULE__.t()) :: __MODULE__.t()
  @impl true
  def mount(state), do: state

  @doc """
  Unmounts the MultiLineInput component, performing any necessary cleanup.
  """
  @spec unmount(__MODULE__.t()) :: __MODULE__.t()
  @impl true
  def unmount(state), do: state

  @impl true
  def update(msg, state) do
    route_message(msg, state)
  end

  # --- Message routing ---
  defp route_message(msg, state) do
    case Raxol.UI.Components.Input.MultiLineInput.MessageRouter.route(
           msg,
           state
         ) do
      {:ok, result} -> result
      :error -> handle_unknown_message(msg, state)
    end
  end

  # --- Delegated to CursorMovement ---
  @doc false
  defdelegate handle_move_cursor(direction, state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_line_start(state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_line_end(state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_page(direction, state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_doc_start(state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_doc_end(state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_to(pos, state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_word_left(state), to: CursorMovement
  @doc false
  defdelegate handle_move_cursor_word_right(state), to: CursorMovement
  @doc false
  defdelegate handle_selection_move(state, direction), to: CursorMovement

  # --- Delegated to SelectionOps ---
  @doc false
  defdelegate handle_select_all(state), to: SelectionOps
  @doc false
  defdelegate handle_copy(state), to: SelectionOps
  @doc false
  defdelegate handle_cut(state), to: SelectionOps
  @doc false
  defdelegate handle_paste(state), to: SelectionOps
  @doc false
  defdelegate handle_clipboard_content(content, state), to: SelectionOps
  @doc false
  defdelegate handle_delete_selection(direction, state), to: SelectionOps
  @doc false
  defdelegate handle_copy_selection(state), to: SelectionOps
  @doc false
  defdelegate handle_select_to(pos, state), to: SelectionOps

  # --- Delegated to EditOps ---
  @doc false
  defdelegate handle_input(char_codepoint, state), to: EditOps
  @doc false
  defdelegate handle_backspace(state), to: EditOps
  @doc false
  defdelegate handle_delete(state), to: EditOps
  @doc false
  defdelegate handle_enter(state), to: EditOps

  # --- Message handlers (kept in main module) ---
  def handle_update_props(new_props, state) do
    new_state = Map.merge(state, new_props)
    new_state = ensure_cursor_visible(new_state)
    {:noreply, new_state, nil}
  end

  def handle_focus(state) do
    {:noreply, %{state | focused: true}, nil}
  end

  def handle_blur(state) do
    {:noreply,
     %{state | focused: false, selection_start: nil, selection_end: nil}, nil}
  end

  def handle_set_shift_held(held, state) do
    {:noreply, %{state | shift_held: held}, nil}
  end

  def handle_undo(state) do
    case state.history.undo do
      [] ->
        {:noreply, state, nil}

      [snapshot | rest] ->
        redo_snapshot = %{value: state.value, cursor_pos: state.cursor_pos}

        new_state =
          restore_snapshot(state, snapshot, %{
            undo: rest,
            redo: [redo_snapshot | state.history.redo]
          })

        {:noreply, new_state, nil}
    end
  end

  def handle_redo(state) do
    case state.history.redo do
      [] ->
        {:noreply, state, nil}

      [snapshot | rest] ->
        undo_snapshot = %{value: state.value, cursor_pos: state.cursor_pos}

        new_state =
          restore_snapshot(state, snapshot, %{
            undo: [undo_snapshot | state.history.undo],
            redo: rest
          })

        {:noreply, new_state, nil}
    end
  end

  def handle_unknown_message(msg, state) do
    Raxol.Core.Runtime.Log.warning(
      "[MultiLineInput] Unhandled update message: #{inspect(msg)}"
    )

    {:noreply, state, nil}
  end

  @doc """
  Handles events for the MultiLineInput component, such as keypresses, mouse events, and context changes.
  """
  @impl true
  def handle_event(event, state, _context) do
    # Delegate to the legacy EventHandler for translation
    case Raxol.UI.Components.Input.MultiLineInput.EventHandler.handle_event(
           event,
           state
         ) do
      {:update, msg, new_state} ->
        # Call update/2 with the translated message
        update(msg, new_state)

      {:noreply, new_state, cmds} ->
        {:noreply, new_state, cmds}

      _other ->
        # Fallback for any other return shape
        {:noreply, state, nil}
    end
  end

  # --- Public helpers (used by sub-modules) ---
  def ensure_cursor_visible(state) do
    {cursor_row, _cursor_col} = state.cursor_pos
    {scroll_row, scroll_col} = state.scroll_offset
    height = state.height

    new_scroll_row = calculate_scroll_row(cursor_row, scroll_row, height)

    new_scroll_col = scroll_col

    new_lines =
      Raxol.UI.Components.Input.MultiLineInput.TextHelper.split_into_lines(
        state.value,
        state.width,
        state.wrap
      )

    %{state | scroll_offset: {new_scroll_row, new_scroll_col}, lines: new_lines}
  end

  def trigger_on_change({:noreply, new_state, existing_cmd}, old_state) do
    trigger_change_if_value_changed(new_state, old_state, existing_cmd)
  end

  @max_undo_history 100

  @doc false
  def push_history(state) do
    snapshot = %{value: state.value, cursor_pos: state.cursor_pos}
    undo_stack = [snapshot | state.history.undo] |> Enum.take(@max_undo_history)
    %{state | history: %{undo: undo_stack, redo: []}}
  end

  # --- Render ---
  @doc """
  Renders the MultiLineInput component using the current state and context.
  """
  @impl true
  def render(state, context) do
    state = %{
      state
      | focused:
          Raxol.UI.FocusHelper.focused?(state.id, context) or state.focused
    }

    merged_theme = merge_themes(context, state)
    visible_lines = calculate_visible_lines(state)

    children = build_children(state, visible_lines, merged_theme)

    root_props = build_root_props(state, merged_theme)

    Raxol.View.Elements.column root_props do
      children
    end
  end

  # --- Private helpers ---
  defp merge_themes(context, state) do
    component_theme = Map.get(context.theme || %{}, :multi_line_input, %{})
    Map.merge(component_theme, state.theme || %{})
  end

  defp calculate_visible_lines(state) do
    start_row = state.scroll_offset |> elem(0)
    end_row = min(start_row + state.height - 1, length(state.lines) - 1)
    Enum.slice(state.lines, start_row..end_row)
  end

  defp build_children(state, visible_lines, merged_theme) do
    line_elements = render_line_elements(visible_lines, state, merged_theme)
    placeholder_element = render_placeholder(state, merged_theme)

    children =
      choose_children_content(placeholder_element, visible_lines, line_elements)

    children |> List.flatten() |> Enum.reject(&is_nil/1)
  end

  defp render_line_elements(visible_lines, state, merged_theme) do
    start_row = state.scroll_offset |> elem(0)

    Enum.with_index(visible_lines, start_row)
    |> Enum.map(fn {line, index} ->
      Raxol.UI.Components.Input.MultiLineInput.RenderHelper.render_line(
        index,
        line,
        state,
        %{components: %{multi_line_input: merged_theme}}
      )
    end)
  end

  defp render_placeholder(
         %__MODULE__{value: "", focused: false, placeholder: placeholder},
         merged_theme
       )
       when placeholder != "" do
    Raxol.View.Elements.label(
      content: placeholder,
      style: [color: merged_theme[:placeholder_color] || :gray]
    )
  end

  defp render_placeholder(%__MODULE__{}, _merged_theme), do: nil

  defp build_root_props(state, merged_theme) do
    [style: merged_theme, aria_label: state.aria_label, tooltip: state.tooltip]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp calculate_scroll_row(cursor_row, scroll_row, _height)
       when cursor_row < scroll_row,
       do: cursor_row

  defp calculate_scroll_row(cursor_row, scroll_row, height)
       when cursor_row >= scroll_row + height,
       do: cursor_row - height + 1

  defp calculate_scroll_row(_cursor_row, scroll_row, _height), do: scroll_row

  defp restore_snapshot(state, snapshot, history) do
    lines =
      Raxol.UI.Components.Input.MultiLineInput.TextHelper.split_into_lines(
        snapshot.value,
        state.width,
        state.wrap
      )

    %{
      state
      | value: snapshot.value,
        cursor_pos: snapshot.cursor_pos,
        lines: lines,
        history: history,
        selection_start: nil,
        selection_end: nil
    }
  end

  defp trigger_change_if_value_changed(new_state, old_state, existing_cmd) do
    if new_state.value != old_state.value and
         is_function(new_state.on_change, 1) do
      cmd = {:component_event, new_state.id, {:change, new_state.value}}

      Raxol.Core.Runtime.Log.debug(
        "Value changed for #{new_state.id}, queueing :change event."
      )

      {:noreply, new_state, [cmd]}
    else
      {:noreply, new_state, existing_cmd}
    end
  end

  defp choose_children_content(
         placeholder_element,
         visible_lines,
         line_elements
       ) do
    if placeholder_element != nil and visible_lines == [""] do
      [placeholder_element]
    else
      line_elements
    end
  end
end
