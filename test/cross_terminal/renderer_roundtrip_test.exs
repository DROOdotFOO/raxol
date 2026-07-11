defmodule Raxol.CrossTerminal.RendererRoundtripTest do
  @moduledoc """
  Dogfood differential test: what the renderer EMITS, the reference
  emulator must INTERPRET back to the identical text grid.

      Core.Buffer --Renderer.render_diff--> ANSI bytes
                 --AnsiReplayer/Emulator--> grid
      grid == Core.Buffer.to_string

  Catches emit/decode asymmetries (problems backlog #1, #2) and is the
  in-process Layer A of the cross-terminal strategy: the same ANSI
  artifact later gets fed to real terminals in Layer B.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Buffer
  alias Raxol.Core.Renderer
  alias Raxol.Test.CrossTerminal.AnsiReplayer, as: Replayer
  alias Raxol.Test.CrossTerminal.SequenceScanner, as: Scanner

  defp render_to_ansi(buffer, width, height) do
    blank = Buffer.create_blank_buffer(width, height)

    blank
    |> Renderer.render_diff(buffer)
    |> Renderer.apply_diff()
  end

  defp roundtrip(buffer, width \\ 40, height \\ 10) do
    ansi = render_to_ansi(buffer, width, height)
    emulator = Replayer.replay(ansi, width: width, height: height)
    {ansi, emulator}
  end

  defp normalized(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.reverse()
    |> Enum.drop_while(&(&1 == ""))
    |> Enum.reverse()
    |> Enum.join("\n")
  end

  test "plain text buffer roundtrips through emulator" do
    buffer =
      Buffer.create_blank_buffer(40, 10)
      |> Buffer.write_at(0, 0, "top-left")
      |> Buffer.write_at(10, 5, "middle")
      |> Buffer.write_at(0, 9, "bottom")

    {_ansi, emulator} = roundtrip(buffer)

    assert normalized(Replayer.grid_text(emulator)) ==
             normalized(Buffer.to_string(buffer))
  end

  test "styled text roundtrips: chars intact, styles land on cells" do
    buffer =
      Buffer.create_blank_buffer(40, 10)
      |> Buffer.write_at(2, 1, "styled", %{fg_color: :red, bold: true})
      |> Buffer.write_at(2, 3, "plain")

    {_ansi, emulator} = roundtrip(buffer)

    assert normalized(Replayer.grid_text(emulator)) ==
             normalized(Buffer.to_string(buffer))

    styled_cell = Replayer.cell_at(emulator, 2, 1)
    plain_cell = Replayer.cell_at(emulator, 2, 3)
    assert styled_cell.char == "s"
    assert plain_cell.char == "p"
  end

  test "box-drawing characters roundtrip intact" do
    buffer =
      Buffer.create_blank_buffer(20, 5)
      |> Buffer.write_at(0, 0, "┌──────┐")
      |> Buffer.write_at(0, 1, "│ box  │")
      |> Buffer.write_at(0, 2, "└──────┘")

    {_ansi, emulator} = roundtrip(buffer, 20, 5)

    assert normalized(Replayer.grid_text(emulator)) ==
             normalized(Buffer.to_string(buffer))
  end

  test "renderer output contains no sequences a modern terminal cannot interpret" do
    buffer =
      Buffer.create_blank_buffer(40, 10)
      |> Buffer.write_at(0, 0, "text", %{fg_color: :cyan})

    {ansi, _emulator} = roundtrip(buffer)

    assert Scanner.violations(ansi, :modern) == []
  end

  test "sequence scanner sees only known token types in renderer output" do
    buffer =
      Buffer.create_blank_buffer(40, 10)
      |> Buffer.write_at(0, 0, "abc", %{bold: true})
      |> Buffer.write_at(5, 5, "def")

    ansi = render_to_ansi(buffer, 40, 10)

    for token <- Scanner.scan(ansi) do
      assert elem(token, 0) in [:csi, :osc, :dcs, :esc, :text]
    end
  end
end
