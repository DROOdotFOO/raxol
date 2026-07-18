defmodule Raxol.Core.Buffer do
  @moduledoc """
  Compatibility layer for legacy Raxol.Core.Buffer references.

  This module exists to maintain backwards compatibility with plugins
  that reference the old apps/raxol_core modules.

  Maps to Raxol.Terminal.Buffer operations where possible.
  """

  @type cell :: %{
          char: String.t(),
          style: map()
        }

  @type line :: %{
          cells: list(cell())
        }

  @type t :: %{
          width: non_neg_integer(),
          height: non_neg_integer(),
          lines: list(line()),
          cells: list()
        }

  @doc "Create blank buffer with lines structure for TerminalBridge compatibility"
  def create_blank_buffer(width, height) do
    # Create lines structure expected by TerminalBridge
    lines =
      for _y <- 0..(height - 1) do
        cells =
          for _x <- 0..(width - 1) do
            blank_cell()
          end

        %{cells: cells}
      end

    %{
      width: width,
      height: height,
      lines: lines,
      cells: []
    }
  end

  @doc "Write text at coordinates"
  def write_at(buffer, x, y, text) when is_binary(text) do
    write_at(buffer, x, y, text, %{})
  end

  def write_at(buffer, x, y, text, style)
      when is_binary(text) and is_integer(x) and is_integer(y) and x >= 0 and
             y >= 0 and
             y < buffer.height do
    chars = String.graphemes(text)

    new_lines =
      List.update_at(buffer.lines, y, fn line ->
        new_cells =
          chars
          |> Enum.with_index()
          |> Enum.reduce(line.cells, fn {char, offset}, cells ->
            update_cell_at_offset(cells, x, offset, char, style, buffer.width)
          end)

        %{line | cells: new_cells}
      end)

    %{buffer | lines: new_lines}
  end

  def write_at(buffer, _x, _y, _text, _style), do: buffer

  @doc "Get cell at coordinates"
  def get_cell(buffer, x, y)
      when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 and
             y < buffer.height and
             x < buffer.width do
    line = Enum.at(buffer.lines, y)
    Enum.at(line.cells, x)
  end

  def get_cell(_buffer, _x, _y) do
    blank_cell()
  end

  @doc "Set cell at coordinates"
  def set_cell(buffer, x, y, char, style)
      when is_integer(x) and is_integer(y) and x >= 0 and y >= 0 and
             y < buffer.height and
             x < buffer.width do
    new_lines =
      List.update_at(buffer.lines, y, fn line ->
        new_cells = List.replace_at(line.cells, x, %{char: char, style: style})
        %{line | cells: new_cells}
      end)

    %{buffer | lines: new_lines}
  end

  def set_cell(buffer, _x, _y, _char, _style), do: buffer

  @doc "Convert buffer to string"
  def to_string(buffer) do
    Enum.map_join(buffer.lines, "\n", fn line ->
      Enum.map_join(line.cells, "", & &1.char)
    end)
  end

  @doc "Clear buffer, resetting all cells to blank"
  def clear(buffer) do
    create_blank_buffer(buffer.width, buffer.height)
  end

  @doc "Resize buffer to new dimensions"
  def resize(buffer, new_width, new_height) do
    new_buffer = create_blank_buffer(new_width, new_height)

    # Copy existing content where it fits
    Enum.reduce(0..(min(buffer.height, new_height) - 1), new_buffer, fn y,
                                                                        acc ->
      copy_row(buffer, acc, y, min(buffer.width, new_width))
    end)
  end

  defp copy_row(source, target, y, max_x) do
    Enum.reduce(0..(max_x - 1), target, fn x, acc ->
      copy_cell(source, acc, x, y)
    end)
  end

  defp copy_cell(source, target, x, y) do
    case get_cell(source, x, y) do
      %{char: char, style: style} -> set_cell(target, x, y, char, style)
      _ -> target
    end
  end

  defp update_cell_at_offset(cells, x, offset, char, style, width) do
    cell_x = x + offset

    case cell_x < width do
      true -> List.replace_at(cells, cell_x, %{char: char, style: style})
      false -> cells
    end
  end

  defp blank_cell do
    %{char: " ", style: %{fg_color: nil, bg_color: nil, bold: false}}
  end
end
