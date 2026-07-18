defmodule Raxol.Terminal.Commands.CSIHandler.CursorMovementHandler do
  @moduledoc """
  Handles cursor movement operations for CSI sequences.

  Provides full implementation of cursor movement commands integrating with the
  existing Raxol.Terminal.Cursor module for consistent cursor state management.

  Supports all standard VT100/ANSI cursor movement sequences:
  - Cursor Up (CUU)
  - Cursor Down (CUD)
  - Cursor Forward/Right (CUF)
  - Cursor Backward/Left (CUB)
  - Cursor Position (CUP)
  - Horizontal and Vertical Position Absolute (HPA/VPA)
  """

  alias Raxol.Core.Runtime.Log
  alias Raxol.Terminal.Commands.CSIHandler.Cursor
  alias Raxol.Terminal.Emulator

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @type emulator :: Emulator.t()
  @type cursor_amount :: non_neg_integer()
  @type cursor_position :: {non_neg_integer(), non_neg_integer()}

  @doc """
  Moves cursor up by specified amount.
  CUU - Cursor Up
  """
  @spec handle_cursor_up(emulator(), cursor_amount()) :: {:ok, emulator()}
  def handle_cursor_up(emulator, amount) do
    # Sanitize amount - if 0, don't move
    case amount do
      0 ->
        # No movement for 0
        {:ok, emulator}

      n when n > 0 ->
        # Use CSIHandler.Cursor functions which handle direct row/col fields
        {:ok, updated_emulator} = Cursor.handle_command(emulator, [n], "A")
        Log.debug("Cursor moved up by #{n}")
        {:ok, updated_emulator}

      _ ->
        # Default to 1 for invalid amounts
        {:ok, updated_emulator} = Cursor.handle_command(emulator, [1], "A")
        Log.debug("Cursor moved up by 1 (default)")
        {:ok, updated_emulator}
    end
  rescue
    error ->
      Log.error("Cursor up movement failed: #{inspect(error)}")
      # Return original emulator on error
      {:ok, emulator}
  end

  @doc """
  Moves cursor down by specified amount.
  CUD - Cursor Down
  """
  @spec handle_cursor_down(emulator(), cursor_amount()) :: {:ok, emulator()}
  def handle_cursor_down(emulator, amount) do
    move_amount = max(1, amount)

    {:ok, updated_emulator} =
      Cursor.handle_command(emulator, [move_amount], "B")

    Log.debug("Cursor moved down by #{move_amount}")
    {:ok, updated_emulator}
  rescue
    error ->
      Log.error("Cursor down movement failed: #{inspect(error)}")
      {:ok, emulator}
  end

  @doc """
  Moves cursor forward (right) by specified amount.
  CUF - Cursor Forward
  """
  @spec handle_cursor_forward(emulator(), cursor_amount()) :: {:ok, emulator()}
  def handle_cursor_forward(emulator, amount) do
    move_amount = max(1, amount)

    {:ok, updated_emulator} =
      Cursor.handle_command(emulator, [move_amount], "C")

    Log.debug("Cursor moved forward by #{move_amount}")
    {:ok, updated_emulator}
  rescue
    error ->
      Log.error("Cursor forward movement failed: #{inspect(error)}")
      {:ok, emulator}
  end

  @doc """
  Moves cursor backward (left) by specified amount.
  CUB - Cursor Backward
  """
  @spec handle_cursor_backward(emulator(), cursor_amount()) :: {:ok, emulator()}
  def handle_cursor_backward(emulator, amount) do
    move_amount = max(1, amount)

    {:ok, updated_emulator} =
      Cursor.handle_command(emulator, [move_amount], "D")

    Log.debug("Cursor moved backward by #{move_amount}")
    {:ok, updated_emulator}
  rescue
    error ->
      Log.error("Cursor backward movement failed: #{inspect(error)}")
      {:ok, emulator}
  end

  @doc """
  Sets cursor position from parameter list.
  CUP - Cursor Position
  """
  @spec handle_cursor_position(emulator(), [non_neg_integer()]) ::
          {:ok, emulator()}
  def handle_cursor_position(emulator, params) do
    # Parse parameters, handling semicolon-separated format
    parsed_params = parse_semicolon_params(params)

    # Parse row and column from params (1-indexed in ANSI, 0-indexed internally)
    row = get_param_or_default(parsed_params, 0, 1) - 1
    col = get_param_or_default(parsed_params, 1, 1) - 1

    handle_cursor_position_direct(emulator, row, col)
  rescue
    error ->
      Log.error("Cursor position from params failed: #{inspect(error)}")

      {:ok, emulator}
  end

  @doc """
  Sets cursor position directly with row and column.
  CUP - Cursor Position (Direct)
  """
  @spec handle_cursor_position(emulator(), non_neg_integer(), non_neg_integer()) ::
          {:ok, emulator()}
  def handle_cursor_position(emulator, row, col) do
    # Convert from 1-based ANSI to 0-based internal coordinates
    zero_based_row = max(0, row - 1)
    zero_based_col = max(0, col - 1)
    handle_cursor_position_direct(emulator, zero_based_row, zero_based_col)
  end

  @doc """
  Sets cursor position directly without parameter validation.
  Used internally for absolute positioning.
  """
  @spec handle_cursor_position_direct(
          emulator(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, emulator()}
  def handle_cursor_position_direct(emulator, row, col) do
    # Ensure coordinates are within bounds
    bounded_row = clamp_to_bounds(row, emulator.height)
    bounded_col = clamp_to_bounds(col, emulator.width)

    # Update cursor position directly using the established pattern
    new_cursor = %{
      emulator.cursor
      | position: {bounded_col, bounded_row},
        row: bounded_row,
        col: bounded_col
    }

    updated_emulator = %{emulator | cursor: new_cursor}

    Log.debug("Cursor position set to (#{bounded_col}, #{bounded_row})")

    {:ok, updated_emulator}
  rescue
    error ->
      Log.error("Cursor position direct failed: #{inspect(error)}")
      {:ok, emulator}
  end

  @doc """
  Sets cursor to specific column (Horizontal Position Absolute).
  HPA - Horizontal Position Absolute
  """
  @spec handle_cursor_column(emulator(), non_neg_integer()) :: {:ok, emulator()}
  def handle_cursor_column(emulator, column) do
    # Convert 1-indexed to 0-indexed and bound check
    target_col = clamp_to_bounds(column - 1, emulator.width)
    {_current_col, current_row} = emulator.cursor.position

    # Set position to new column, same row
    handle_cursor_position_direct(emulator, current_row, target_col)
  rescue
    error ->
      Log.error("Cursor column positioning failed: #{inspect(error)}")
      {:ok, emulator}
  end

  @doc """
  Sets cursor to specific row (Vertical Position Absolute).
  VPA - Vertical Position Absolute
  """
  @spec handle_cursor_row(emulator(), non_neg_integer()) :: {:ok, emulator()}
  def handle_cursor_row(emulator, row) do
    # Convert 1-indexed to 0-indexed and bound check
    target_row = clamp_to_bounds(row - 1, emulator.height)
    {current_col, _current_row} = emulator.cursor.position

    # Set position to same column, new row
    handle_cursor_position_direct(emulator, target_row, current_col)
  rescue
    error ->
      Log.error("Cursor row positioning failed: #{inspect(error)}")
      {:ok, emulator}
  end

  @doc """
  Gets the current cursor position.
  """
  @spec get_cursor_position(emulator()) :: cursor_position()
  def get_cursor_position(emulator) do
    emulator.cursor.position
  end

  @doc """
  Checks if cursor is at the edge of the screen.
  """
  @spec cursor_at_edge?(emulator()) :: %{
          top: boolean(),
          bottom: boolean(),
          left: boolean(),
          right: boolean()
        }
  def cursor_at_edge?(emulator) do
    {x, y} = emulator.cursor.position

    %{
      top: y == 0,
      bottom: y == emulator.height - 1,
      left: x == 0,
      right: x == emulator.width - 1
    }
  end

  # Private Implementation

  defp get_param_or_default(params, index, default) when is_list(params) do
    case Enum.at(params, index) do
      nil -> default
      # ANSI treats 0 as default for position commands
      0 -> default
      value when is_integer(value) -> value
      _ -> default
    end
  end

  defp get_param_or_default(_params, _index, default), do: default

  defp parse_semicolon_params(params) when is_list(params) do
    params
    # Remove semicolon characters (59)
    |> Enum.reject(&(&1 == ?;))
    # Keep only integers
    |> Enum.filter(&is_integer/1)
  end

  defp parse_semicolon_params(params), do: params
end
