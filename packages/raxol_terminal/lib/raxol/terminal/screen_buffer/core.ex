defmodule Raxol.Terminal.ScreenBuffer.Core do
  @moduledoc """
  Core functionality for screen buffer creation, initialization, and basic queries.
  Consolidates: Initializer, Common, Helpers, and basic state management.
  """

  @default_width Raxol.Core.Defaults.terminal_width()
  @default_height Raxol.Core.Defaults.terminal_height()
  @default_scrollback Raxol.Core.Defaults.scrollback_limit()

  alias Raxol.Core.Utils.Validation
  alias Raxol.Terminal.ANSI.TextFormatting
  alias Raxol.Terminal.Cell

  # Minimal, focused struct definition
  defstruct [
    :cells,
    :scrollback,
    :scrollback_limit,
    :selection,
    :scroll_region,
    :scroll_position,
    :width,
    :height,
    :damage_regions,
    :default_style,
    cursor_position: {0, 0},
    cursor_style: :block,
    cursor_visible: true,
    cursor_blink: true,
    alternate_screen: false
  ]

  @type t :: %__MODULE__{
          cells: list(list(Cell.t())),
          scrollback: list(list(Cell.t())),
          scrollback_limit: non_neg_integer(),
          selection:
            nil
            | {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer()},
          scroll_region: nil | {non_neg_integer(), non_neg_integer()},
          scroll_position: non_neg_integer(),
          width: non_neg_integer(),
          height: non_neg_integer(),
          damage_regions: list(tuple()),
          default_style: map(),
          cursor_position: {non_neg_integer(), non_neg_integer()},
          cursor_style: atom(),
          cursor_visible: boolean(),
          cursor_blink: boolean(),
          alternate_screen: boolean()
        }

  @doc """
  Creates a new screen buffer with the specified dimensions, clamped to the
  terminal size ceiling (`Raxol.Core.Utils.Validation.clamp_terminal_size/2`).
  """
  def new(width, height, scrollback_limit \\ @default_scrollback) do
    {width, height} =
      Validation.clamp_terminal_size(
        validate_dimension(width, @default_width),
        validate_dimension(height, @default_height)
      )

    scrollback_limit = validate_dimension(scrollback_limit, @default_scrollback)

    %__MODULE__{
      cells: create_empty_grid(width, height),
      scrollback: [],
      scrollback_limit: scrollback_limit,
      selection: nil,
      scroll_region: nil,
      scroll_position: 0,
      width: width,
      height: height,
      damage_regions: [],
      default_style: TextFormatting.new(),
      cursor_position: {0, 0},
      cursor_style: :block,
      cursor_visible: true,
      cursor_blink: true,
      alternate_screen: false
    }
  end

  @doc """
  Resizes the buffer to new dimensions, clamped to the terminal size ceiling.
  """
  def resize(buffer, new_width, new_height) do
    {new_width, new_height} =
      Validation.clamp_terminal_size(
        validate_dimension(new_width, buffer.width),
        validate_dimension(new_height, buffer.height)
      )

    new_cells =
      resize_grid(
        buffer.cells,
        buffer.width,
        buffer.height,
        new_width,
        new_height
      )

    %{
      buffer
      | cells: new_cells,
        width: new_width,
        height: new_height,
        damage_regions: [{0, 0, new_width - 1, new_height - 1}]
    }
    |> adjust_cursor_after_resize()
  end

  @doc """
  Gets the buffer dimensions.
  """
  def get_dimensions(%{width: width, height: height}), do: {width, height}

  @doc """
  Gets the buffer width.
  """
  def get_width(%{width: width}), do: width

  @doc """
  Gets the buffer height.
  """
  def get_height(%{height: height}), do: height

  @doc """
  Checks if coordinates are within buffer bounds.
  """
  def within_bounds?(%{width: width, height: height}, x, y) do
    x >= 0 and x < width and y >= 0 and y < height
  end

  @doc """
  Gets a cell at the specified coordinates.
  """
  def get_cell(buffer, x, y) when x >= 0 and y >= 0 do
    if within_bounds?(buffer, x, y) do
      buffer.cells
      |> Enum.at(y, [])
      |> Enum.at(x)
    else
      nil
    end
  end

  @doc """
  Gets the character at the specified coordinates.
  """
  def get_char(buffer, x, y) do
    case get_cell(buffer, x, y) do
      %Cell{char: char} -> char || " "
      _ -> " "
    end
  end

  @doc """
  Gets a line of cells.
  """
  def get_line(buffer, y) when y >= 0 and y < buffer.height do
    Enum.at(buffer.cells, y, [])
  end

  def get_line(_buffer, _y), do: []

  @doc """
  Clears the entire buffer.
  """
  def clear(buffer) do
    %{
      buffer
      | cells: create_empty_grid(buffer.width, buffer.height),
        damage_regions: [{0, 0, buffer.width - 1, buffer.height - 1}]
    }
  end

  # Private helper functions

  defp validate_dimension(dimension, _default)
       when is_integer(dimension) and dimension > 0 do
    dimension
  end

  defp validate_dimension(_dimension, default), do: default

  # Every row is the same blank row: cells are immutable, so a blank screen
  # costs one row plus the list of rows, not a cell per cell (clearing the
  # alternate screen on every 1049 switch built all of them).
  defp create_empty_grid(width, height) when width > 0 and height > 0,
    do: List.duplicate(List.duplicate(Cell.empty(), width), height)

  defp create_empty_grid(_width, _height), do: []

  defp resize_grid(cells, old_width, old_height, new_width, new_height) do
    # Crop or extend height
    cells =
      if new_height < old_height do
        Enum.take(cells, new_height)
      else
        cells ++ create_empty_grid(new_width, new_height - old_height)
      end

    # Crop or extend width for each row
    Enum.map(cells, fn row ->
      if new_width < old_width do
        Enum.take(row, new_width)
      else
        row ++ List.duplicate(Cell.empty(), new_width - length(row))
      end
    end)
  end

  defp adjust_cursor_after_resize(buffer) do
    {x, y} = buffer.cursor_position
    new_x = min(x, buffer.width - 1)
    new_y = min(y, buffer.height - 1)
    %{buffer | cursor_position: {new_x, new_y}}
  end

  @doc """
  Converts buffer to legacy cell grid format for backward compatibility.
  """
  def to_cell_grid(buffer) do
    buffer.cells
  end
end
