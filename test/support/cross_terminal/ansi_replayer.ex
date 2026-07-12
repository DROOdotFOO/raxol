defmodule Raxol.Test.CrossTerminal.AnsiReplayer do
  @moduledoc """
  Feeds a raw ANSI byte stream into the reference terminal emulator
  (`Raxol.Terminal.Emulator`) and exposes the resulting text grid.

  This is the missing link between `Raxol.Recording` (which captures the
  real ANSI frames an app emits) and grid-level assertions: any `.cast`
  file or ANSI string can be replayed headlessly and compared cell by cell.
  """

  alias Raxol.Terminal.Emulator
  alias Raxol.Terminal.Buffer.Queries
  alias Raxol.Terminal.ScreenBuffer

  @default_width 80
  @default_height 24

  @doc "Replays a single ANSI binary into a fresh emulator."
  def replay(bytes, opts \\ []) when is_binary(bytes) do
    replay_chunks([bytes], opts)
  end

  @doc """
  Replays a list of ANSI chunks sequentially through one emulator,
  exercising the parser's ability to resume mid-sequence across chunks.
  """
  def replay_chunks(chunks, opts \\ []) when is_list(chunks) do
    width = Keyword.get(opts, :width, @default_width)
    height = Keyword.get(opts, :height, @default_height)

    Enum.reduce(chunks, Emulator.new(width, height), fn chunk, emulator ->
      {emulator, _output} = Emulator.process_input(emulator, chunk)
      emulator
    end)
  end

  @doc """
  Replays an asciinema v2 `.cast` file (as produced by `Raxol.Recording`),
  concatenating all output ("o") events. Returns the emulator.
  """
  def replay_cast(path, opts \\ []) do
    [header_line | event_lines] =
      path
      |> File.read!()
      |> String.split("\n", trim: true)

    header = Jason.decode!(header_line)

    bytes =
      event_lines
      |> Enum.map(&Jason.decode!/1)
      |> Enum.filter(fn [_ts, type, _data] -> type == "o" end)
      |> Enum.map_join("", fn [_ts, _type, data] -> data end)

    opts =
      Keyword.merge(
        [
          width: header["width"] || @default_width,
          height: header["height"] || @default_height
        ],
        opts
      )

    replay(bytes, opts)
  end

  @doc "Full text grid, one string per line, padded to buffer width."
  def grid_text(emulator) do
    emulator
    |> Emulator.get_screen_buffer()
    |> Queries.get_text()
  end

  @doc """
  Text grid trimmed for golden comparisons: trailing whitespace stripped
  per line, trailing blank lines dropped.
  """
  def visible_text(emulator) do
    emulator
    |> grid_text()
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  @doc "Cell struct at (x, y) — zero-based."
  def cell_at(emulator, x, y) do
    emulator
    |> Emulator.get_screen_buffer()
    |> ScreenBuffer.get_cell_at(x, y)
  end

  @doc """
  Cursor position of the replayed emulator.

  NOTE: the emulator returns `{row, col}` (y first), not `{x, y}`.
  Pinned as-is by the characterization tests.
  """
  def cursor(emulator) do
    Emulator.get_cursor_position(emulator)
  end
end
