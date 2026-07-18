defmodule Raxol.Terminal.Integration.Buffer do
  @moduledoc """
  Handles buffer and cursor management for the terminal.
  """

  alias Raxol.Terminal.{
    Buffer.Scroll,
    Integration.State,
    ScreenBuffer.Manager
  }

  alias Raxol.Terminal.Cursor.Manager, as: CursorManager

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @doc """
  Writes text to the terminal buffer.
  """
  def write(%State{} = state, text) do
    # Update the buffer manager with the new text
    {:ok, buffer_manager} = Manager.write(state.buffer_manager, text)

    # Update the cursor position - handle different cursor_manager types
    cursor_manager =
      case state.cursor_manager do
        nil ->
          nil

        cursor when is_map(cursor) ->
          # If it's a Cursor.Manager struct, use its update function
          {x, y} = CursorManager.get_position(cursor)
          CursorManager.set_position(cursor, {x + String.length(text), y})

        cursor ->
          # For other types, return as-is
          cursor
      end

    # Update the state
    State.update(state,
      buffer_manager: buffer_manager,
      cursor_manager: cursor_manager
    )
  end

  @doc """
  Clears the terminal buffer.
  """
  def clear(%State{} = state) do
    # Clear the buffer manager
    buffer_manager = Manager.clear(state.buffer_manager)

    # Reset the cursor position - handle different cursor_manager types
    cursor_manager =
      case state.cursor_manager do
        nil ->
          nil

        cursor when is_map(cursor) ->
          CursorManager.set_position(cursor, {0, 0})

        cursor ->
          cursor
      end

    # Update the state
    State.update(state,
      buffer_manager: buffer_manager,
      cursor_manager: cursor_manager
    )
  end

  @doc """
  Scrolls the terminal buffer.
  """
  def scroll(%State{} = state, direction, amount \\ 1) do
    # Update the scroll buffer
    scroll_buffer = Scroll.scroll(state.scroll_buffer, direction, amount)

    # Update the buffer manager's visible region (expects non_neg_integer, not region)
    # Scroll.get_visible_region always returns {offset, height}
    {scroll_offset, _height} = Scroll.get_visible_region(scroll_buffer)

    buffer_manager =
      Manager.update_visible_region(
        state.buffer_manager,
        scroll_offset
      )

    # Update the state
    State.update(state,
      buffer_manager: buffer_manager,
      scroll_buffer: scroll_buffer
    )
  end

  @doc """
  Moves the cursor to a specific position.
  """
  def move_cursor(%State{} = state, x, y) do
    # Update the cursor position - handle different cursor_manager types
    cursor_manager =
      case state.cursor_manager do
        nil ->
          nil

        cursor when is_map(cursor) ->
          CursorManager.set_position(cursor, {x, y})

        cursor ->
          cursor
      end

    # Update the state
    State.update(state, cursor_manager: cursor_manager)
  end

  @doc """
  Gets the current cursor position.
  """
  def get_cursor_position(%State{} = state) do
    case state.cursor_manager do
      nil ->
        {0, 0}

      cursor when is_map(cursor) ->
        CursorManager.get_position(cursor)

      _cursor ->
        {0, 0}
    end
  end

  @doc """
  Gets the current visible content.
  """
  def get_visible_content(%State{} = state) do
    Manager.get_visible_content(state.buffer_manager)
  end

  @doc """
  Gets the current scroll position.
  """
  def get_scroll_position(%State{} = state) do
    Scroll.get_position(state.scroll_buffer)
  end

  @doc """
  Gets the total number of lines in the buffer.
  """
  def get_total_lines(%State{} = state) do
    Manager.get_total_lines(state.buffer_manager)
  end

  @doc """
  Gets the number of visible lines.
  """
  def get_visible_lines(%State{} = state) do
    Manager.get_visible_lines(state.buffer_manager)
  end

  @doc """
  Resizes the terminal buffer.
  """
  def resize(%State{} = state, width, height) do
    # Resize the buffer manager
    buffer_manager = Manager.resize(state.buffer_manager, width, height)

    # Update the scroll buffer
    scroll_buffer = Scroll.resize(state.scroll_buffer, height)

    # Constrain cursor position to new dimensions
    cursor_manager =
      case state.cursor_manager do
        nil ->
          nil

        cursor when is_map(cursor) ->
          {x, y} = CursorManager.get_position(cursor)
          # Constrain to new bounds
          new_x = clamp_to_bounds(x, width)
          new_y = clamp_to_bounds(y, height)
          CursorManager.set_position(cursor, {new_x, new_y})

        cursor ->
          cursor
      end

    # Update the state
    State.update(state,
      buffer_manager: buffer_manager,
      scroll_buffer: scroll_buffer,
      cursor_manager: cursor_manager
    )
  end
end
