defmodule Raxol.Terminal.Buffer.Cursor do
  @moduledoc """
  Manages cursor state and operations for the screen buffer.
  This module handles cursor position, visibility, style, and blink state.
  """

  alias Raxol.Terminal.ScreenBuffer

  import Raxol.Terminal.Bounds, only: [clamp_to_bounds: 2]

  @type cursor_style :: :block | :underline | :bar

  @type t :: %__MODULE__{
          position: {non_neg_integer(), non_neg_integer()},
          visible: boolean(),
          style: cursor_style(),
          blink_state: boolean()
        }

  defstruct [
    :position,
    :visible,
    :style,
    :blink_state
  ]

  @doc """
  Initializes a new cursor state with default values.
  """
  def init do
    %__MODULE__{
      position: {0, 0},
      visible: true,
      style: :block,
      blink_state: true
    }
  end

  @doc """
  Sets the cursor position.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `x` - The x-coordinate (column)
  * `y` - The y-coordinate (row)

  ## Returns

  The updated screen buffer with new cursor position.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.set_position(buffer, 10, 5)
      iex> Cursor.get_position(buffer)
      {10, 5}
  """
  def set_position(buffer, x, y) do
    case buffer do
      %{cursor: cursor} ->
        new_cursor = %{cursor | position: {x, y}}
        %{buffer | cursor: new_cursor}

      %{cursor_position: _} ->
        %{buffer | cursor_position: {x, y}}

      _ ->
        buffer
    end
  end

  @doc """
  Gets the current cursor position.

  ## Parameters

  * `buffer` - The screen buffer to query

  ## Returns

  A tuple {x, y} representing the cursor position.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> Cursor.get_position(buffer)
      {0, 0}
  """
  def get_position(%{cursor: %{position: position}}), do: position
  def get_position(%{cursor_position: position}), do: position
  def get_position(_buffer), do: {0, 0}

  @doc """
  Sets the cursor visibility.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `visible` - Whether the cursor should be visible

  ## Returns

  The updated screen buffer with new cursor visibility.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.set_visibility(buffer, false)
      iex> Cursor.visible?(buffer)
      false
  """
  def set_visibility(buffer, visible) do
    %{buffer | cursor_visible: visible}
  end

  @doc """
  Checks if the cursor is visible.

  ## Parameters

  * `buffer` - The screen buffer to query

  ## Returns

  A boolean indicating cursor visibility.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> Cursor.visible?(buffer)
      true
  """
  def visible?(%ScreenBuffer{} = buffer) do
    buffer.cursor_visible
  end

  def visible?(%__MODULE__{} = cursor) do
    cursor.visible
  end

  @doc """
  Sets the cursor style.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `style` - The cursor style (:block, :underline, :bar)

  ## Returns

  The updated screen buffer with new cursor style.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.set_style(buffer, :underline)
      iex> Cursor.get_style(buffer)
      :underline
  """
  def set_style(buffer, style) do
    Map.put(buffer, :cursor_style, style)
  end

  @doc """
  Gets the current cursor style.

  ## Parameters

  * `buffer` - The screen buffer to query

  ## Returns

  The current cursor style.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> Cursor.get_style(buffer)
      :block
  """
  def get_style(buffer) do
    buffer.cursor.style
  end

  @doc """
  Sets the cursor blink state.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `blink` - Whether the cursor should blink

  ## Returns

  The updated screen buffer with new cursor blink state.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.set_blink(buffer, false)
      iex> Cursor.blinking?(buffer)
      false
  """
  def set_blink(buffer, blink) do
    Map.put(buffer, :cursor_blink, blink)
  end

  @doc """
  Checks if the cursor is blinking.

  ## Parameters

  * `buffer` - The screen buffer to query

  ## Returns

  A boolean indicating if the cursor is blinking.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> Cursor.blinking?(buffer)
      true
  """
  def blinking?(%ScreenBuffer{} = _buffer) do
    # ScreenBuffer doesn't have cursor blink state, default to false
    false
  end

  def blinking?(%__MODULE__{} = cursor) do
    cursor.blink_state
  end

  @doc """
  Moves the cursor up by the specified number of lines.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `lines` - Number of lines to move up

  ## Returns

  The updated screen buffer with new cursor position.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.move_up(buffer, 2)
      iex> Cursor.get_position(buffer)
      {0, 0}  # Cursor stays at top
  """
  def move_up(buffer, lines) do
    {x, y} = buffer.cursor.position
    new_y = max(0, y - lines)
    set_position(buffer, x, new_y)
  end

  @doc """
  Moves the cursor down by the specified number of lines.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `lines` - Number of lines to move down

  ## Returns

  The updated screen buffer with new cursor position.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.move_down(buffer, 2)
      iex> Cursor.get_position(buffer)
      {0, 2}
  """
  def move_down(buffer, lines) do
    {x, y} = buffer.cursor.position
    new_y = min(buffer.height - 1, y + lines)
    set_position(buffer, x, new_y)
  end

  @doc """
  Moves the cursor forward by the specified number of columns.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `columns` - Number of columns to move forward

  ## Returns

  The updated screen buffer with new cursor position.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.move_forward(buffer, 2)
      iex> Cursor.get_position(buffer)
      {2, 0}
  """
  def move_forward(buffer, columns) do
    {x, y} = buffer.cursor.position
    new_x = min(buffer.width - 1, x + columns)
    set_position(buffer, new_x, y)
  end

  @doc """
  Moves the cursor backward by the specified number of columns.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `columns` - Number of columns to move backward

  ## Returns

  The updated screen buffer with new cursor position.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.move_backward(buffer, 2)
      iex> Cursor.get_position(buffer)
      {0, 0}  # Cursor stays at left edge
  """
  def move_backward(buffer, columns) do
    {x, y} = buffer.cursor.position
    new_x = max(0, x - columns)
    set_position(buffer, new_x, y)
  end

  @doc """
  Moves the cursor to the specified position.

  ## Parameters

  * `buffer` - The screen buffer to modify
  * `position` - The target position as {x, y}

  ## Returns

  The updated screen buffer with new cursor position.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> buffer = Cursor.move_to(buffer, {10, 5})
      iex> Cursor.get_position(buffer)
      {10, 5}
  """
  def move_to(buffer, {x, y}) do
    x = clamp_to_bounds(x, buffer.width)
    y = clamp_to_bounds(y, buffer.height)
    set_position(buffer, x, y)
  end

  @doc """
  Sets the cursor position on the ScreenBuffer struct.
  """
  def set_cursor_position(buffer, x, y) do
    %{buffer | cursor_position: {x, y}}
  end

  @doc """
  Gets the cursor position from the ScreenBuffer struct.
  """
  def get_cursor_position(buffer) do
    buffer.cursor_position
  end
end
