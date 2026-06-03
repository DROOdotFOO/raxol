defmodule Raxol.UI.Components.Input.TextField do
  @moduledoc """
  A text field component for single-line text input.

  It supports validation, placeholders, masks, and styling.

  ## Unicode and display width

  The cursor (`cursor_pos`) and scroll position (`scroll_offset`) are
  grapheme indices, while `width` is measured in display cells. Internal
  helpers translate between the two so CJK characters, emoji, and ZWJ
  sequences scroll and clip on cell boundaries instead of grapheme counts.
  Cell width is sourced from `Raxol.UI.TextMeasure` (single source of truth).
  """
  alias Raxol.UI.TextMeasure
  alias Raxol.UI.Theming.Theme

  @behaviour Raxol.UI.Components.Base.Component

  @typedoc """
  State for the TextField component.

  - :id - unique identifier
  - :value - current text value
  - :placeholder - placeholder text
  - :style - style map
  - :theme - theme map
  - :disabled - whether the field is disabled
  - :secret - whether to mask input (e.g., password)
  - :focused - whether the field is focused
  - :cursor_pos - cursor position
  - :scroll_offset - horizontal scroll offset
  - :width - visible width of the field (not in defstruct, but added in init)
  """
  @type t :: %__MODULE__{
          id: any(),
          value: String.t(),
          placeholder: String.t(),
          style: map(),
          theme: map(),
          disabled: boolean(),
          secret: boolean(),
          focused: boolean(),
          cursor_pos: non_neg_integer(),
          scroll_offset: non_neg_integer(),
          width: non_neg_integer()
        }

  defstruct id: nil,
            value: "",
            placeholder: "",
            style: %{},
            theme: %{},
            disabled: false,
            secret: false,
            # Internal state
            focused: false,
            cursor_pos: 0,
            scroll_offset: 0,
            width: 20

  @doc """
  Initializes the TextField component state from the given props.
  """
  @impl Raxol.UI.Components.Base.Component
  def init(props) do
    id = props[:id] || Raxol.Core.ID.generate()
    width = props[:width] || 20
    state = struct!(__MODULE__, Map.merge(%{id: id}, props))
    {:ok, Map.put(state, :width, width)}
  end

  @doc """
  Mounts the TextField component. Performs any setup needed after initialization.
  """
  @impl Raxol.UI.Components.Base.Component
  def mount(state), do: {state, []}

  @doc """
  Updates the TextField component state in response to messages or prop changes.
  """
  @impl Raxol.UI.Components.Base.Component
  def update({:update_props, new_props}, state) do
    updated_state = Map.merge(state, Map.new(new_props))
    # Clamp cursor position if value changed
    cursor_pos =
      clamp(updated_state.cursor_pos, 0, String.length(updated_state.value))

    width = Map.get(updated_state, :width, 20)

    # Reconcile scroll_offset with the (possibly new) value/width/cursor
    # using the cell-aware policy. Avoids ASCII-only String.length math
    # that would corrupt scroll under CJK or emoji content.
    scroll_offset =
      adjust_scroll_offset(
        cursor_pos,
        width,
        updated_state.value,
        updated_state.scroll_offset
      )

    %{
      updated_state
      | cursor_pos: cursor_pos,
        scroll_offset: scroll_offset,
        width: width
    }
  end

  def update({:move_cursor_to, {_row, col}}, state) do
    # Convert column position to cursor position, accounting for scroll offset
    new_cursor_pos =
      clamp(col + state.scroll_offset, 0, String.length(state.value))

    width = Map.get(state, :width, 20)

    new_scroll_offset =
      adjust_scroll_offset(
        new_cursor_pos,
        width,
        state.value,
        state.scroll_offset
      )

    {:noreply,
     %{
       state
       | cursor_pos: new_cursor_pos,
         scroll_offset: new_scroll_offset
     }}
  end

  # Handle focus/blur implicitly via context for now
  # def update(:focus, state), do: {:noreply, %{state | focused: true}}
  # def update(:blur, state), do: {:noreply, %{state | focused: false}}

  @impl Raxol.UI.Components.Base.Component
  def update(message, state) do
    _message = message
    {:noreply, state}
  end

  @doc """
  Handles events for the TextField component, such as keypresses, focus, and blur.
  """
  @impl Raxol.UI.Components.Base.Component
  def handle_event(
        {:keypress, _key, _modifiers},
        %{disabled: true} = state,
        _context
      ) do
    {state, []}
  end

  def handle_event({:keypress, key, modifiers}, state, context) do
    handle_keypress(state, key, modifiers, context)
  end

  def handle_event({:focus}, state, _context) do
    {%{state | focused: true}, []}
  end

  def handle_event({:blur}, state, _context) do
    {%{state | focused: false}, []}
  end

  def handle_event({:mouse, {:click, {_x, y}}}, state, _context) do
    # Handle mouse clicks to position cursor
    updated_state = update({:move_cursor_to, {0, y}}, state)
    {updated_state, []}
  end

  def handle_event(_event, state, _context) do
    {state, []}
  end

  defp handle_keypress(state, key, _modifiers, context) when is_binary(key) do
    _context = context
    # Insert character
    {left, right} = String.split_at(state.value, state.cursor_pos)
    new_value = left <> key <> right
    new_cursor_pos = state.cursor_pos + String.length(key)
    width = Map.get(state, :width, 20)

    new_scroll_offset =
      adjust_scroll_offset(
        new_cursor_pos,
        width,
        new_value,
        state.scroll_offset
      )

    {:noreply,
     %{
       state
       | value: new_value,
         cursor_pos: new_cursor_pos,
         scroll_offset: new_scroll_offset
     }}
  end

  defp handle_keypress(
         %{cursor_pos: 0} = state,
         :backspace,
         _modifiers,
         _context
       ) do
    {:noreply, state}
  end

  defp handle_keypress(state, :backspace, _modifiers, _context) do
    {left, right} = String.split_at(state.value, state.cursor_pos)
    new_value = String.slice(left, 0, String.length(left) - 1) <> right
    new_cursor_pos = state.cursor_pos - 1
    width = Map.get(state, :width, 20)

    new_scroll_offset =
      adjust_scroll_offset(
        new_cursor_pos,
        width,
        new_value,
        state.scroll_offset
      )

    {:noreply,
     %{
       state
       | value: new_value,
         cursor_pos: new_cursor_pos,
         scroll_offset: new_scroll_offset
     }}
  end

  defp handle_keypress(state, :delete, _modifiers, _context) do
    if state.cursor_pos >= String.length(state.value) do
      {:noreply, state}
    else
      {left, right} = String.split_at(state.value, state.cursor_pos)
      new_value = left <> String.slice(right, 1, String.length(right) - 1)
      width = Map.get(state, :width, 20)

      new_scroll_offset =
        adjust_scroll_offset(
          state.cursor_pos,
          width,
          new_value,
          state.scroll_offset
        )

      {:noreply, %{state | value: new_value, scroll_offset: new_scroll_offset}}
    end
  end

  defp handle_keypress(state, :arrow_left, _modifiers, _context) do
    new_cursor_pos = clamp(state.cursor_pos - 1, 0, String.length(state.value))
    width = Map.get(state, :width, 20)

    new_scroll_offset =
      adjust_scroll_offset(
        new_cursor_pos,
        width,
        state.value,
        state.scroll_offset
      )

    {:noreply,
     %{state | cursor_pos: new_cursor_pos, scroll_offset: new_scroll_offset}}
  end

  defp handle_keypress(state, :arrow_right, _modifiers, _context) do
    new_cursor_pos = clamp(state.cursor_pos + 1, 0, String.length(state.value))
    width = Map.get(state, :width, 20)

    new_scroll_offset =
      adjust_scroll_offset(
        new_cursor_pos,
        width,
        state.value,
        state.scroll_offset
      )

    {:noreply,
     %{state | cursor_pos: new_cursor_pos, scroll_offset: new_scroll_offset}}
  end

  defp handle_keypress(state, :home, _modifiers, _context) do
    {:noreply, %{state | cursor_pos: 0, scroll_offset: 0}}
  end

  defp handle_keypress(state, :end, _modifiers, _context) do
    new_cursor_pos = String.length(state.value)
    width = Map.get(state, :width, 20)

    new_scroll_offset =
      adjust_scroll_offset(
        new_cursor_pos,
        width,
        state.value,
        state.scroll_offset
      )

    {:noreply,
     %{state | cursor_pos: new_cursor_pos, scroll_offset: new_scroll_offset}}
  end

  # Ignore other key presses for now
  defp handle_keypress(state, _key, _modifiers, _context) do
    {:noreply, state}
  end

  @doc """
  Renders the TextField component using the current state and context.
  """
  @impl Raxol.UI.Components.Base.Component
  def render(state, context) do
    focused = Raxol.UI.FocusHelper.focused?(state.id, context) or state.focused
    state = %{state | focused: focused}
    merged_style = get_merged_style(state)

    merged_style =
      Raxol.UI.FocusHelper.maybe_focus_style(state.id, context, merged_style)

    {visible_value, showing_placeholder} = get_visible_value(state)

    text_children =
      build_text_children(
        state,
        visible_value,
        showing_placeholder,
        merged_style
      )

    %{type: :view, style: merged_style, children: text_children}
  end

  defp get_merged_style(state) do
    theme = Map.get(state, :theme, %{})
    component_theme_style = Theme.component_style(theme, :text_field)

    case component_theme_style do
      %Raxol.Style{} = style_struct ->
        Raxol.Style.merge(style_struct, state.style)

      plain_map when is_map(plain_map) ->
        Map.merge(plain_map, state.style || %{})

      _ ->
        state.style || %{}
    end
  end

  defp get_visible_value(state) do
    display_value = get_display_value(state.secret, state.value)

    showing_placeholder =
      should_show_placeholder(display_value, state.focused, state.placeholder)

    final_value =
      get_final_value(showing_placeholder, state.placeholder, display_value)

    width = Map.get(state, :width, 20)
    scroll_offset = state.scroll_offset || 0

    visible_value =
      slice_visible_value(
        showing_placeholder,
        final_value,
        scroll_offset,
        width
      )

    {visible_value, showing_placeholder}
  end

  defp get_display_value(true, value),
    do: String.duplicate("•", String.length(value))

  defp get_display_value(false, value), do: value

  defp should_show_placeholder(display_value, focused, placeholder) do
    String.length(display_value) == 0 && !focused && placeholder != ""
  end

  defp get_final_value(true, placeholder, _display_value), do: placeholder
  defp get_final_value(false, _placeholder, display_value), do: display_value

  defp slice_visible_value(true, final_value, _scroll_offset, width) do
    truncate_to_cells(final_value, 0, width)
  end

  defp slice_visible_value(false, final_value, scroll_offset, width) do
    truncate_to_cells(final_value, scroll_offset, width)
  end

  defp build_text_children(
         state,
         visible_value,
         showing_placeholder,
         merged_style
       ) do
    select_text_children(
      showing_placeholder,
      state.focused,
      state,
      visible_value,
      merged_style
    )
  end

  defp select_text_children(true, _focused, _state, visible_value, merged_style) do
    build_placeholder_children(visible_value, merged_style)
  end

  defp select_text_children(false, true, state, visible_value, merged_style) do
    build_focused_children(state, visible_value, merged_style)
  end

  defp select_text_children(false, false, _state, visible_value, _merged_style) do
    build_normal_children(visible_value)
  end

  defp build_placeholder_children(visible_value, merged_style) do
    placeholder_style = %{
      color: Map.get(merged_style, :placeholder_color, "#888"),
      text_decoration: [:italic]
    }

    [
      Raxol.View.Components.text(
        content: visible_value,
        style: placeholder_style
      )
    ]
  end

  defp build_focused_children(state, visible_value, merged_style) do
    scroll_offset = state.scroll_offset || 0
    # cursor_in_window is a grapheme count within the visible substring,
    # clamped to the visible substring's grapheme length (not `width`,
    # which is in cells and would mis-bound the split).
    cursor_in_window =
      clamp(
        state.cursor_pos - scroll_offset,
        0,
        String.length(visible_value)
      )

    {left, right} = String.split_at(visible_value, cursor_in_window)

    cursor_style = %{
      text_decoration: [:underline],
      color: merged_style.color || "#fff",
      background: merged_style.background || "#000"
    }

    [
      Raxol.View.Components.text(content: left),
      Raxol.View.Components.text(content: "|", style: cursor_style),
      Raxol.View.Components.text(content: right)
    ]
  end

  defp build_normal_children(visible_value) do
    [
      Raxol.View.Components.text(content: visible_value)
    ]
  end

  @doc """
  Unmounts the TextField component, performing any necessary cleanup.
  """
  @impl Raxol.UI.Components.Base.Component
  def unmount(state), do: state

  defp clamp(value, lo, hi), do: Raxol.Core.Utils.Math.clamp(value, lo, hi)

  # --- Cell-aware scroll / display helpers ---

  # Keep the cursor's cell position within the visible window. `cursor_pos`
  # and `scroll_offset` are grapheme indices; `width` is cells. All decisions
  # are made in cell space, then translated back to a grapheme scroll_offset.
  defp adjust_scroll_offset(cursor_pos, width, value, scroll_offset) do
    cursor_cell = cell_offset_at(value, cursor_pos)
    scroll_cell = cell_offset_at(value, scroll_offset)
    total_cells = TextMeasure.display_width(value)

    cond do
      cursor_cell < scroll_cell ->
        cursor_pos

      cursor_cell > scroll_cell + width - 1 ->
        grapheme_index_at_cell(value, cursor_cell - width + 1)

      total_cells - scroll_cell < width ->
        grapheme_index_at_cell(value, max(0, total_cells - width))

      true ->
        scroll_offset
    end
  end

  # Cell offset of the boundary BEFORE the grapheme at `grapheme_index`.
  # Equivalent to "sum of display widths of graphemes [0, grapheme_index)".
  defp cell_offset_at(value, grapheme_index) do
    value
    |> String.slice(0, grapheme_index)
    |> TextMeasure.display_width()
  end

  # Smallest grapheme index whose cell offset is >= `target_cell`. Used to
  # translate a cell-space scroll target back to a grapheme index. If a
  # wide character straddles `target_cell`, the index lands on that
  # grapheme (never inside it).
  defp grapheme_index_at_cell(_value, target_cell) when target_cell <= 0, do: 0

  defp grapheme_index_at_cell(value, target_cell) do
    {idx, _cells} =
      value
      |> String.graphemes()
      |> Enum.reduce_while({0, 0}, fn g, {idx, cells} ->
        if cells >= target_cell do
          {:halt, {idx, cells}}
        else
          {:cont, {idx + 1, cells + TextMeasure.display_width(g)}}
        end
      end)

    idx
  end

  # Take graphemes from `start_grapheme` forward, accumulating until the
  # next grapheme would exceed `max_cells`. A trailing wide char that
  # would straddle the right edge is dropped (no partial-cell display).
  defp truncate_to_cells(value, start_grapheme, max_cells) do
    value
    |> String.slice(start_grapheme..-1//1)
    |> TextMeasure.split_at_display_width(max_cells)
    |> elem(0)
  end
end
