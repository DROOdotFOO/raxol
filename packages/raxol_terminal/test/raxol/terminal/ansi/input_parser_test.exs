defmodule Raxol.Terminal.ANSI.InputParserTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ANSI.InputParser
  alias Raxol.Core.Events.Event

  describe "arrow keys" do
    test "parses up arrow" do
      assert [%Event{type: :key, data: %{key: :up}}] =
               InputParser.parse(<<27, 91, 65>>)
    end

    test "parses down arrow" do
      assert [%Event{type: :key, data: %{key: :down}}] =
               InputParser.parse(<<27, 91, 66>>)
    end

    test "parses right arrow" do
      assert [%Event{type: :key, data: %{key: :right}}] =
               InputParser.parse(<<27, 91, 67>>)
    end

    test "parses left arrow" do
      assert [%Event{type: :key, data: %{key: :left}}] =
               InputParser.parse(<<27, 91, 68>>)
    end
  end

  describe "basic keys" do
    test "parses escape" do
      assert [%Event{type: :key, data: %{key: :escape}}] =
               InputParser.parse(<<27>>)
    end

    test "parses enter (CR)" do
      assert [%Event{type: :key, data: %{key: :enter}}] =
               InputParser.parse(<<13>>)
    end

    test "parses enter (LF)" do
      assert [%Event{type: :key, data: %{key: :enter}}] =
               InputParser.parse(<<10>>)
    end

    test "parses backspace" do
      assert [%Event{type: :key, data: %{key: :backspace}}] =
               InputParser.parse(<<127>>)
    end

    test "parses tab" do
      assert [%Event{type: :key, data: %{key: :tab}}] = InputParser.parse(<<9>>)
    end
  end

  describe "printable ASCII" do
    test "parses lowercase letter" do
      assert [%Event{type: :key, data: %{key: :char, char: "a"}}] =
               InputParser.parse("a")
    end

    test "parses uppercase letter" do
      assert [%Event{type: :key, data: %{key: :char, char: "A"}}] =
               InputParser.parse("A")
    end

    test "parses space" do
      assert [%Event{type: :key, data: %{key: :char, char: " "}}] =
               InputParser.parse(" ")
    end

    test "parses digit" do
      assert [%Event{type: :key, data: %{key: :char, char: "5"}}] =
               InputParser.parse("5")
    end

    test "parses symbol" do
      assert [%Event{type: :key, data: %{key: :char, char: "@"}}] =
               InputParser.parse("@")
    end
  end

  describe "UTF-8 characters" do
    test "parses multi-byte UTF-8" do
      assert [%Event{type: :key, data: %{key: :char, char: "ñ"}}] =
               InputParser.parse("ñ")
    end
  end

  describe "function keys (SS3)" do
    test "parses F1 SS3" do
      assert [%Event{type: :key, data: %{key: :f1}}] =
               InputParser.parse(<<27, 79, 80>>)
    end

    test "parses F2 SS3" do
      assert [%Event{type: :key, data: %{key: :f2}}] =
               InputParser.parse(<<27, 79, 81>>)
    end

    test "parses F3 SS3" do
      assert [%Event{type: :key, data: %{key: :f3}}] =
               InputParser.parse(<<27, 79, 82>>)
    end

    test "parses F4 SS3" do
      assert [%Event{type: :key, data: %{key: :f4}}] =
               InputParser.parse(<<27, 79, 83>>)
    end
  end

  describe "function keys (CSI tilde)" do
    test "parses F1 CSI" do
      assert [%Event{type: :key, data: %{key: :f1}}] =
               InputParser.parse(<<27, 91>> <> "11~")
    end

    test "parses F2 CSI" do
      assert [%Event{type: :key, data: %{key: :f2}}] =
               InputParser.parse(<<27, 91>> <> "12~")
    end

    test "parses F3 CSI" do
      assert [%Event{type: :key, data: %{key: :f3}}] =
               InputParser.parse(<<27, 91>> <> "13~")
    end

    test "parses F4 CSI" do
      assert [%Event{type: :key, data: %{key: :f4}}] =
               InputParser.parse(<<27, 91>> <> "14~")
    end

    test "parses F5" do
      assert [%Event{type: :key, data: %{key: :f5}}] =
               InputParser.parse(<<27, 91>> <> "15~")
    end

    test "parses F6" do
      assert [%Event{type: :key, data: %{key: :f6}}] =
               InputParser.parse(<<27, 91>> <> "17~")
    end

    test "parses F7" do
      assert [%Event{type: :key, data: %{key: :f7}}] =
               InputParser.parse(<<27, 91>> <> "18~")
    end

    test "parses F8" do
      assert [%Event{type: :key, data: %{key: :f8}}] =
               InputParser.parse(<<27, 91>> <> "19~")
    end

    test "parses F9" do
      assert [%Event{type: :key, data: %{key: :f9}}] =
               InputParser.parse(<<27, 91>> <> "20~")
    end

    test "parses F10" do
      assert [%Event{type: :key, data: %{key: :f10}}] =
               InputParser.parse(<<27, 91>> <> "21~")
    end

    test "parses F11" do
      assert [%Event{type: :key, data: %{key: :f11}}] =
               InputParser.parse(<<27, 91>> <> "23~")
    end

    test "parses F12" do
      assert [%Event{type: :key, data: %{key: :f12}}] =
               InputParser.parse(<<27, 91>> <> "24~")
    end
  end

  describe "navigation keys" do
    test "parses Home (CSI H)" do
      assert [%Event{type: :key, data: %{key: :home}}] =
               InputParser.parse(<<27, 91, 72>>)
    end

    test "parses End (CSI F)" do
      assert [%Event{type: :key, data: %{key: :end}}] =
               InputParser.parse(<<27, 91, 70>>)
    end

    test "parses Home (CSI 1~)" do
      assert [%Event{type: :key, data: %{key: :home}}] =
               InputParser.parse(<<27, 91>> <> "1~")
    end

    test "parses End (CSI 4~)" do
      assert [%Event{type: :key, data: %{key: :end}}] =
               InputParser.parse(<<27, 91>> <> "4~")
    end

    test "parses Insert" do
      assert [%Event{type: :key, data: %{key: :insert}}] =
               InputParser.parse(<<27, 91>> <> "2~")
    end

    test "parses Delete" do
      assert [%Event{type: :key, data: %{key: :delete}}] =
               InputParser.parse(<<27, 91>> <> "3~")
    end

    test "parses PageUp" do
      assert [%Event{type: :key, data: %{key: :page_up}}] =
               InputParser.parse(<<27, 91>> <> "5~")
    end

    test "parses PageDown" do
      assert [%Event{type: :key, data: %{key: :page_down}}] =
               InputParser.parse(<<27, 91>> <> "6~")
    end

    test "parses Home (SS3 H)" do
      assert [%Event{type: :key, data: %{key: :home}}] =
               InputParser.parse(<<27, 79, 72>>)
    end

    test "parses End (SS3 F)" do
      assert [%Event{type: :key, data: %{key: :end}}] =
               InputParser.parse(<<27, 79, 70>>)
    end
  end

  describe "Shift+Tab" do
    test "parses backtab" do
      assert [%Event{type: :key, data: %{key: :tab, shift: true}}] =
               InputParser.parse(<<27, 91, 90>>)
    end
  end

  describe "modified arrows and navigation" do
    test "parses Shift+Up" do
      # ESC [ 1 ; 2 A
      assert [%Event{type: :key, data: %{key: :up, shift: true}}] =
               InputParser.parse(<<27, 91, 49, 59, 50, 65>>)
    end

    test "parses Alt+Right" do
      # ESC [ 1 ; 3 C (mod 3 = alt)
      assert [%Event{type: :key, data: %{key: :right, alt: true}}] =
               InputParser.parse(<<27, 91, 49, 59, 51, 67>>)
    end

    test "parses Ctrl+Left" do
      # ESC [ 1 ; 5 D (mod 5 = ctrl)
      assert [%Event{type: :key, data: %{key: :left, ctrl: true}}] =
               InputParser.parse(<<27, 91, 49, 59, 53, 68>>)
    end

    test "parses Ctrl+Shift+Down" do
      # ESC [ 1 ; 6 B (mod 6 = ctrl+shift)
      assert [%Event{type: :key, data: %{key: :down, ctrl: true, shift: true}}] =
               InputParser.parse(<<27, 91, 49, 59, 54, 66>>)
    end

    test "parses Ctrl+Alt+Up" do
      # ESC [ 1 ; 7 A (mod 7 = ctrl+alt)
      assert [%Event{type: :key, data: %{key: :up, ctrl: true, alt: true}}] =
               InputParser.parse(<<27, 91, 49, 59, 55, 65>>)
    end

    test "parses modified Home" do
      # ESC [ 1 ; 5 H (Ctrl+Home)
      assert [%Event{type: :key, data: %{key: :home, ctrl: true}}] =
               InputParser.parse(<<27, 91, 49, 59, 53, 72>>)
    end

    test "parses modified End" do
      # ESC [ 1 ; 5 F (Ctrl+End)
      assert [%Event{type: :key, data: %{key: :end, ctrl: true}}] =
               InputParser.parse(<<27, 91, 49, 59, 53, 70>>)
    end
  end

  describe "modified tilde sequences" do
    test "parses Ctrl+Delete" do
      # ESC [ 3 ; 5 ~
      assert [%Event{type: :key, data: %{key: :delete, ctrl: true}}] =
               InputParser.parse(<<27, 91>> <> "3;5~")
    end

    test "parses Shift+Insert" do
      # ESC [ 2 ; 2 ~
      assert [%Event{type: :key, data: %{key: :insert, shift: true}}] =
               InputParser.parse(<<27, 91>> <> "2;2~")
    end
  end

  describe "Alt+key" do
    test "parses Alt+a" do
      assert [%Event{type: :key, data: %{key: :char, char: "a", alt: true}}] =
               InputParser.parse(<<27, ?a>>)
    end

    test "parses Alt+z" do
      assert [%Event{type: :key, data: %{key: :char, char: "z", alt: true}}] =
               InputParser.parse(<<27, ?z>>)
    end

    test "parses Alt+A (uppercase)" do
      assert [%Event{type: :key, data: %{key: :char, char: "A", alt: true}}] =
               InputParser.parse(<<27, ?A>>)
    end
  end

  describe "Ctrl+letter" do
    test "parses Ctrl+A" do
      assert [%Event{type: :key, data: %{key: :char, char: "a", ctrl: true}}] =
               InputParser.parse(<<1>>)
    end

    test "parses Ctrl+C" do
      assert [%Event{type: :key, data: %{key: :char, char: "c", ctrl: true}}] =
               InputParser.parse(<<3>>)
    end

    test "parses Ctrl+D" do
      assert [%Event{type: :key, data: %{key: :char, char: "d", ctrl: true}}] =
               InputParser.parse(<<4>>)
    end

    test "parses Ctrl+Q" do
      assert [%Event{type: :key, data: %{key: :char, char: "q", ctrl: true}}] =
               InputParser.parse(<<17>>)
    end

    test "parses Ctrl+Z" do
      assert [%Event{type: :key, data: %{key: :char, char: "z", ctrl: true}}] =
               InputParser.parse(<<26>>)
    end

    test "Ctrl+I maps to tab (byte 9)" do
      assert [%Event{type: :key, data: %{key: :tab}}] = InputParser.parse(<<9>>)
    end

    test "Ctrl+J maps to enter (byte 10)" do
      assert [%Event{type: :key, data: %{key: :enter}}] =
               InputParser.parse(<<10>>)
    end

    test "Ctrl+M maps to enter (byte 13)" do
      assert [%Event{type: :key, data: %{key: :enter}}] =
               InputParser.parse(<<13>>)
    end
  end

  describe "mouse SGR events" do
    test "parses left button press" do
      # ESC [ < 0 ; 10 ; 20 M
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 60>> <> "0;10;20M")

      assert data.button == :left
      assert data.x == 10
      assert data.y == 20
      assert data.action == :press
    end

    test "parses left button release" do
      # ESC [ < 0 ; 10 ; 20 m
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 60>> <> "0;10;20m")

      assert data.button == :left
      assert data.action == :release
    end

    test "parses right button press" do
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 60>> <> "2;5;5M")

      assert data.button == :right
      assert data.action == :press
    end

    test "parses middle button press" do
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 60>> <> "1;5;5M")

      assert data.button == :middle
      assert data.action == :press
    end

    test "parses mouse motion" do
      # button code 32 = motion flag set, left button
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 60>> <> "32;15;25M")

      assert data.action == :move
    end

    test "parses wheel up" do
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 60>> <> "64;10;10M")

      assert data.button == :wheel_up
    end

    test "parses wheel down" do
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 60>> <> "65;10;10M")

      assert data.button == :wheel_down
    end
  end

  describe "X10/normal mouse events" do
    test "parses X10 left button press" do
      # ESC [ M <button+32> <x+32> <y+32>
      assert [%Event{type: :mouse, data: data}] =
               InputParser.parse(<<27, 91, 77, 32, 42, 52>>)

      assert data.button == :left
      assert data.x == 10
      assert data.y == 20
      assert data.action == :press
    end
  end

  describe "focus events" do
    test "parses focus in" do
      assert [%Event{type: :focus, data: %{focused: true}}] =
               InputParser.parse(<<27, 91, 73>>)
    end

    test "parses focus out" do
      assert [%Event{type: :focus, data: %{focused: false}}] =
               InputParser.parse(<<27, 91, 79>>)
    end
  end

  describe "bracketed paste" do
    test "parses complete paste" do
      # ESC [ 200 ~ <text> ESC [ 201 ~
      input =
        <<27, 91, 50, 48, 48, 126>> <>
          "hello world" <> <<27, 91, 50, 48, 49, 126>>

      assert [%Event{type: :paste, data: %{text: "hello world"}}] =
               InputParser.parse(input)
    end

    test "parses paste without end marker" do
      input = <<27, 91, 50, 48, 48, 126>> <> "partial paste"

      assert [%Event{type: :paste, data: %{text: "partial paste"}}] =
               InputParser.parse(input)
    end
  end

  describe "unknown input" do
    test "returns empty list for invalid sequence" do
      assert [] = InputParser.parse(<<128, 129, 130>>)
    end

    test "does not crash on a secondary DA reply (CSI > Pp ; Pv ; Pc c)" do
      # Some terminals answer unsolicited (or in response to a secondary DA
      # probe raxol never sends) with `CSI > ... c`. The leading `>` byte
      # must not hit a missing clause in parse_csi_params/3 and crash the
      # Driver GenServer with a FunctionClauseError.
      assert is_list(InputParser.parse("\e[>0;282;0c"))
    end

    test "does not crash on other CSI private-marker/intermediate bytes" do
      for seq <- ["\e[=1c", "\e[<35;10;10M-not-sgr", "\e[:1;2m", "\e[?9999h"] do
        assert is_list(InputParser.parse(seq))
      end
    end

    test "keeps parsing subsequent events after an unrecognized CSI sequence" do
      # A secondary DA reply immediately followed by a real key press must
      # not swallow the key press (or crash trying to reach it).
      events = InputParser.parse("\e[>0;282;0c" <> "q")

      assert %Event{type: :key, data: %{key: :char, char: "q"}} =
               List.last(events)
    end
  end

  describe "unmapped terminal reports (render-storm regression)" do
    # Well-formed CSI sequences with no event mapping must not leak: skipping
    # only the ESC byte and re-parsing the rest as printable char keys turns
    # one terminal report into a burst of spurious keystrokes. Terminal
    # reports must produce ZERO events.

    test "secondary DA reply produces zero events" do
      assert [] = InputParser.parse("\e[>0;282;0c")
    end

    test "primary DA reply produces zero events" do
      assert [] = InputParser.parse("\e[?62;4c")
    end

    test "cursor position report produces zero events" do
      assert [] = InputParser.parse("\e[42;120R")
    end

    test "DECRQM reply (with $ intermediate byte) produces zero events" do
      assert [] = InputParser.parse("\e[?2026;2$y")
    end

    test "kitty keyboard protocol reply produces zero events" do
      assert [] = InputParser.parse("\e[?1u")
    end

    test "report followed by a real key yields only that key" do
      assert [%Event{type: :key, data: %{key: :down}}] =
               InputParser.parse("\e[>0;282;0c\e[B")
    end

    test "report between two chars yields only those chars" do
      assert [
               %Event{type: :key, data: %{key: :char, char: "a"}},
               %Event{type: :key, data: %{key: :char, char: "b"}}
             ] = InputParser.parse("a\e[42;120Rb")
    end

    test "incomplete CSI fragment at end of chunk is dropped, not leaked" do
      # The driver's input buffer flushes incomplete escapes after a
      # timeout; the fragment must not degrade to char key events.
      assert [] = InputParser.parse("\e[12;3")
      assert [] = InputParser.parse("\e[>0;28")
    end

    test "truncated SGR mouse report is dropped, not leaked" do
      assert [] = InputParser.parse("\e[<35;10")
    end
  end
end
