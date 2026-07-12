defmodule Raxol.CrossTerminal.ParserCharacterizationTest do
  @moduledoc """
  Characterizes the two ANSI parsers — `TerminalParser` (stateful,
  canonical) and `ANSI.Parser` (stateless tokenizer) — against a shared
  corpus, asserting observable outcomes only.
  """
  use ExUnit.Case, async: true

  alias Raxol.Test.CrossTerminal.AnsiReplayer, as: Replayer
  alias Raxol.Terminal.ANSI.Parser, as: StatelessParser

  @corpus [
    {"plain text", "hello world"},
    {"16-color SGR", "\e[31mred\e[0m"},
    {"truecolor SGR", "\e[38;2;255;0;0mR\e[0m"},
    {"cursor position", "\e[10;20Hx"},
    {"erase display", "before\e[2J\e[Hafter"},
    {"alt screen", "\e[?1049halt\e[?1049l"},
    {"osc title", "\e]0;my-title\abody"},
    {"bracketed paste enable", "\e[?2004htext"}
  ]

  describe "stateful pipeline (canonical): corpus must not crash the emulator" do
    for {name, input} <- @corpus do
      test "#{name}" do
        emulator = Replayer.replay(unquote(input))
        # grid must be a well-formed string, cursor a coordinate tuple
        assert is_binary(Replayer.grid_text(emulator))
        assert {x, y} = Replayer.cursor(emulator)
        assert is_integer(x) and is_integer(y)
      end
    end
  end

  describe "stateless parser: corpus must return token lists without crashing" do
    for {name, input} <- @corpus do
      test "#{name}" do
        result = StatelessParser.parse(unquote(input))
        assert is_list(result)
      end
    end
  end

  describe "pinned grid outcomes (drift detectors)" do
    test "16-color SGR leaves only text on the grid" do
      assert "\e[31mred\e[0m" |> Replayer.replay() |> Replayer.visible_text() ==
               "red"
    end

    test "OSC title does not leak into the grid" do
      text =
        "\e]0;my-title\abody" |> Replayer.replay() |> Replayer.visible_text()

      assert text == "body"
      refute text =~ "my-title"
    end

    test "private mode toggles leave no residue on the grid" do
      assert "\e[?2004htext" |> Replayer.replay() |> Replayer.visible_text() ==
               "text"
    end

    test "cursor lands after written text, not at sequence start" do
      emulator = Replayer.replay("\e[10;20Hx")
      # CUP is 1-based, grid is 0-based; cursor sits after "x" as {row, col}.
      assert Replayer.cursor(emulator) == {9, 20}
    end
  end
end
