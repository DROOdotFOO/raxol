defmodule Raxol.Core.Renderer do
  @moduledoc """
  Rendering utilities for Raxol.Core.Buffer.

  Provides functions to render buffers to strings and calculate minimal
  differences between buffers for efficient terminal updates.

  ## Example

      buffer = Raxol.Core.Buffer.create_blank_buffer(80, 24)
      buffer = Raxol.Core.Buffer.write_at(buffer, 0, 0, "Hello, World!")
      output = Raxol.Core.Renderer.render_to_string(buffer)
  """

  alias Raxol.Core.Buffer
  alias Raxol.Core.Style

  @doc """
  Render a buffer to a plain string without ANSI codes.

  ## Example

      buffer = Raxol.Core.Buffer.create_blank_buffer(20, 5)
      Raxol.Core.Renderer.render_to_string(buffer)
      # => "                    \\n..."
  """
  @spec render_to_string(Buffer.t()) :: String.t()
  def render_to_string(buffer) do
    Buffer.to_string(buffer)
  end

  @doc """
  Render a buffer to a string with ANSI escape codes for styling.

  ## Example

      buffer = Raxol.Core.Buffer.create_blank_buffer(20, 5)
      Raxol.Core.Renderer.render_to_ansi(buffer)
      # => String with ANSI codes for colors and styles
  """
  @spec render_to_ansi(Buffer.t()) :: String.t()
  def render_to_ansi(buffer) do
    buffer.lines
    |> Enum.map_join("\n", fn line ->
      render_line_with_ansi(line.cells)
    end)
  end

  @doc """
  Calculate minimal updates between two buffers.

  Returns a list of update operations that can be applied to transform
  the old buffer into the new buffer with minimal terminal output.

  ## Return Format

  Returns a list of update tuples:
  - `{:move, x, y}` - Move cursor to position
  - `{:write, text, style}` - Write text with style
  - `{:clear_line, y}` - Clear line at y

  ## Example

      old_buffer = Raxol.Core.Buffer.create_blank_buffer(20, 5)
      new_buffer = Raxol.Core.Buffer.write_at(old_buffer, 0, 0, "Hello")
      diff = Raxol.Core.Renderer.render_diff(old_buffer, new_buffer)
      # => [{:move, 0, 0}, {:write, "Hello", %{}}]
  """
  @spec render_diff(Buffer.t(), Buffer.t()) :: list()
  def render_diff(old_buffer, new_buffer) do
    old_buffer.lines
    |> Enum.zip(new_buffer.lines)
    |> Enum.with_index()
    |> Enum.flat_map(fn {{old_line, new_line}, y} ->
      generate_line_diff(old_line.cells, new_line.cells, y)
    end)
  end

  @doc """
  Apply diff operations to produce ANSI output string.

  Takes the diff operations from render_diff/2 and produces a string
  with ANSI cursor movement and styling codes.

  ## Example

      diff = [{:move, 0, 0}, {:write, "Hello", %{fg_color: :blue}}]
      Raxol.Core.Renderer.apply_diff(diff)
      # => "\e[1;1H\e[34mHello\e[0m"
  """
  @spec apply_diff(list()) :: String.t()
  def apply_diff(operations) do
    operations
    |> Enum.map_join("", &operation_to_ansi/1)
  end

  # Private helpers

  defp render_line_with_ansi(cells) do
    cells
    |> chunk_by_style()
    |> Enum.map_join("", fn {style, chars} ->
      ansi_prefix = Style.to_ansi(style)
      text = chars |> Enum.reverse() |> Enum.join()

      styled =
        case ansi_prefix do
          "" -> text
          prefix -> prefix <> text <> Style.reset()
        end

      maybe_wrap_hyperlink(styled, style)
    end)
  end

  defp chunk_by_style(cells) do
    cells
    |> Enum.reduce([], fn cell, acc ->
      case acc do
        [] ->
          [{cell.style, [cell.char]}]

        [{prev_style, chars} | rest] when prev_style == cell.style ->
          [{prev_style, [cell.char | chars]} | rest]

        _ ->
          [{cell.style, [cell.char]} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp generate_line_diff(old_cells, new_cells, y) do
    old_cells
    |> Enum.zip(new_cells)
    |> Enum.with_index()
    |> Enum.reduce({[], nil, []}, fn {{old_cell, new_cell}, x}, acc ->
      diff_cell(acc, old_cell, new_cell, x, y, new_cells)
    end)
    |> then(fn {ops, run_start, run_chars} ->
      flush_run(ops, run_start, run_chars, y, new_cells)
      |> elem(0)
      |> Enum.reverse()
    end)
  end

  defp diff_cell({ops, run_start, run_chars}, old_cell, new_cell, x, y, cells) do
    if cells_equal?(old_cell, new_cell) do
      flush_run(ops, run_start, run_chars, y, cells)
    else
      case run_start do
        nil -> {ops, x, [new_cell]}
        _ -> {ops, run_start, [new_cell | run_chars]}
      end
    end
  end

  defp flush_run(ops, nil, _run_chars, _y, _cells), do: {ops, nil, []}

  defp flush_run(ops, run_start, run_chars, y, _cells) do
    reversed_chars = Enum.reverse(run_chars)
    text = Enum.map_join(reversed_chars, "", & &1.char)
    style = List.first(reversed_chars) |> Map.get(:style, %{})

    # ops is built reversed and flipped once at the end; prepend write
    # before move so the final order is [{:move, ...}, {:write, ...}]
    new_ops = [{:write, text, style}, {:move, run_start, y} | ops]
    {new_ops, nil, []}
  end

  defp cells_equal?(old_cell, new_cell) do
    old_cell.char == new_cell.char and old_cell.style == new_cell.style
  end

  defp operation_to_ansi({:move, x, y}) do
    # ANSI cursor position is 1-indexed
    "\e[#{y + 1};#{x + 1}H"
  end

  defp operation_to_ansi({:write, text, style}) do
    ansi_prefix = Style.to_ansi(style)

    styled =
      case ansi_prefix do
        "" -> text
        prefix -> prefix <> text <> Style.reset()
      end

    maybe_wrap_hyperlink(styled, style)
  end

  defp operation_to_ansi({:clear_line, y}) do
    "\e[#{y + 1};1H\e[2K"
  end

  defp operation_to_ansi(_), do: ""

  # Wrap already-styled content in an OSC 8 hyperlink when the cell style
  # carries one (bare form, ST-terminated). Cells with no hyperlink emit
  # exactly as before.
  defp maybe_wrap_hyperlink(content, style) when is_map(style) do
    case Map.get(style, :hyperlink) do
      url when is_binary(url) and url != "" ->
        "\e]8;;" <> url <> "\e\\" <> content <> "\e]8;;\e\\"

      _ ->
        content
    end
  end
end
