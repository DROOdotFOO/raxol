defmodule Raxol.Terminal.Cursor.Movement do
  @moduledoc """
  Handles cursor movement operations for the terminal cursor.
  Extracted from Raxol.Terminal.Cursor.Manager to reduce file size.
  """

  alias Raxol.Terminal.Cursor.Manager

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @doc """
  Moves the cursor up by the specified number of lines.
  """
  def move_up(cursor, lines, _width, _height) do
    # Handle emulator cursor format (with :position field)
    case cursor do
      %{position: {row, col}} ->
        # This is the emulator's cursor format (row, col)
        new_row = max(0, row - lines)
        %{cursor | position: {new_row, col}}

      %{row: row, col: col} ->
        # This is the cursor manager format
        new_row = max(cursor.top_margin || 0, row - lines)
        %{cursor | row: new_row, col: col, position: {new_row, col}}

      _ ->
        # Fallback for other formats
        cursor
    end
  end

  @doc """
  Moves the cursor down by the specified number of lines.
  """
  def move_down(%Manager{} = cursor, lines, _width, _height) do
    new_row = min(cursor.bottom_margin, cursor.row + lines)
    %{cursor | row: new_row, col: cursor.col, position: {new_row, cursor.col}}
  end

  def move_down(cursor, lines, _width, _height) do
    # Handle emulator cursor format (with :position field)
    case cursor do
      %{position: {row, col}} ->
        # This is the emulator's cursor format (row, col)
        new_row = row + lines
        %{cursor | position: {new_row, col}}

      %{row: row, col: col} ->
        # This is the cursor manager format
        new_row = min(cursor.bottom_margin || 24, row + lines)
        %{cursor | row: new_row, col: col, position: {new_row, col}}

      _ ->
        # Fallback for other formats
        cursor
    end
  end

  @doc """
  Moves the cursor left by the specified number of columns.
  """
  def move_left(cursor, cols, _width, _height) do
    # Handle emulator cursor format (with :position field)
    case cursor do
      %{position: {row, col}} ->
        # This is the emulator's cursor format (row, col)
        new_col = max(0, col - cols)
        %{cursor | position: {row, new_col}}

      %{row: row, col: col} ->
        # This is the cursor manager format
        new_col = max(0, col - cols)
        %{cursor | col: new_col, row: row, position: {row, new_col}}

      _ ->
        # Fallback for other formats
        cursor
    end
  end

  @doc """
  Moves the cursor right by the specified number of columns.
  """
  def move_right(cursor, cols, _width, _height) do
    # Handle emulator cursor format (with :position field)
    case cursor do
      %{position: {row, col}} ->
        # This is the emulator's cursor format (row, col)
        new_col = col + cols
        %{cursor | position: {row, new_col}}

      %{row: row, col: col} ->
        # This is the cursor manager format
        new_col = col + cols
        %{cursor | col: new_col, row: row, position: {row, new_col}}

      _ ->
        # Fallback for other formats
        cursor
    end
  end

  @doc """
  Moves the cursor to the beginning of the line.
  """
  def move_to_line_start(cursor) do
    # Handle emulator cursor format (with :position field)
    case cursor do
      %{position: {row, _col}} ->
        # This is the emulator's cursor format (row, col)
        %{cursor | position: {row, 0}}

      %{row: row} ->
        # This is the cursor manager format
        %{cursor | col: 0, row: row, position: {row, 0}}

      _ ->
        # Fallback for other formats
        cursor
    end
  end

  @doc """
  Moves the cursor to the end of the line.
  """
  def move_to_line_end(cursor, line_width) do
    %{cursor | col: line_width - 1, position: {cursor.row, line_width - 1}}
  end

  @doc """
  Moves the cursor to the specified column.
  """
  def move_to_column(cursor, column) do
    %{cursor | col: column, position: {cursor.row, column}}
  end

  @doc """
  Moves the cursor to the specified column with bounds clamping.
  """
  @spec move_to_column(
          Manager.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Manager.t()
  def move_to_column(cursor, column, width, _height) do
    clamped_col = clamp_to_bounds(column, width)
    %{cursor | col: clamped_col, position: {cursor.row, clamped_col}}
  end

  @doc """
  Constrains the cursor position to within the specified bounds.
  """
  @spec constrain_position(Manager.t(), non_neg_integer(), non_neg_integer()) ::
          Manager.t()
  def constrain_position(cursor, width, height) do
    clamped_row = clamp_to_bounds(cursor.row, height)
    clamped_col = clamp_to_bounds(cursor.col, width)

    %{
      cursor
      | row: clamped_row,
        col: clamped_col,
        position: {clamped_row, clamped_col}
    }
  end

  @doc """
  Moves the cursor to the specified line.
  """
  def move_to_line(cursor, line) do
    %{cursor | row: line, position: {line, cursor.col}}
  end

  @doc """
  Moves the cursor to the home position (0, 0).
  """
  def move_home(cursor, _width, _height) do
    %{cursor | col: 0, row: 0, position: {0, 0}}
  end

  @doc """
  Moves the cursor to the next tab stop.
  """
  def move_to_next_tab(cursor, tab_size, width, _height) do
    next_tab = div(cursor.col + tab_size, tab_size) * tab_size
    new_col = min(next_tab, width - 1)
    %{cursor | col: new_col, position: {cursor.row, new_col}}
  end

  @doc """
  Moves the cursor to the previous tab stop.
  """
  def move_to_prev_tab(cursor, tab_size, _width, _height) do
    prev_tab = div(cursor.col - 1, tab_size) * tab_size
    new_col = max(prev_tab, 0)
    %{cursor | col: new_col, position: {cursor.row, new_col}}
  end

  @doc """
  Moves the cursor to a specific position with bounds clamping.
  """
  def move_to_bounded(cursor, row, col, width, height) do
    clamped_row = clamp_to_bounds(row, height)
    clamped_col = clamp_to_bounds(col, width)

    %{
      cursor
      | row: clamped_row,
        col: clamped_col,
        position: {clamped_row, clamped_col}
    }
  end
end
