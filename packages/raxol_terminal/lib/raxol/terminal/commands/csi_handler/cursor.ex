defmodule Raxol.Terminal.Commands.CSIHandler.Cursor do
  @moduledoc """
  Handles cursor-related CSI sequences.
  """

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @doc """
  Handles cursor movement commands.
  """
  @spec handle_command(term(), list(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def handle_command(emulator, params, command) do
    # Delegate to the appropriate cursor movement handler
    case command do
      "A" -> handle_cursor_up(emulator, get_param(params, 0, 1))
      "B" -> handle_cursor_down(emulator, get_param(params, 0, 1))
      "C" -> handle_cursor_forward(emulator, get_param(params, 0, 1))
      "D" -> handle_cursor_backward(emulator, get_param(params, 0, 1))
      "H" -> handle_cursor_position(emulator, params)
      "G" -> handle_cursor_column(emulator, get_param(params, 0, 1))
      # Alternative position command
      "f" -> handle_cursor_position(emulator, params)
      "s" -> handle_save_cursor(emulator)
      "u" -> handle_restore_cursor(emulator)
      _ -> {:error, :unknown_cursor_command}
    end
  end

  defp handle_cursor_up(emulator, amount) do
    cursor = emulator.cursor
    {current_row, current_col} = get_cursor_position(cursor)
    new_row = max(0, current_row - amount)
    updated_cursor = update_cursor_position(cursor, new_row, current_col)
    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp handle_cursor_down(emulator, amount) do
    cursor = emulator.cursor
    {current_row, current_col} = get_cursor_position(cursor)
    new_row = min(emulator.height - 1, current_row + amount)
    updated_cursor = update_cursor_position(cursor, new_row, current_col)
    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp handle_cursor_forward(emulator, amount) do
    cursor = emulator.cursor
    {current_row, current_col} = get_cursor_position(cursor)
    new_col = min(emulator.width - 1, current_col + amount)
    updated_cursor = update_cursor_position(cursor, current_row, new_col)
    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp handle_cursor_backward(emulator, amount) do
    cursor = emulator.cursor
    {current_row, current_col} = get_cursor_position(cursor)
    new_col = max(0, current_col - amount)
    updated_cursor = update_cursor_position(cursor, current_row, new_col)
    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp handle_cursor_position(emulator, params) do
    # Convert from 1-based to 0-based
    row = get_param(params, 0, 1) - 1
    # Convert from 1-based to 0-based
    col = get_param(params, 1, 1) - 1

    # Clamp to valid ranges
    bounded_row = clamp_to_bounds(row, emulator.height)
    bounded_col = clamp_to_bounds(col, emulator.width)

    cursor = emulator.cursor

    # Handle both full cursor struct and minimal cursor (map with position tuple)
    updated_cursor =
      case cursor do
        %{row: _, col: _} = c ->
          # Full cursor struct
          updated = %{c | row: bounded_row, col: bounded_col}

          if Map.has_key?(c, :position) do
            Map.put(updated, :position, {bounded_row, bounded_col})
          else
            updated
          end

        _ ->
          # Minimal cursor - just update position
          %{position: {bounded_row, bounded_col}}
      end

    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp handle_cursor_column(emulator, column) do
    cursor = emulator.cursor
    {current_row, _current_col} = get_cursor_position(cursor)
    # Convert to 0-based
    new_col = clamp_to_bounds(column - 1, emulator.width)
    updated_cursor = update_cursor_position(cursor, current_row, new_col)
    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp handle_save_cursor(emulator) do
    cursor = emulator.cursor
    {current_row, current_col} = get_cursor_position(cursor)

    updated_cursor =
      case cursor do
        %{row: _, col: _} = c ->
          # Full cursor struct
          %{
            c
            | saved_row: current_row,
              saved_col: current_col,
              saved_position: {current_row, current_col}
          }

        _ ->
          # Minimal cursor
          %{
            position: {current_row, current_col},
            saved_position: {current_row, current_col}
          }
      end

    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp handle_restore_cursor(emulator) do
    cursor = emulator.cursor

    {new_row, new_col} =
      case cursor do
        %{saved_row: row, saved_col: col} when row != nil and col != nil ->
          {row, col}

        %{saved_position: {row, col}} ->
          {row, col}

        _ ->
          # Default to origin if no saved position
          {0, 0}
      end

    updated_cursor = update_cursor_position(cursor, new_row, new_col)
    {:ok, %{emulator | cursor: updated_cursor}}
  end

  defp get_param(params, index, default) do
    case Enum.at(params, index) do
      nil -> default
      val when is_integer(val) -> val
      _ -> default
    end
  end

  # Helper functions to handle both full and minimal cursor structs
  defp get_cursor_position(cursor) do
    case cursor do
      %{row: row, col: col} when is_integer(row) and is_integer(col) ->
        {row, col}

      %{position: {row, col}} ->
        {row, col}

      _ ->
        {0, 0}
    end
  end

  defp update_cursor_position(cursor, new_row, new_col) do
    case cursor do
      %{row: _, col: _} = c ->
        # Full cursor struct - update both row/col and position if it exists
        c
        |> Map.put(:row, new_row)
        |> Map.put(:col, new_col)
        |> then(fn cursor ->
          if Map.has_key?(cursor, :position) do
            Map.put(cursor, :position, {new_row, new_col})
          else
            cursor
          end
        end)

      _ ->
        # Minimal cursor - just update position
        %{position: {new_row, new_col}}
    end
  end
end
