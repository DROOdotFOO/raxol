defmodule Raxol.Terminal.Buffer.Scroller do
  @moduledoc """
  Handles scrolling operations for the terminal buffer.
  """

  alias Raxol.Terminal.ScreenBuffer

  @doc """
  Scrolls the buffer up by the specified number of lines.
  """
  def scroll_up(buffer, count) do
    do_scroll_up(buffer, count)
  end

  @doc """
  Scrolls the buffer down by the specified number of lines.
  """
  def scroll_down(buffer, count) do
    do_scroll_down(buffer, count)
  end

  @doc """
  Gets the scroll top position.
  """
  def get_scroll_top(_buffer, scroll_margins) do
    scroll_margins.top
  end

  @doc """
  Gets the scroll bottom position.
  """
  def get_scroll_bottom(_buffer, scroll_margins) do
    scroll_margins.bottom
  end

  @doc """
  Scrolls the entire buffer up by the specified number of lines.

  ## Parameters

  * `buffer` - The screen buffer to scroll
  * `count` - The number of lines to scroll up

  ## Returns

  A tuple containing :ok and the updated buffer.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> {:ok, new_buffer} = Scroller.scroll_entire_buffer_up(buffer, 1)
      iex> length(new_buffer.content)
      24
  """
  @spec scroll_entire_buffer_up(ScreenBuffer.t(), non_neg_integer()) ::
          {:ok, ScreenBuffer.t()}
  def scroll_entire_buffer_up(buffer, count) do
    {new_buffer, _removed_lines} = ScreenBuffer.pop_bottom_lines(buffer, count)
    empty_lines = List.duplicate(List.duplicate(%{}, buffer.width), count)
    new_cells = empty_lines ++ new_buffer.cells
    {:ok, %{new_buffer | cells: new_cells}}
  end

  @doc """
  Scrolls the entire buffer down by the specified number of lines.

  ## Parameters

  * `buffer` - The screen buffer to scroll
  * `count` - The number of lines to scroll down

  ## Returns

  A tuple containing :ok and the updated buffer.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> {:ok, new_buffer} = Scroller.scroll_entire_buffer_down(buffer, 1)
      iex> length(new_buffer.content)
      24
  """
  @spec scroll_entire_buffer_down(ScreenBuffer.t(), non_neg_integer()) ::
          {:ok, ScreenBuffer.t()}
  def scroll_entire_buffer_down(buffer, count) do
    {new_buffer, _removed_lines} = ScreenBuffer.pop_bottom_lines(buffer, count)
    empty_lines = List.duplicate(List.duplicate(%{}, buffer.width), count)
    new_cells = new_buffer.cells ++ empty_lines
    {:ok, %{new_buffer | cells: new_cells}}
  end

  @doc """
  Scrolls a specific region of the buffer up by the specified number of lines.

  ## Parameters

  * `buffer` - The screen buffer to scroll
  * `count` - The number of lines to scroll up
  * `top` - The top boundary of the scroll region
  * `bottom` - The bottom boundary of the scroll region

  ## Returns

  A tuple containing :ok and the updated buffer.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> {:ok, new_buffer} = Scroller.scroll_region_up(buffer, 1, 5, 15)
      iex> length(new_buffer.content)
      24
  """
  @spec scroll_region_up(
          ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, ScreenBuffer.t()}
  def scroll_region_up(buffer, count, top, bottom) do
    region_lines = Enum.slice(buffer.cells, top..bottom)
    {_to_scroll, remaining} = Enum.split(region_lines, count)
    empty_lines = List.duplicate(List.duplicate(%{}, buffer.width), count)
    new_region = remaining ++ empty_lines
    new_cells = List.replace_at(buffer.cells, top, new_region)
    {:ok, %{buffer | cells: new_cells}}
  end

  @doc """
  Scrolls a specific region of the buffer down by the specified number of lines.

  ## Parameters

  * `buffer` - The screen buffer to scroll
  * `count` - The number of lines to scroll down
  * `top` - The top boundary of the scroll region
  * `bottom` - The bottom boundary of the scroll region

  ## Returns

  A tuple containing :ok and the updated buffer.

  ## Examples

      iex> buffer = ScreenBuffer.new(80, 24)
      iex> {:ok, new_buffer} = Scroller.scroll_region_down(buffer, 1, 5, 15)
      iex> length(new_buffer.content)
      24
  """
  @spec scroll_region_down(
          ScreenBuffer.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: {:ok, ScreenBuffer.t()}
  def scroll_region_down(buffer, count, top, bottom) do
    region_lines = Enum.slice(buffer.cells, top..bottom)
    {remaining, _to_scroll} = Enum.split(region_lines, -count)
    empty_lines = List.duplicate(List.duplicate(%{}, buffer.width), count)
    new_region = empty_lines ++ remaining
    new_cells = List.replace_at(buffer.cells, top, new_region)
    {:ok, %{buffer | cells: new_cells}}
  end

  # Private helper functions

  defp do_scroll_up(buffer, count) do
    case buffer.scroll_region do
      nil ->
        {:ok, new_buffer} = scroll_entire_buffer_up(buffer, count)
        new_buffer

      region ->
        {:ok, new_buffer} =
          scroll_region_up(buffer, count, region.top, region.bottom)

        new_buffer
    end
  end

  defp do_scroll_down(buffer, count) do
    case buffer.scroll_region do
      nil ->
        {:ok, new_buffer} = scroll_entire_buffer_down(buffer, count)
        new_buffer

      region ->
        {:ok, new_buffer} =
          scroll_region_down(buffer, count, region.top, region.bottom)

        new_buffer
    end
  end
end
