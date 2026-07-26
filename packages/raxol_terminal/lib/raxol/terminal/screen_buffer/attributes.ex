defmodule Raxol.Terminal.ScreenBuffer.Attributes do
  @moduledoc """
  Manages buffer attributes including formatting, charset, and cursor state.
  Consolidates: Formatting, TextFormatting, Charset, Cursor functionality.
  """

  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.ScreenBuffer.SharedOperations

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  # Cursor operations

  @doc """
  Sets the cursor position.
  """
  def set_cursor_position(buffer, x, y) do
    x = clamp_to_bounds(x, buffer.width)
    y = clamp_to_bounds(y, buffer.height)
    %{buffer | cursor_position: {x, y}}
  end

  @doc """
  Gets the cursor position.
  """
  def get_cursor_position(buffer) do
    buffer.cursor_position
  end

  @doc """
  Moves the cursor relative to its current position.
  """
  def move_cursor(buffer, dx, dy) do
    {x, y} = buffer.cursor_position
    set_cursor_position(buffer, x + dx, y + dy)
  end

  @doc """
  Sets cursor visibility.
  """
  def set_cursor_visible(buffer, visible) do
    %{buffer | cursor_visible: visible}
  end

  @doc """
  Sets cursor style.
  """
  def set_cursor_style(buffer, style)
      when style in [:block, :underline, :bar] do
    %{buffer | cursor_style: style}
  end

  def set_cursor_style(buffer, _), do: buffer

  @doc """
  Sets cursor blink state.
  """
  def set_cursor_blink(buffer, blink) do
    %{buffer | cursor_blink: blink}
  end

  @doc """
  Saves the current cursor position.
  """
  def save_cursor(buffer) do
    Map.put(buffer, :saved_cursor_position, buffer.cursor_position)
  end

  @doc """
  Restores the saved cursor position.
  """
  def restore_cursor(buffer) do
    case Map.get(buffer, :saved_cursor_position) do
      {x, y} -> set_cursor_position(buffer, x, y)
      nil -> buffer
    end
  end

  # Formatting operations

  @doc """
  Sets the default text style for the buffer.
  """
  def set_default_style(buffer, style) do
    %{buffer | default_style: style}
  end

  @doc """
  Gets the default text style.
  """
  def get_default_style(buffer) do
    buffer.default_style || TextFormatting.new()
  end

  @doc """
  Creates a text style from SGR parameters.
  """
  def create_style(params) do
    # Create a default style and apply SGR parameters
    initial_style = TextFormatting.new()

    Enum.reduce(params, initial_style, fn param, style ->
      TextFormatting.parse_sgr_param(param, style)
    end)
  end

  @doc """
  Merges two styles, with the second taking precedence.
  """
  def merge_styles(base, override) do
    Map.merge(base, override)
  end

  # Charset operations

  @doc """
  Sets the active charset (G0, G1, G2, G3).
  """
  def set_charset(buffer, slot, charset) when slot in [:g0, :g1, :g2, :g3] do
    charsets =
      Map.get(buffer, :charsets, %{
        g0: :ascii,
        g1: :ascii,
        g2: :ascii,
        g3: :ascii
      })

    new_charsets = Map.put(charsets, slot, charset)
    Map.put(buffer, :charsets, new_charsets)
  end

  def set_charset(buffer, _, _), do: buffer

  @doc """
  Gets the active charset for a slot.
  """
  def get_charset(buffer, slot) when slot in [:g0, :g1, :g2, :g3] do
    charsets =
      Map.get(buffer, :charsets, %{
        g0: :ascii,
        g1: :ascii,
        g2: :ascii,
        g3: :ascii
      })

    Map.get(charsets, slot, :ascii)
  end

  def get_charset(_buffer, _), do: :ascii

  @doc """
  Selects which charset slot is active.
  """
  def select_charset(buffer, slot) when slot in [:g0, :g1, :g2, :g3] do
    Map.put(buffer, :active_charset, slot)
  end

  def select_charset(buffer, _), do: buffer

  @doc """
  Gets the currently active charset.
  """
  def get_active_charset(buffer) do
    slot = Map.get(buffer, :active_charset, :g0)
    get_charset(buffer, slot)
  end

  @doc """
  Translates a character according to the active charset.
  """
  def translate_char(buffer, char) do
    charset = get_active_charset(buffer)
    translate_with_charset(char, charset)
  end

  # Screen mode operations

  @doc """
  Switches between main and alternate screen buffers.
  """
  def set_alternate_screen(buffer, use_alternate) do
    %{buffer | alternate_screen: use_alternate}
  end

  @doc """
  Checks if using alternate screen.
  """
  def using_alternate_screen?(buffer) do
    buffer.alternate_screen
  end

  # Tab stop operations

  @doc """
  Sets a tab stop at the current cursor position.
  """
  def set_tab_stop(buffer) do
    {x, _y} = buffer.cursor_position
    tab_stops = Map.get(buffer, :tab_stops, default_tab_stops(buffer.width))
    new_tab_stops = MapSet.put(tab_stops, x)
    Map.put(buffer, :tab_stops, new_tab_stops)
  end

  @doc """
  Clears a tab stop at the current cursor position.
  """
  def clear_tab_stop(buffer) do
    {x, _y} = buffer.cursor_position
    tab_stops = Map.get(buffer, :tab_stops, default_tab_stops(buffer.width))
    new_tab_stops = MapSet.delete(tab_stops, x)
    Map.put(buffer, :tab_stops, new_tab_stops)
  end

  @doc """
  Clears all tab stops.
  """
  def clear_all_tab_stops(buffer) do
    Map.put(buffer, :tab_stops, MapSet.new())
  end

  @doc """
  Resets tab stops to default (every 8 columns).
  """
  def reset_tab_stops(buffer) do
    Map.put(buffer, :tab_stops, default_tab_stops(buffer.width))
  end

  @doc """
  Finds the next tab stop position from the current cursor.
  """
  def next_tab_stop(buffer) do
    {x, _y} = buffer.cursor_position
    tab_stops = Map.get(buffer, :tab_stops, default_tab_stops(buffer.width))

    # Find next tab stop after current position
    tab_stops
    |> Enum.filter(fn stop -> stop > x end)
    |> Enum.min(fn -> buffer.width - 1 end)
  end

  # Private helper functions

  defp translate_with_charset(char, :ascii), do: char

  defp translate_with_charset(char, :dec_special) do
    # DEC Special Graphics character set mapping
    case char do
      "`" -> "◆"
      "a" -> "▒"
      "b" -> "␉"
      "c" -> "␌"
      "d" -> "␍"
      "e" -> "␊"
      "f" -> "°"
      "g" -> "±"
      "h" -> "␤"
      "i" -> "␋"
      "j" -> "┘"
      "k" -> "┐"
      "l" -> "┌"
      "m" -> "└"
      "n" -> "┼"
      "o" -> "⎺"
      "p" -> "⎻"
      "q" -> "─"
      "r" -> "⎼"
      "s" -> "⎽"
      "t" -> "├"
      "u" -> "┤"
      "v" -> "┴"
      "w" -> "┬"
      "x" -> "│"
      "y" -> "≤"
      "z" -> "≥"
      "{" -> "π"
      "|" -> "≠"
      "}" -> "£"
      "~" -> "·"
      _ -> char
    end
  end

  defp translate_with_charset(char, _), do: char

  defp default_tab_stops(width) do
    # Default tab stops every 8 columns
    0..(width - 1)
    |> Enum.filter(fn x -> rem(x, 8) == 0 end)
    |> MapSet.new()
  end

  # === Stub Implementations for Test Compatibility ===
  # These functions are referenced by delegations but not critical for core functionality

  @doc """
  Checks if cursor is visible (stub).
  """
  def cursor_visible?(buffer), do: buffer.cursor_visible

  @doc """
  Checks if cursor is blinking (stub).
  """
  def cursor_blinking?(buffer), do: Map.get(buffer, :cursor_blink, true)

  @doc """
  Gets cursor style (stub).
  """
  def get_cursor_style(buffer), do: buffer.cursor_style

  @doc """
  Gets text style (stub).
  """
  def get_style(buffer), do: buffer.default_style

  @doc """
  Updates text style (stub).
  """
  def update_style(buffer, style), do: %{buffer | default_style: style}

  @doc """
  Gets foreground color (stub).
  """
  def get_foreground(buffer), do: buffer.default_style.foreground

  @doc """
  Gets background color (stub).
  """
  def get_background(buffer), do: buffer.default_style.background

  @doc """
  Starts selection (stub).
  """
  def start_selection(buffer, x, y), do: %{buffer | selection: {x, y, nil, nil}}

  @doc """
  Updates selection (stub).
  """
  def update_selection(buffer, x, y) do
    case buffer.selection do
      {sx, sy, _, _} -> %{buffer | selection: {sx, sy, x, y}}
      nil -> buffer
    end
  end

  @doc """
  Clears selection (stub).
  """
  def clear_selection(buffer), do: %{buffer | selection: nil}

  @doc """
  Gets selection (stub).
  """
  def get_selection(buffer), do: buffer.selection

  @doc """
  Gets selection start (stub).
  """
  def get_selection_start(buffer) do
    case buffer.selection do
      {sx, sy, _, _} -> {sx, sy}
      nil -> nil
    end
  end

  @doc """
  Gets selection end (stub).
  """
  def get_selection_end(buffer) do
    case buffer.selection do
      {_, _, nil, nil} -> nil
      {_, _, ex, ey} -> {ex, ey}
      nil -> nil
    end
  end

  @doc """
  Gets selection boundaries (stub).
  """
  def get_selection_boundaries(buffer), do: buffer.selection

  @doc """
  Checks if position is in selection (stub).
  """
  def in_selection?(buffer, x, y) do
    case buffer.selection do
      {sx, sy, ex, ey} when ex != nil and ey != nil ->
        {start_x, start_y, end_x, end_y} =
          SharedOperations.normalize_selection(sx, sy, ex, ey)

        SharedOperations.position_in_selection?(
          x,
          y,
          start_x,
          start_y,
          end_x,
          end_y
        )

      _ ->
        false
    end
  end

  @doc """
  Gets text in region.
  """
  def get_text_in_region(buffer, x1, y1, x2, y2) do
    case buffer.cells do
      cells when is_list(cells) ->
        start_y = max(0, min(y1, y2))
        end_y = min(length(cells) - 1, max(y1, y2))
        col_range = {max(0, min(x1, x2)), max(x1, x2)}

        if start_y > end_y do
          ""
        else
          cells
          |> Enum.slice(start_y..end_y)
          |> Enum.map(&extract_line_text(&1, col_range))
          |> Enum.reject(&(&1 == ""))
          |> Enum.join("\n")
        end

      _ ->
        ""
    end
  end

  defp extract_line_text(line, {start_x, max_x}) when is_list(line) do
    end_x = min(length(line) - 1, max_x)

    if start_x > end_x do
      ""
    else
      line
      |> Enum.slice(start_x..end_x)
      |> Enum.map_join("", fn
        %{char: char} -> char
        _ -> " "
      end)
      |> String.trim_trailing()
    end
  end

  defp extract_line_text(_line, _col_range), do: ""

  @doc """
  Checks if attribute is set (stub).
  """
  def attribute_set?(_buffer, _attr), do: false

  @doc """
  Gets set attributes (stub).
  """
  def get_set_attributes(_buffer), do: []

  @doc """
  Applies single shift (stub).
  """
  def apply_single_shift(buffer, _set), do: buffer

  @doc """
  Gets single shift state (stub).
  """
  def get_single_shift(_buffer), do: nil

  @doc """
  Gets current G set (stub).
  """
  def get_current_g_set(_buffer), do: 0

  @doc """
  Designates charset (stub).
  """
  def designate_charset(buffer, _set, _charset), do: buffer

  @doc """
  Gets designated charset (stub).
  """
  def get_designated_charset(_buffer, _set), do: :us

  @doc """
  Invokes G set (stub).
  """
  def invoke_g_set(buffer, _set), do: buffer

  @doc """
  Resets all attributes to defaults (stub).
  """
  def reset_all_attributes(buffer) do
    %{buffer | default_style: TextFormatting.default_style()}
  end

  @doc """
  Resets specific attribute (stub).
  """
  def reset_attribute(buffer, _attr), do: buffer

  @doc """
  Resets charset state (stub).
  """
  def reset_charset_state(buffer), do: buffer

  @doc """
  Checks if selection is active (stub).
  """
  def selection_active?(buffer), do: buffer.selection != nil

  @doc """
  Sets specific attribute (stub).
  """
  def set_attribute(buffer, _attr), do: buffer

  @doc """
  Sets background color (stub).
  """
  def set_background(buffer, color) do
    style = Map.put(buffer.default_style, :background, color)
    %{buffer | default_style: style}
  end

  @doc """
  Sets cursor visibility (stub).
  """
  def set_cursor_visibility(buffer, visible) do
    %{buffer | cursor_visible: visible}
  end

  @doc """
  Sets foreground color (stub).
  """
  def set_foreground(buffer, color) do
    style = Map.put(buffer.default_style, :foreground, color)
    %{buffer | default_style: style}
  end
end
