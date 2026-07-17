defmodule Raxol.Terminal.ScreenBuffer do
  @moduledoc """
  Manages the terminal's screen buffer state (grid, scrollback, selection).
  This module serves as the main interface for terminal buffer operations,
  delegating specific operations to specialized modules in Raxol.Terminal.Buffer.*.

  ## Structure

  The buffer consists of:
  * A main grid of cells (the visible screen)
  * A scrollback buffer for history
  * Selection state
  * Scroll region settings
  * Dimensions (width and height)

  ## Operations

  The module delegates operations to specialized modules:
  * `Content` - Writing and content management
  * `ScrollRegion` - Scroll region and scrolling operations
  * `LineOperations` - Line manipulation
  * `CharEditor` - Character editing
  * `LineEditor` - Line editing
  * `Eraser` - Clearing operations
  * `Selection` - Text selection
  * `Scrollback` - History management
  * `Queries` - State querying
  * `Initializer` - Buffer creation and validation
  * `Cursor` - Cursor state management
  * `Charset` - Character set management
  * `Formatting` - Text formatting and styling
  """

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  @behaviour Raxol.Terminal.ScreenBufferBehaviour

  @compile {:no_warn_undefined,
            [
              Raxol.Terminal.ScreenBuffer.WriteOps,
              Raxol.Terminal.ScreenBuffer.ScrollOps,
              Raxol.Terminal.ScreenBuffer.EraseOperations,
              Raxol.Terminal.ScreenBuffer.LineOps
            ]}

  alias Raxol.Core.Utils.Validation
  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cell

  alias Raxol.Terminal.ScreenBuffer.{
    Attributes,
    BehaviourImpl,
    EraseOperations,
    LineOps,
    Operations,
    RegionOperations,
    ScrollOps,
    Selection,
    WriteOps
  }

  defstruct [
    :cells,
    :scrollback,
    :scrollback_limit,
    :selection,
    :scroll_region,
    :scroll_position,
    :width,
    :height,
    :damage_regions,
    :default_style,
    cursor_position: {0, 0},
    cursor_style: :block,
    cursor_visible: true,
    cursor_blink: true,
    alternate_screen: false
  ]

  @type t :: %__MODULE__{
          cells: list(list(Cell.t())),
          scrollback: list(list(Cell.t())),
          scrollback_limit: non_neg_integer(),
          selection: {integer(), integer(), integer(), integer()} | nil,
          scroll_region: {integer(), integer()} | nil,
          scroll_position: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          cursor_position: {non_neg_integer(), non_neg_integer()},
          cursor_style: atom(),
          cursor_visible: boolean(),
          cursor_blink: boolean(),
          damage_regions: [
            {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()}
          ],
          default_style: TextFormatting.text_style(),
          alternate_screen: boolean()
        }

  # === Core Operations ===

  @doc """
  Creates a new screen buffer with the specified dimensions.
  Validates and normalizes the input dimensions to ensure they are valid.
  """
  @impl Raxol.Terminal.ScreenBufferBehaviour
  def new(width, height, scrollback_limit \\ @default_scrollback) do
    width = Validation.validate_dimension(width, @default_width)
    height = Validation.validate_dimension(height, @default_height)
    scrollback_limit = Validation.validate_dimension(scrollback_limit, @default_scrollback)

    %__MODULE__{
      cells: create_empty_grid(width, height),
      scrollback: [],
      scrollback_limit: scrollback_limit,
      selection: nil,
      scroll_region: nil,
      scroll_position: 0,
      width: width,
      height: height,
      cursor_position: {0, 0},
      cursor_style: :block,
      cursor_visible: true,
      cursor_blink: true,
      damage_regions: [],
      default_style: TextFormatting.new()
    }
  end

  def new do
    new(@default_width, @default_height)
  end

  def new(size) when is_integer(size) and size > 0 do
    new(size, size)
  end

  def resize(buffer, new_width, new_height) do
    validate_positive_dimensions!(new_width, new_height)
    WriteOps.resize(buffer, new_width, new_height)
  end

  def get_lines(%__MODULE__{cells: cells}), do: cells
  def get_lines(_), do: []

  # === Content Operations (WriteOps) ===

  def write_char(buffer, x, y, char),
    do: WriteOps.write_char(buffer, x, y, char)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def write_char(buffer, x, y, char, style),
    do: WriteOps.write_char(buffer, x, y, char, style)

  @doc """
  Bulk-writes `{x, y, char, style}` cells in one pass per touched row.

  Result-identical to folding `write_char/5` over the list (ordering,
  overwrites, wide-char placeholders, bounds), at O(row) instead of
  O(cells x row) cost. The optional `style_resolver` is called per
  in-bounds write with `(style, cell_currently_at_position)` -- earlier
  writes of the same batch included -- and returns the style to write.
  See `Raxol.Terminal.Buffer.Writer.fill_cells/3`.
  """
  def fill_cells(buffer, cells, style_resolver \\ nil),
    do: WriteOps.fill_cells(buffer, cells, style_resolver)

  def write_string(buffer, x, y, string),
    do: WriteOps.write_string(buffer, x, y, string)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def write_string(buffer, x, y, string, style),
    do: WriteOps.write_string(buffer, x, y, string, style)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def get_char(buffer, x, y), do: WriteOps.get_char(buffer, x, y)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def get_cell(buffer, x, y) when x >= 0 and y >= 0,
    do: WriteOps.get_cell(buffer, x, y)

  def get_cell(_, _, _), do: WriteOps.get_cell(nil, -1, -1)

  def get_content(buffer), do: WriteOps.get_content(buffer)

  def put_line(buffer, y, line), do: WriteOps.put_line(buffer, y, line)

  # === Eraser Operations (delegated) ===

  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate clear_line(buffer, line), to: Operations
  defdelegate clear_line(buffer, line, style), to: Operations
  defdelegate erase_chars(buffer, count), to: Operations
  defdelegate erase_chars(buffer, x, y, count), to: Operations
  defdelegate erase_display(buffer, mode), to: Operations
  defdelegate erase_line(buffer, mode), to: Operations
  defdelegate erase_line(buffer, line, mode), to: Operations

  # === Line Operations (delegated) ===

  defdelegate insert_lines(buffer, count), to: Operations
  defdelegate delete_lines(buffer, count), to: Operations

  defdelegate delete_lines_in_region(buffer, lines, y, top, bottom),
    to: Raxol.Terminal.Buffer.LineOperations

  defdelegate insert_chars(buffer, count), to: Operations
  defdelegate delete_chars(buffer, count), to: Operations
  defdelegate prepend_lines(buffer, lines), to: Operations

  # === Scroll Operations ===

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def scroll_up(buffer, lines), do: ScrollOps.scroll_up(buffer, lines)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def scroll_down(buffer, lines), do: ScrollOps.scroll_down(buffer, lines)

  def scroll_up(buffer, top, bottom, lines),
    do: ScrollOps.scroll_up(buffer, top, bottom, lines)

  def scroll_down(buffer, top, bottom, lines),
    do: ScrollOps.scroll_down(buffer, top, bottom, lines)

  def scroll_to(buffer, top, bottom, line),
    do: ScrollOps.scroll_to(buffer, top, bottom, line)

  def reset_scroll_region(buffer),
    do: ScrollOps.reset_scroll_region(buffer)

  def get_scroll_top(buffer),
    do: ScrollOps.get_scroll_top(buffer)

  def get_scroll_bottom(buffer),
    do: ScrollOps.get_scroll_bottom(buffer)

  def set_scroll_region(buffer, {top, bottom}),
    do: ScrollOps.set_scroll_region(buffer, {top, bottom})

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def set_scroll_region(buffer, top, bottom)
      when is_integer(top) and is_integer(bottom),
      do: ScrollOps.set_scroll_region(buffer, top, bottom)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def clear_scroll_region(buffer),
    do: ScrollOps.clear_scroll_region(buffer)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def get_scroll_region_boundaries(buffer),
    do: ScrollOps.get_scroll_region_boundaries(buffer)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def get_scroll_position(buffer),
    do: ScrollOps.get_scroll_position(buffer)

  # === Dimension Operations ===

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def get_dimensions(buffer), do: {buffer.width, buffer.height}

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def get_width(buffer), do: buffer.width

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def get_height(buffer), do: buffer.height

  def set_dimensions(buffer, width, height), do: resize(buffer, width, height)

  # === Cursor Operations ===

  defdelegate set_cursor_position(buffer, x, y), to: Attributes
  defdelegate get_cursor_position(buffer), to: Attributes
  defdelegate set_cursor_visibility(buffer, visible), to: Attributes
  defdelegate cursor_visible?(buffer), to: Attributes
  defdelegate set_cursor_style(buffer, style), to: Attributes
  defdelegate get_cursor_style(buffer), to: Attributes
  defdelegate set_cursor_blink(buffer, blink), to: Attributes
  defdelegate cursor_blinking?(buffer), to: Attributes

  # === Charset Operations ===

  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate designate_charset(buffer, slot, charset), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_designated_charset(buffer, slot), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate invoke_g_set(buffer, slot), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_current_g_set(buffer), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate apply_single_shift(buffer, slot), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_single_shift(buffer), to: Attributes
  defdelegate reset_charset_state(buffer), to: Attributes

  # === Formatting Operations ===

  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_style(buffer), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate update_style(buffer, style), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate set_attribute(buffer, attribute), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate reset_attribute(buffer, attribute), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate set_foreground(buffer, color), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate set_background(buffer, color), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate reset_all_attributes(buffer), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_foreground(buffer), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_background(buffer), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate attribute_set?(buffer, attribute), to: Attributes
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_set_attributes(buffer), to: Attributes

  # === Selection Operations ===

  defdelegate start_selection(buffer, x, y), to: Selection
  defdelegate clear_selection(buffer), to: Selection
  defdelegate get_selected_text(buffer), to: Selection
  defdelegate update_selection(buffer, x, y), to: Selection
  defdelegate get_selection_boundaries(buffer), to: Selection
  defdelegate selection_active?(buffer), to: Selection
  defdelegate get_selection_start(buffer), to: Selection
  defdelegate get_selection_end(buffer), to: Selection

  def get_selection(buffer), do: get_selected_text(buffer)
  def in_selection?(buffer, x, y), do: Selection.selected?(buffer, x, y)

  defdelegate get_text_in_region(buffer, start_x, start_y, end_x, end_y),
    to: Attributes

  # === Erase Operations (EraseOps) ===

  def clear(buffer, style \\ nil), do: EraseOperations.clear(buffer, style)

  def erase_from_cursor_to_end(buffer, x, y, top, bottom),
    do: EraseOperations.erase_from_cursor_to_end(buffer, x, y, top, bottom)

  def erase_from_start_to_cursor(buffer, x, y, top, bottom),
    do: EraseOperations.erase_from_start_to_cursor(buffer, x, y, top, bottom)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def erase_all(buffer), do: EraseOperations.erase_all(buffer)

  def clear_region(buffer, x, y, width, height),
    do: EraseOperations.clear_region(buffer, x, y, width, height)

  def erase_display(buffer, mode, cursor, min_row, max_row),
    do: EraseOperations.erase_display(buffer, mode, cursor, min_row, max_row)

  def erase_screen(buffer), do: EraseOperations.erase_screen(buffer)

  def erase_line(buffer, mode, cursor, min_col, max_col),
    do: EraseOperations.erase_line(buffer, mode, cursor, min_col, max_col)

  def erase_in_line(buffer, position, type),
    do: EraseOperations.erase_in_line(buffer, position, type)

  def erase_in_display(buffer, position, type),
    do: EraseOperations.erase_in_display(buffer, position, type)

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def erase_from_cursor_to_end(buffer),
    do: EraseOperations.erase_from_cursor_to_end(buffer)

  def delete_chars(buffer, count, cursor, max_col),
    do: EraseOperations.delete_chars(buffer, count, cursor, max_col)

  def insert_chars(buffer, count, cursor, max_col),
    do: EraseOperations.insert_chars(buffer, count, cursor, max_col)

  def delete_characters(buffer, row, col, count, default_style),
    do: EraseOperations.delete_characters(buffer, row, col, count, default_style)

  # === Line Operations (LineOps) ===

  def insert_lines(buffer, y, count, style),
    do: LineOps.insert_lines(buffer, y, count, style)

  def insert_lines(buffer, y, count, style, {top, bottom}),
    do: LineOps.insert_lines(buffer, y, count, style, {top, bottom})

  def insert_lines(buffer, lines, y, top, bottom),
    do: LineOps.insert_lines_in_region(buffer, lines, y, top, bottom)

  def delete_lines(buffer, y, count, style, {top, bottom}),
    do: LineOps.delete_lines(buffer, y, count, style, {top, bottom})

  def delete_lines(buffer, lines, y, top, bottom),
    do: LineOps.delete_lines_in_region(buffer, lines, y, top, bottom)

  def pop_bottom_lines(buffer, count),
    do: LineOps.pop_bottom_lines(buffer, count)

  def get_line(buffer, y), do: LineOps.get_line(buffer, y)

  def get_cell_at(buffer, x, y), do: LineOps.get_cell_at(buffer, x, y)

  # === Query Operations ===

  @impl Raxol.Terminal.ScreenBufferBehaviour
  def empty?(buffer) do
    case buffer.cells do
      nil ->
        true

      cells ->
        Enum.all?(cells, fn line ->
          Enum.all?(line, &Cell.empty?/1)
        end)
    end
  end

  def cleanup(_buffer), do: :ok

  def mark_damaged(buffer, x, y, width, height, _reason) do
    new_region = {x, y, width, height}
    updated_damage_regions = [new_region | buffer.damage_regions || []]
    %{buffer | damage_regions: updated_damage_regions}
  end

  # === Scrollback Operations ===

  def get_scrollback(buffer), do: buffer.scrollback || []

  def set_scrollback(buffer, scrollback),
    do: %{buffer | scrollback: scrollback}

  def get_damaged_regions(buffer), do: buffer.damage_regions || []

  def clear_damaged_regions(buffer), do: %{buffer | damage_regions: []}

  def get_scroll_region(buffer),
    do: ScrollOps.get_scroll_region(buffer)

  def shift_region_to_line(buffer, region, target_line),
    do: ScrollOps.shift_region_to_line(buffer, region, target_line)

  def scroll_down(buffer, lines, count)
      when is_integer(lines) and is_integer(count),
      do: ScrollOps.scroll_down_with_count(buffer, lines, count)

  def scroll_down(buffer, lines, count) when is_integer(count),
    do: ScrollOps.scroll_down_with_count(buffer, lines, count)

  # === Behaviour Callback Implementations ===

  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate cleanup_file_watching(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate clear_output_buffer(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate clear_saved_states(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate clear_screen(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate collect_metrics(buffer, type), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate create_chart(buffer, type, options), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate current_theme(), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate enqueue_control_sequence(buffer, sequence), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate erase_all_with_scrollback(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate erase_from_cursor_to_end_of_line(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate erase_from_start_of_line_to_cursor(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate erase_from_start_to_cursor(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate erase_line(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate flush_output(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_config(), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_current_state(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_metric(buffer, type, name), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_metric_value(buffer, name), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_metrics_by_type(buffer, type), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_output_buffer(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_preferences(), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_saved_states_count(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_size(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_state_stack(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate get_update_settings(), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate handle_csi_sequence(buffer, command, params), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate handle_debounced_events(buffer, events, delay), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate handle_file_event(buffer, event), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate handle_mode(buffer, mode, value), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate has_saved_states?(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate light_theme(), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate mark_damaged(buffer, x, y, width, height), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate record_metric(buffer, type, name, value), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate record_operation(buffer, operation, duration), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate record_performance(buffer, metric, value), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate record_resource(buffer, type, value), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate reset_state(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate restore_state(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate save_state(buffer), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate set_config(config), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate set_preferences(preferences), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate update_current_state(buffer, updates), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate update_state_stack(buffer, stack), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate verify_metrics(buffer, type), to: BehaviourImpl
  @impl Raxol.Terminal.ScreenBufferBehaviour
  defdelegate write(buffer, data), to: BehaviourImpl

  def write(buffer, string, opts) when is_map(buffer) and is_binary(string) do
    write_string(buffer, 0, 0, string, opts[:style] || nil)
  end

  # === Region Operations ===

  defdelegate fill_region(buffer, x, y, width, height, cell),
    to: RegionOperations

  def update(buffer, changes) when is_map(changes) do
    Map.merge(buffer, changes)
  end

  defdelegate handle_single_line_replacement(
                lines_list,
                row,
                start_col,
                end_col,
                replacement
              ),
              to: RegionOperations

  # === Compatibility Functions ===

  def scroll(buffer, lines) when lines > 0, do: scroll_up(buffer, lines)

  def scroll(buffer, lines) when lines < 0,
    do: {scroll_down(buffer, -lines), []}

  def scroll(buffer, 0), do: {buffer, []}

  def write(buffer, x, y, content) when is_binary(content),
    do: write_string(buffer, x, y, content)

  def write(buffer, x, y, content),
    do: write_char(buffer, x, y, to_string(content))

  # === Private Helpers ===

  # All cells of a fresh grid are equal, so build ONE default cell and one
  # row and share them (immutable terms; indistinguishable from per-cell
  # construction except in allocation count). A 200x60 grid goes from 12k
  # cell + 12k style allocations to 1 + 1 -- this runs once per rendered
  # frame on the `Backends.apply_cells_to_buffer/2` path.
  defp create_empty_grid(width, height) when width > 0 and height > 0 do
    List.duplicate(List.duplicate(Cell.new(), width), height)
  end

  defp create_empty_grid(_width, _height), do: []

  defp validate_positive_dimensions!(width, height)
       when width <= 0 or height <= 0 do
    raise ArgumentError,
          "ScreenBuffer dimensions must be positive integers, got: #{width}x#{height}"
  end

  defp validate_positive_dimensions!(_width, _height), do: :ok
end
