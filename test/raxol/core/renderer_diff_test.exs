defmodule Raxol.Core.RendererDiffTest do
  @moduledoc """
  Unit tests for `Raxol.Core.Renderer.render_diff/2` operation emission,
  in particular the `{:clear_line, y}` fast path for rows that become
  entirely blank.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Buffer
  alias Raxol.Core.Renderer
  alias Raxol.Test.CrossTerminal.AnsiReplayer, as: Replayer

  defp blank(width \\ 20, height \\ 4),
    do: Buffer.create_blank_buffer(width, height)

  describe "render_diff/2 clear_line emission" do
    test "changed row that becomes fully blank emits exactly clear_line" do
      old = Buffer.write_at(blank(), 3, 1, "hello world")
      new = blank()

      assert Renderer.render_diff(old, new) == [{:clear_line, 1}]
    end

    test "each blanked row emits its own clear_line" do
      old =
        blank()
        |> Buffer.write_at(0, 0, "top")
        |> Buffer.write_at(0, 2, "bottom")

      new = blank()

      assert Renderer.render_diff(old, new) == [
               {:clear_line, 0},
               {:clear_line, 2}
             ]
    end

    test "unchanged blank row emits nothing" do
      assert Renderer.render_diff(blank(), blank()) == []
    end

    test "visually blank rows with different style shapes emit nothing" do
      # create_blank_buffer cells carry the full nil-map style; write_at with
      # a space and default style leaves %{} - visually identical, structurally
      # different. Neither a write nor a clear_line should appear.
      old = blank()
      new = Buffer.write_at(blank(), 5, 1, " ")

      assert Buffer.to_string(old) == Buffer.to_string(new)
      assert Renderer.render_diff(old, new) == []
    end

    test "partially blank row still emits move/write runs" do
      old = Buffer.write_at(blank(), 0, 1, "hello world")
      new = Buffer.write_at(blank(), 0, 1, "hello")

      ops = Renderer.render_diff(old, new)

      assert Enum.any?(ops, &match?({:move, _, 1}, &1))
      assert Enum.any?(ops, &match?({:write, _, _}, &1))
      refute Enum.any?(ops, &match?({:clear_line, _}, &1))
    end

    test "row of spaces with bg_color set stays a write" do
      style = %{bg_color: :blue}
      old = Buffer.write_at(blank(), 0, 1, "text", style)
      new = Buffer.write_at(blank(), 0, 1, "    ", style)

      ops = Renderer.render_diff(old, new)

      refute Enum.any?(ops, &match?({:clear_line, _}, &1))
      assert Enum.any?(ops, &match?({:write, "    ", ^style}, &1))
    end

    test "row of blank chars with a hyperlink stays a write" do
      style = %{hyperlink: "https://raxol.io"}
      old = Buffer.write_at(blank(), 0, 1, "link", style)
      new = Buffer.write_at(blank(), 0, 1, "    ", style)

      ops = Renderer.render_diff(old, new)

      refute Enum.any?(ops, &match?({:clear_line, _}, &1))
      assert Enum.any?(ops, &match?({:write, "    ", ^style}, &1))
    end

    test "space cells with a non-map style never crash the blank scan" do
      # set_cell/5 has no guard on style, so nil styles are reachable via the
      # public API; the fast path must fall through, not raise.
      old = Buffer.set_cell(blank(), 3, 1, " ", nil)
      new = Buffer.set_cell(blank(), 3, 1, " ", nil)

      assert Renderer.render_diff(old, new) == []
      # The nil-style cell is not blank (unknown style), so a diff to a truly
      # blank row is a changed-row-to-blank: clear_line, no crash.
      assert Renderer.render_diff(old, blank()) == [{:clear_line, 1}]
    end

    test "row going from blank to text emits writes, not clear_line" do
      old = blank()
      new = Buffer.write_at(blank(), 2, 1, "hi")

      assert [{:move, 2, 1}, {:write, "hi", %{}}] =
               Renderer.render_diff(old, new)
    end
  end

  describe "apply_diff/1 clear_line rendering" do
    test "clear_line renders cursor move to column 1 plus erase-line" do
      assert Renderer.apply_diff([{:clear_line, 3}]) == "\e[4;1H\e[2K"
    end
  end

  describe "clear_line roundtrip through the reference emulator" do
    test "a blanked line is actually cleared on the emulated grid" do
      width = 20
      height = 4

      frame1 =
        Buffer.create_blank_buffer(width, height)
        |> Buffer.write_at(0, 0, "keep this line")
        |> Buffer.write_at(0, 2, "clear this line")

      frame2 =
        Buffer.create_blank_buffer(width, height)
        |> Buffer.write_at(0, 0, "keep this line")

      ansi1 =
        Buffer.create_blank_buffer(width, height)
        |> Renderer.render_diff(frame1)
        |> Renderer.apply_diff()

      diff = Renderer.render_diff(frame1, frame2)
      assert {:clear_line, 2} in diff
      ansi2 = Renderer.apply_diff(diff)

      emulator =
        Replayer.replay_chunks([ansi1, ansi2], width: width, height: height)

      assert normalized(Replayer.grid_text(emulator)) ==
               normalized(Buffer.to_string(frame2))
    end
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
end
