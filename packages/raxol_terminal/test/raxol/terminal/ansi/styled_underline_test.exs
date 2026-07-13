defmodule Raxol.Terminal.ANSI.StyledUnderlineTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.{Emulator, Renderer, ScreenBuffer}

  # These exercise the live CSI dispatch pipeline
  # (Emulator.process_input -> Parser -> Executor -> CSIHandler -> SGR
  # Processor), not just the SGRProcessor module in isolation. Colon
  # subparameters previously aborted the whole escape sequence at the
  # byte-level CSI param parser before reaching any SGR code.

  describe "live emulator dispatch: colon-form SGR" do
    test "4:3 sets curly underline on emulator.style" do
      {emulator, _} = Emulator.process_input(Emulator.new(), "\e[4:3m")
      assert emulator.style.underline == true
      assert emulator.style.underline_style == :curly
    end

    test "4:0 through 4:5 map to the expected underline styles" do
      expected = %{
        0 => :none,
        1 => :single,
        2 => :double,
        3 => :curly,
        4 => :dotted,
        5 => :dashed
      }

      for {n, style} <- expected do
        {emulator, _} = Emulator.process_input(Emulator.new(), "\e[4:#{n}m")
        assert emulator.style.underline_style == style
      end
    end

    test "58:2::r:g:b sets an RGB underline color" do
      {emulator, _} =
        Emulator.process_input(Emulator.new(), "\e[58:2::255:10:20m")

      assert emulator.style.underline_color == {:rgb, 255, 10, 20}
    end

    test "58:5:n sets an indexed underline color" do
      {emulator, _} = Emulator.process_input(Emulator.new(), "\e[58:5:196m")
      assert emulator.style.underline_color == {:index, 196}
    end

    test "59 resets underline color" do
      {emulator, _} =
        Emulator.process_input(Emulator.new(), "\e[58:5:196m")

      assert emulator.style.underline_color != nil

      {emulator, _} = Emulator.process_input(emulator, "\e[59m")
      assert emulator.style.underline_color == nil
    end

    test "colon and semicolon params combine in a single sequence" do
      {emulator, _} =
        Emulator.process_input(Emulator.new(), "\e[1;4:4;58;2;1;2;3m")

      assert emulator.style.bold == true
      assert emulator.style.underline_style == :dotted
      assert emulator.style.underline_color == {:rgb, 1, 2, 3}
    end
  end

  describe "regression: plain semicolon-form SGR is unaffected" do
    test "bold + red foreground still works" do
      {emulator, _} = Emulator.process_input(Emulator.new(), "\e[1;31m")
      assert emulator.style.bold == true
      assert emulator.style.foreground == :red
      assert emulator.style.underline_style == :single
      assert emulator.style.underline_color == nil
    end

    test "plain underline (4) toggles the boolean without touching underline_style" do
      {emulator, _} = Emulator.process_input(Emulator.new(), "\e[4m")
      assert emulator.style.underline == true
      assert emulator.style.underline_style == :single

      {emulator, _} = Emulator.process_input(emulator, "\e[24m")
      assert emulator.style.underline == false
    end
  end

  describe "round trip: parse -> render -> parse" do
    test "curly underline survives a render round trip" do
      {emulator, _} = Emulator.process_input(Emulator.new(), "\e[4:3m")

      buffer = ScreenBuffer.new(1, 1)
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "x", emulator.style)
      output = Renderer.new(buffer) |> Renderer.render()

      assert output =~ "\e[4:3m"

      # Reparse just the style prefix -- `output` also carries the trailing
      # `\e[0m` reset emitted after the styled char, which would otherwise
      # correctly reset the style back to defaults.
      [prefix, _] = String.split(output, "x", parts: 2)
      {reparsed, _} = Emulator.process_input(Emulator.new(), prefix)
      assert reparsed.style.underline_style == :curly
    end

    test "RGB underline color survives a render round trip" do
      {emulator, _} =
        Emulator.process_input(Emulator.new(), "\e[58:2::9:8:7m")

      buffer = ScreenBuffer.new(1, 1)
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "x", emulator.style)
      output = Renderer.new(buffer) |> Renderer.render()

      assert output =~ "\e[58;2;9;8;7m"

      [prefix, _] = String.split(output, "x", parts: 2)
      {reparsed, _} = Emulator.process_input(Emulator.new(), prefix)
      assert reparsed.style.underline_color == {:rgb, 9, 8, 7}
    end

    test "plain underline still renders as the bare \\e[4m form" do
      {emulator, _} = Emulator.process_input(Emulator.new(), "\e[4m")

      buffer = ScreenBuffer.new(1, 1)
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "x", emulator.style)
      output = Renderer.new(buffer) |> Renderer.render()

      assert output =~ "\e[4m"
      refute output =~ "\e[4:"
    end
  end
end
