defmodule Raxol.Terminal.ANSI.SGRProcessorTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ANSI.SGRProcessor

  describe "colon-form underline style (SGR 4:n)" do
    test "4:0 clears underline" do
      style = SGRProcessor.handle_sgr("4:0", nil)
      assert style.underline == false
      assert style.underline_style == :none
    end

    test "4:1 sets single underline" do
      style = SGRProcessor.handle_sgr("4:1", nil)
      assert style.underline == true
      assert style.underline_style == :single
    end

    test "4:2 sets double underline" do
      style = SGRProcessor.handle_sgr("4:2", nil)
      assert style.underline == true
      assert style.double_underline == true
      assert style.underline_style == :double
    end

    test "4:3 sets curly underline" do
      style = SGRProcessor.handle_sgr("4:3", nil)
      assert style.underline == true
      assert style.underline_style == :curly
    end

    test "4:4 sets dotted underline" do
      style = SGRProcessor.handle_sgr("4:4", nil)
      assert style.underline_style == :dotted
    end

    test "4:5 sets dashed underline" do
      style = SGRProcessor.handle_sgr("4:5", nil)
      assert style.underline_style == :dashed
    end

    test "unknown underline subparam is a no-op" do
      style = SGRProcessor.handle_sgr("4:9", nil)
      assert style.underline_style == :single
      assert style.underline == false
    end
  end

  describe "colon-form underline color (SGR 58)" do
    test "58:5:n sets an indexed underline color" do
      style = SGRProcessor.handle_sgr("58:5:196", nil)
      assert style.underline_color == {:indexed, 196}
    end

    test "58:2::r:g:b (empty colorspace slot) sets an RGB underline color" do
      style = SGRProcessor.handle_sgr("58:2::255:10:20", nil)
      assert style.underline_color == {:rgb, 255, 10, 20}
    end

    test "58:2:r:g:b (no colorspace slot) also sets an RGB underline color" do
      style = SGRProcessor.handle_sgr("58:2:255:10:20", nil)
      assert style.underline_color == {:rgb, 255, 10, 20}
    end

    test "59 resets underline color" do
      style =
        "58:2::1:2:3"
        |> SGRProcessor.handle_sgr(nil)
        |> then(&SGRProcessor.handle_sgr("59", &1))

      assert style.underline_color == nil
    end
  end

  describe "colon-form 38/48 truecolor and 256-color" do
    test "38:2::r:g:b sets RGB foreground" do
      style = SGRProcessor.handle_sgr("38:2::10:20:30", nil)
      assert style.foreground == {:rgb, 10, 20, 30}
    end

    test "38:5:n sets indexed foreground" do
      style = SGRProcessor.handle_sgr("38:5:200", nil)
      assert style.foreground == {:indexed, 200}
    end

    test "48:2::r:g:b sets RGB background" do
      style = SGRProcessor.handle_sgr("48:2::1:2:3", nil)
      assert style.background == {:rgb, 1, 2, 3}
    end

    test "48:5:n sets indexed background" do
      style = SGRProcessor.handle_sgr("48:5:5", nil)
      assert style.background == {:indexed, 5}
    end
  end

  describe "mixed colon and semicolon params in one sequence" do
    test "bold + curly underline + red foreground" do
      style = SGRProcessor.handle_sgr("1;4:3;31", nil)
      assert style.bold == true
      assert style.underline == true
      assert style.underline_style == :curly
      assert style.foreground == :red
    end

    test "styled underline followed by extended color consumes its own params only" do
      style = SGRProcessor.handle_sgr("4:3;38;5;196;1", nil)
      assert style.underline_style == :curly
      assert style.foreground == {:indexed, 196}
      assert style.bold == true
    end
  end

  describe "round trip: parse -> process_sgr_codes with pre-split codes" do
    test "process_sgr_codes still accepts a flat integer list (unaffected by colon support)" do
      style = SGRProcessor.process_sgr_codes([1, 4, 31, 48, 5, 196], nil)
      assert style.bold == true
      assert style.underline == true
      assert style.foreground == :red
      assert style.background == {:indexed, 196}
    end
  end

  describe "regression: plain semicolon-form parsing is unchanged" do
    test "basic attributes and colors" do
      style = SGRProcessor.handle_sgr("1;4;31;48;5;196", nil)
      assert style.bold == true
      assert style.underline == true
      assert style.foreground == :red
      assert style.background == {:indexed, 196}
      # Untouched by the plain semicolon underline (4), not a colon form
      assert style.underline_style == :single
      assert style.underline_color == nil
    end

    test "truecolor semicolon foreground/background" do
      style = SGRProcessor.handle_sgr("38;2;10;20;30;48;2;40;50;60", nil)
      assert style.foreground == {:rgb, 10, 20, 30}
      assert style.background == {:rgb, 40, 50, 60}
    end

    test "existing semicolon-form underline color (58;5;n / 58;2;r;g;b)" do
      style = SGRProcessor.handle_sgr("58;5;10", nil)
      assert style.underline_color == {:indexed, 10}

      style2 = SGRProcessor.handle_sgr("58;2;9;8;7", nil)
      assert style2.underline_color == {:rgb, 9, 8, 7}
    end

    test "reset (0) clears everything, including new underline fields" do
      style =
        "1;4:3;58:2::1:2:3"
        |> SGRProcessor.handle_sgr(nil)
        |> then(&SGRProcessor.handle_sgr("0", &1))

      assert style.bold == false
      assert style.underline == false
      assert style.underline_style == :single
      assert style.underline_color == nil
    end

    test "empty params string defaults to reset (0)" do
      style = SGRProcessor.handle_sgr("", nil)
      assert style.bold == false
    end
  end
end
