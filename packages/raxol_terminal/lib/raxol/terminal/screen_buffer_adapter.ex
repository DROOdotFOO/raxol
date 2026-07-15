defmodule Raxol.Terminal.ScreenBufferAdapter do
  @moduledoc """
  Backward-compatible adapter that maps the old ScreenBuffer API to the new consolidated modules.
  This allows existing code to work without changes while we migrate to the consolidated architecture.
  """

  alias Raxol.Terminal.ScreenBuffer.{
    Attributes,
    Core,
    Operations,
    ScrollOps,
    Selection
  }

  # Re-export the Core struct as ScreenBuffer.t()
  @type t :: map()

  # Creation and basic operations (from Core)
  defdelegate new(width, height), to: Core
  defdelegate new(width, height, scrollback_limit), to: Core
  defdelegate resize(buffer, new_width, new_height), to: Core
  defdelegate get_dimensions(buffer), to: Core
  defdelegate get_width(buffer), to: Core
  defdelegate get_height(buffer), to: Core
  defdelegate within_bounds?(buffer, x, y), to: Core
  defdelegate get_cell(buffer, x, y), to: Core
  defdelegate get_char(buffer, x, y), to: Core
  defdelegate get_line(buffer, y), to: Core
  defdelegate clear(buffer), to: Core

  # Write and mutation operations (from Operations)
  defdelegate write_char(buffer, x, y, char), to: Operations
  defdelegate write_char(buffer, x, y, char, style), to: Operations
  defdelegate write_text(buffer, x, y, text), to: Operations
  defdelegate write_text(buffer, x, y, text, style), to: Operations

  defdelegate write_string(buffer, x, y, string),
    to: Operations,
    as: :write_text

  defdelegate write_string(buffer, x, y, string, style),
    to: Operations,
    as: :write_text

  defdelegate insert_char(buffer, char), to: Operations
  defdelegate insert_char(buffer, char, style), to: Operations
  defdelegate delete_char(buffer), to: Operations
  defdelegate clear_line(buffer, y), to: Operations
  defdelegate clear_to_end_of_line(buffer), to: Operations
  defdelegate clear_to_beginning_of_line(buffer), to: Operations
  defdelegate clear_to_end_of_screen(buffer), to: Operations
  defdelegate clear_to_beginning_of_screen(buffer), to: Operations
  defdelegate clear_region(buffer, x, y, width, height), to: Operations
  defdelegate insert_line(buffer, y), to: Operations
  defdelegate delete_line(buffer, y), to: Operations
  defdelegate fill_region(buffer, x, y, width, height, char), to: Operations

  defdelegate fill_region(buffer, x, y, width, height, char, style),
    to: Operations

  defdelegate copy_region(buffer, src_x, src_y, width, height, dest_x, dest_y),
    to: Operations

  # Scrolling operations (from ScrollOps)
  defdelegate set_scroll_region(buffer, top, bottom), to: ScrollOps
  defdelegate get_scroll_region(buffer), to: ScrollOps
  defdelegate get_scroll_position(buffer), to: ScrollOps

  def scroll_up(buffer), do: ScrollOps.scroll_up(buffer, 1)
  defdelegate scroll_up(buffer, n), to: ScrollOps
  def scroll_down(buffer), do: ScrollOps.scroll_down(buffer, 1)
  defdelegate scroll_down(buffer, n), to: ScrollOps

  # ScrollOps.scroll_up/4 returns {buffer, scrolled_out_rows} (TE); this
  # adapter's contract is buffer-only, so drop the eviction list here.
  def scroll_region_up(buffer, top, bottom, n),
    do: elem(ScrollOps.scroll_up(buffer, top, bottom, n), 0)

  def scroll_region_down(buffer, top, bottom, n),
    do: ScrollOps.scroll_down(buffer, top, bottom, n)

  # Scrollback stubs (scrollback storage removed with Scroll module)
  def save_to_scrollback(buffer, _lines), do: buffer
  def clear_scrollback(buffer), do: buffer
  def get_scrollback(_buffer), do: []
  def get_scrollback(_buffer, _limit), do: []
  def set_scroll_position(buffer, _position), do: buffer
  def scroll_to_bottom(buffer), do: buffer
  def scroll_to_top(buffer), do: buffer
  def get_visible_lines(buffer), do: get_lines(buffer)
  def reverse_index(buffer), do: elem(ScrollOps.scroll_up(buffer, 1), 0)
  def index(buffer), do: ScrollOps.scroll_down(buffer, 1)

  # Selection operations (from Selection)
  defdelegate start_selection(buffer, x, y), to: Selection
  defdelegate extend_selection(buffer, x, y), to: Selection
  defdelegate clear_selection(buffer), to: Selection
  defdelegate get_selection(buffer), to: Selection
  defdelegate position_in_selection?(buffer, x, y), to: Selection
  defdelegate get_selected_text(buffer), to: Selection
  defdelegate get_selected_lines(buffer), to: Selection
  defdelegate select_line(buffer, y), to: Selection
  defdelegate select_lines(buffer, start_y, end_y), to: Selection
  defdelegate select_all(buffer), to: Selection
  defdelegate select_word(buffer, x, y), to: Selection
  defdelegate expand_selection_to_word(buffer), to: Selection

  # Attribute and cursor operations (from Attributes)
  defdelegate set_cursor_position(buffer, x, y), to: Attributes
  defdelegate get_cursor_position(buffer), to: Attributes
  defdelegate move_cursor(buffer, dx, dy), to: Attributes
  defdelegate set_cursor_visible(buffer, visible), to: Attributes
  defdelegate set_cursor_style(buffer, style), to: Attributes
  defdelegate set_cursor_blink(buffer, blink), to: Attributes
  defdelegate save_cursor(buffer), to: Attributes
  defdelegate restore_cursor(buffer), to: Attributes
  defdelegate set_default_style(buffer, style), to: Attributes
  defdelegate get_default_style(buffer), to: Attributes
  defdelegate create_style(params), to: Attributes
  defdelegate merge_styles(base, override), to: Attributes
  defdelegate set_charset(buffer, slot, charset), to: Attributes
  defdelegate get_charset(buffer, slot), to: Attributes
  defdelegate select_charset(buffer, slot), to: Attributes
  defdelegate get_active_charset(buffer), to: Attributes
  defdelegate translate_char(buffer, char), to: Attributes
  defdelegate set_alternate_screen(buffer, use_alternate), to: Attributes
  defdelegate using_alternate_screen?(buffer), to: Attributes
  defdelegate set_tab_stop(buffer), to: Attributes
  defdelegate clear_tab_stop(buffer), to: Attributes
  defdelegate clear_all_tab_stops(buffer), to: Attributes
  defdelegate reset_tab_stops(buffer), to: Attributes
  defdelegate next_tab_stop(buffer), to: Attributes

  # Backward compatibility aliases for old function names

  # Old Buffer.* modules compatibility
  def write(buffer, x, y, text, style \\ nil),
    do: write_text(buffer, x, y, text, style)

  def scroll(buffer, n), do: scroll_up(buffer, n)
  def erase(buffer), do: clear(buffer)
  def erase_line(buffer, y), do: clear_line(buffer, y)
  def erase_line(buffer, y, _x, _width, _style), do: clear_line(buffer, y)
  def erase_screen(buffer), do: clear(buffer)
  def erase_region(buffer, x, y, w, h), do: clear_region(buffer, x, y, w, h)

  # Selection compatibility
  def start(buffer, x, y), do: start_selection(buffer, x, y)
  def update(buffer, x, y), do: extend_selection(buffer, x, y)
  def get_text(buffer), do: get_selected_text(buffer)
  def contains?(buffer, x, y), do: position_in_selection?(buffer, x, y)

  # Cursor compatibility
  def cursor_position(buffer), do: get_cursor_position(buffer)
  def cursor_position(buffer, x, y), do: set_cursor_position(buffer, x, y)
  def cursor_visible(buffer, visible), do: set_cursor_visible(buffer, visible)
  def cursor_style(buffer, style), do: set_cursor_style(buffer, style)

  # Damage region compatibility (these now live in Manager, but we can provide simple versions)
  def mark_damaged(buffer, x, y, width, height) do
    new_region = {x, y, x + width - 1, y + height - 1}
    existing = Map.get(buffer, :damage_regions, [])
    %{buffer | damage_regions: [new_region | existing] |> Enum.take(10)}
  end

  def get_damage_regions(buffer) do
    Map.get(buffer, :damage_regions, [])
  end

  def clear_damage_regions(buffer) do
    %{buffer | damage_regions: []}
  end

  # Put/get line compatibility
  def put_line(buffer, y, line) when is_list(line) do
    line
    |> Enum.with_index()
    |> Enum.reduce(buffer, fn {cell, x}, acc ->
      case cell do
        %{char: char, style: style} -> write_char(acc, x, y, char, style)
        %{char: char} -> write_char(acc, x, y, char)
        _ -> acc
      end
    end)
  end

  # Get lines from buffer
  def get_lines(buffer) do
    height = get_height(buffer)
    Enum.map(0..(height - 1), fn y -> get_line(buffer, y) end)
  end
end
