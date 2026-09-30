defmodule Raxol.Terminal.Commands.CursorUtils do
  @moduledoc """
  Shared utility functions for cursor handling commands.
  Eliminates code duplication between CursorHandler and CSIHandler.
  """

  @doc """
  Calculates new cursor position based on direction and movement amount.
  Ensures the new position is within the emulator bounds.

  ## Parameters
    - current_pos: Current {row, col} position
    - direction: Direction to move (:up, :down, :left, :right)
    - amount: Number of positions to move
    - width: Emulator width for boundary checking
    - height: Emulator height for boundary checking

  ## Returns
    New {row, col} position clamped to bounds
  """
  @spec calculate_new_cursor_position(
          {non_neg_integer(), non_neg_integer()},
          atom(),
          non_neg_integer(),
          pos_integer(),
          pos_integer()
        ) :: {non_neg_integer(), non_neg_integer()}
  def calculate_new_cursor_position(
        {row, col},
        direction,
        amount,
        width,
        height
      ) do
    case direction do
      :up -> {max(0, row - amount), col}
      :down -> {min(height - 1, row + amount), col}
      :left -> {row, max(0, col - amount)}
      :right -> {row, min(width - 1, col + amount)}
    end
  end

  @doc """
  Saves the current cursor position into the emulator state (`CSI s`).

  As in xterm, the save also fills the screen's DECSC slot, so an `ESC 8`
  after `CSI s` restores it rather than falling back to the power-up state.
  """
  def save_cursor_position(emulator) do
    emulator = Raxol.Terminal.ControlCodes.handle_decsc(emulator)
    cursor = emulator.cursor

    updated_cursor = %{
      cursor
      | saved_row: cursor.row,
        saved_col: cursor.col,
        saved_position: {cursor.row, cursor.col}
    }

    saved_cursor = cursor
    %{emulator | cursor: updated_cursor, saved_cursor: saved_cursor}
  end

  @doc """
  Restores a previously saved cursor position from the emulator state.
  """
  def restore_cursor_position(emulator) do
    case Map.get(emulator, :saved_cursor) do
      nil ->
        cursor = emulator.cursor

        {new_row, new_col} =
          case {cursor.saved_row, cursor.saved_col} do
            {nil, nil} -> {cursor.row, cursor.col}
            {row, col} -> {row, col}
          end

        updated_cursor = %{
          cursor
          | row: new_row,
            col: new_col,
            position: {new_row, new_col}
        }

        %{emulator | cursor: updated_cursor}

      saved_cursor ->
        row = saved_cursor.row
        col = saved_cursor.col

        updated_cursor = %{
          emulator.cursor
          | row: row,
            col: col,
            position: {row, col},
            shape: Map.get(saved_cursor, :shape, emulator.cursor.shape),
            visible: Map.get(saved_cursor, :visible, emulator.cursor.visible)
        }

        %{emulator | cursor: updated_cursor}
    end
  end
end
