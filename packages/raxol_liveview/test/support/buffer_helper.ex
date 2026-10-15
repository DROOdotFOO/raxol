defmodule Raxol.LiveView.Test.BufferHelper do
  @moduledoc false
  # Creates buffer-like maps for testing TerminalBridge's structural buffer
  # contract without coupling these tests to the compatibility constructor.

  @doc "Create a blank buffer map with given dimensions."
  def create_blank_buffer(width, height) do
    cells =
      for _y <- 0..(height - 1) do
        for _x <- 0..(width - 1) do
          %{char: " ", fg: :default, bg: :default, style: %{}}
        end
      end

    %{
      width: width,
      height: height,
      cells: cells
    }
  end

  @doc "Set a character in the buffer at (x, y)."
  def set_cell(buffer, x, y, char, opts \\ []) do
    fg = Keyword.get(opts, :fg, :default)
    bg = Keyword.get(opts, :bg, :default)
    style = Keyword.get(opts, :style, %{})

    cell = %{char: char, fg: fg, bg: bg, style: style}

    cells =
      List.update_at(buffer.cells, y, fn row ->
        List.replace_at(row, x, cell)
      end)

    %{buffer | cells: cells}
  end

  @doc "Write a string starting at (x, y)."
  def write_string(buffer, x, y, string, opts \\ []) do
    string
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.reduce(buffer, fn {char, i}, buf ->
      set_cell(buf, x + i, y, char, opts)
    end)
  end
end
