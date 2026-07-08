defprotocol Raxol.Protocols.BufferOperations do
  @moduledoc """
  Protocol for buffer operations in terminal emulation.

  This protocol provides a unified interface for different types of buffers
  (screen buffers, scrollback buffers, overlay buffers) to implement their
  own strategies for writing, reading, and clearing data.

  ## Examples

      defimpl Raxol.Protocols.BufferOperations, for: MyBuffer do
        def write(buffer, {x, y}, data, style) do
          # Implementation for writing to buffer
        end

        def read(buffer, {x, y}, length) do
          # Implementation for reading from buffer
        end

        def clear(buffer, :all) do
          # Implementation for clearing buffer
        end
      end
  """

  @type position :: {non_neg_integer(), non_neg_integer()}
  @type region ::
          :all
          | :line
          | :screen
          | {:rect, position, position}
          | {:lines, non_neg_integer(), non_neg_integer()}
  @type style :: map() | nil

  @doc """
  Writes data to the buffer at the specified position.

  ## Parameters

    * `buffer` - The buffer to write to
    * `position` - A tuple `{x, y}` specifying the position
    * `data` - The data to write (string or character)
    * `style` - Optional style map containing attributes like color, bold, etc.

  ## Returns

  The updated buffer.
  """
  @spec write(t, position, binary() | char(), style) :: t
  def write(buffer, position, data, style)

  @doc """
  Reads data from the buffer at the specified position.

  ## Parameters

    * `buffer` - The buffer to read from
    * `position` - A tuple `{x, y}` specifying the starting position
    * `length` - Number of characters to read (default: 1)

  ## Returns

  The data at the specified position, or `nil` if position is out of bounds.
  """
  @spec read(t, position, non_neg_integer()) :: binary() | nil
  def read(buffer, position, length)

  @doc """
  Clears the buffer or a specific region.

  ## Parameters

    * `buffer` - The buffer to clear
    * `region` - The region to clear:
      * `:all` - Clear entire buffer
      * `:line` - Clear current line
      * `:screen` - Clear visible screen
      * `{:rect, {x1, y1}, {x2, y2}}` - Clear rectangular region
      * `{:lines, start, end}` - Clear lines from start to end

  ## Returns

  The updated buffer.
  """
  @spec clear(t, region) :: t
  def clear(buffer, region)

  @doc """
  Gets the dimensions of the buffer.

  ## Returns

  A tuple `{width, height}` representing the buffer dimensions.
  """
  @spec dimensions(t) :: {non_neg_integer(), non_neg_integer()}
  def dimensions(buffer)

  @doc """
  Scrolls the buffer content.

  ## Parameters

    * `buffer` - The buffer to scroll
    * `direction` - `:up` or `:down`
    * `lines` - Number of lines to scroll

  ## Returns

  The updated buffer.
  """
  @spec scroll(t, :up | :down, non_neg_integer()) :: t
  def scroll(buffer, direction, lines)
end
