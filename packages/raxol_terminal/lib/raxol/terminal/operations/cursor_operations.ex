defmodule Raxol.Terminal.Operations.CursorOperations do
  @moduledoc """
  Implements cursor-related operations for the terminal emulator.
  """

  alias Raxol.Terminal.Cursor.Manager, as: CursorManager

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  def get_cursor_position(emulator) do
    # Returns {row, col} format for consistency
    {row, col} = CursorManager.get_position(emulator.cursor)
    {row, col}
  end

  def set_cursor_position(emulator, row, col) do
    # Get emulator dimensions for bounds checking
    width = Raxol.Terminal.Emulator.get_width(emulator)
    height = Raxol.Terminal.Emulator.get_height(emulator)

    # Clamp position to screen bounds
    clamped_row = clamp_to_bounds(row, height)
    clamped_col = clamp_to_bounds(col, width)

    # CursorManager.set_position expects {row, col} tuple and returns updated cursor
    updated_cursor =
      CursorManager.set_position(emulator.cursor, {clamped_row, clamped_col})

    %{emulator | cursor: updated_cursor}
  end

  def get_cursor_style(emulator) do
    CursorManager.get_style(emulator.cursor)
  end

  def set_cursor_style(emulator, style) do
    # Validate the style - only allow valid cursor styles
    valid_styles = [:block, :underline, :bar]

    case style in valid_styles do
      true ->
        updated_cursor = CursorManager.set_style(emulator.cursor, style)
        %{emulator | cursor: updated_cursor}

      false ->
        # If style is invalid, do nothing (maintain current style)
        emulator
    end
  end

  def cursor_visible?(emulator) do
    CursorManager.get_visibility(emulator.cursor)
  end

  def set_cursor_visibility(emulator, visible) do
    updated_cursor = CursorManager.set_visibility(emulator.cursor, visible)
    %{emulator | cursor: updated_cursor}
  end

  def cursor_blinking?(emulator) do
    CursorManager.get_blink(emulator.cursor)
  end

  def set_cursor_blink(emulator, blinking) do
    updated_cursor = CursorManager.set_blink(emulator.cursor, blinking)
    %{emulator | cursor: updated_cursor}
  end

  def toggle_visibility(emulator) do
    current_visible = CursorManager.get_visibility(emulator.cursor)

    updated_cursor =
      CursorManager.set_visibility(emulator.cursor, !current_visible)

    %{emulator | cursor: updated_cursor}
  end

  def toggle_blink(emulator) do
    current_blinking = CursorManager.get_blink(emulator.cursor)
    updated_cursor = CursorManager.set_blink(emulator.cursor, !current_blinking)
    %{emulator | cursor: updated_cursor}
  end

  def set_blink_rate(emulator, rate) do
    # For now, just set the blink state based on rate
    blinking = rate > 0
    updated_cursor = CursorManager.set_blink(emulator.cursor, blinking)
    %{emulator | cursor: updated_cursor}
  end

  def update_blink(emulator) do
    case CursorManager.get_blink(emulator.cursor) do
      true ->
        # Toggle the blink state for blinking cursors
        current_visible = CursorManager.get_visibility(emulator.cursor)
        CursorManager.set_visibility(emulator.cursor, !current_visible)

      false ->
        # For non-blinking cursors, ensure they're visible
        CursorManager.set_visibility(emulator.cursor, true)
    end

    emulator
  end

  # Function aliases expected by tests
  def visible?(emulator) do
    cursor_visible?(emulator)
  end

  def blinking?(emulator) do
    cursor_blinking?(emulator)
  end

  def move_cursor(emulator, row, col) do
    set_cursor_position(emulator, row, col)
  end
end
