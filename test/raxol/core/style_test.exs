defmodule Raxol.Core.StyleTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Style

  describe "new/1" do
    test "returns default style with no options" do
      assert Style.new() == %{
               bold: false,
               italic: false,
               underline: false,
               fg_color: nil,
               bg_color: nil
             }
    end

    test "sets bold" do
      assert %{bold: true} = Style.new(bold: true)
    end

    test "sets italic" do
      assert %{italic: true} = Style.new(italic: true)
    end

    test "sets underline" do
      assert %{underline: true} = Style.new(underline: true)
    end

    test "sets fg_color as named color" do
      assert %{fg_color: :red} = Style.new(fg_color: :red)
    end

    test "sets bg_color as named color" do
      assert %{bg_color: :green} = Style.new(bg_color: :green)
    end

    test "sets fg_color as RGB tuple" do
      assert %{fg_color: {255, 128, 0}} = Style.new(fg_color: {255, 128, 0})
    end

    test "sets fg_color as 256-color index" do
      assert %{fg_color: 196} = Style.new(fg_color: 196)
    end

    test "sets multiple options at once" do
      style = Style.new(bold: true, italic: true, fg_color: :blue, bg_color: :white)

      assert style == %{
               bold: true,
               italic: true,
               underline: false,
               fg_color: :blue,
               bg_color: :white
             }
    end
  end

  describe "merge/2" do
    test "override values take precedence" do
      base = Style.new(bold: true, fg_color: :red)
      override = Style.new(fg_color: :blue)
      merged = Style.merge(base, override)

      assert merged.fg_color == :blue
    end

    test "preserves base values not present in override" do
      base = Style.new(bold: true, italic: true, fg_color: :red)
      override = %{fg_color: :blue}
      merged = Style.merge(base, override)

      assert merged.bold == true
      assert merged.italic == true
      assert merged.fg_color == :blue
    end

    test "override false replaces base true" do
      base = Style.new(bold: true)
      override = Style.new(bold: false)
      merged = Style.merge(base, override)

      assert merged.bold == false
    end

    test "override nil replaces base color" do
      base = Style.new(fg_color: :red)
      override = Style.new()
      merged = Style.merge(base, override)

      assert merged.fg_color == nil
    end

    test "merges two fully specified styles" do
      base = Style.new(bold: true, italic: true, underline: true, fg_color: :red, bg_color: :white)
      override = Style.new(bold: false, italic: false, underline: false, fg_color: :blue, bg_color: :black)

      assert Style.merge(base, override) == override
    end
  end

  describe "rgb/3" do
    test "creates an RGB tuple" do
      assert Style.rgb(255, 100, 50) == {255, 100, 50}
    end

    test "accepts boundary values 0 and 255" do
      assert Style.rgb(0, 0, 0) == {0, 0, 0}
      assert Style.rgb(255, 255, 255) == {255, 255, 255}
    end

    test "raises on value below 0" do
      assert_raise FunctionClauseError, fn -> Style.rgb(-1, 0, 0) end
    end

    test "raises on value above 255" do
      assert_raise FunctionClauseError, fn -> Style.rgb(256, 0, 0) end
    end

    test "raises when green channel is out of range" do
      assert_raise FunctionClauseError, fn -> Style.rgb(0, 256, 0) end
    end

    test "raises when blue channel is out of range" do
      assert_raise FunctionClauseError, fn -> Style.rgb(0, 0, 256) end
    end
  end

  describe "color_256/1" do
    test "returns a valid index" do
      assert Style.color_256(196) == 196
    end

    test "accepts boundary value 0" do
      assert Style.color_256(0) == 0
    end

    test "accepts boundary value 255" do
      assert Style.color_256(255) == 255
    end

    test "raises on index below 0" do
      assert_raise FunctionClauseError, fn -> Style.color_256(-1) end
    end

    test "raises on index above 255" do
      assert_raise FunctionClauseError, fn -> Style.color_256(256) end
    end
  end

  describe "named_color/1" do
    test "validates all named colors" do
      for color <- [:black, :red, :green, :yellow, :blue, :magenta, :cyan, :white] do
        assert Style.named_color(color) == color
      end
    end

    test "raises on invalid color name" do
      assert_raise FunctionClauseError, fn -> apply(Style, :named_color, [:orange]) end
    end
  end

  describe "to_ansi/1" do
    test "empty style returns empty string" do
      assert Style.to_ansi(Style.new()) == ""
    end

    test "bold only" do
      style = Style.new(bold: true)
      assert Style.to_ansi(style) == "\e[1m"
    end

    test "italic only" do
      style = Style.new(italic: true)
      assert Style.to_ansi(style) == "\e[3m"
    end

    test "underline only" do
      style = Style.new(underline: true)
      assert Style.to_ansi(style) == "\e[4m"
    end

    test "named fg color blue" do
      style = Style.new(fg_color: :blue)
      assert Style.to_ansi(style) == "\e[34m"
    end

    test "named fg color red" do
      style = Style.new(fg_color: :red)
      assert Style.to_ansi(style) == "\e[31m"
    end

    test "named fg color black" do
      style = Style.new(fg_color: :black)
      assert Style.to_ansi(style) == "\e[30m"
    end

    test "named bg color blue" do
      style = Style.new(bg_color: :blue)
      assert Style.to_ansi(style) == "\e[44m"
    end

    test "named bg color red" do
      style = Style.new(bg_color: :red)
      assert Style.to_ansi(style) == "\e[41m"
    end

    test "named bg color white" do
      style = Style.new(bg_color: :white)
      assert Style.to_ansi(style) == "\e[47m"
    end

    test "RGB fg color" do
      style = Style.new(fg_color: {100, 150, 200})
      assert Style.to_ansi(style) == "\e[38;2;100;150;200m"
    end

    test "RGB bg color" do
      style = Style.new(bg_color: {10, 20, 30})
      assert Style.to_ansi(style) == "\e[48;2;10;20;30m"
    end

    test "256-color fg" do
      style = Style.new(fg_color: 196)
      assert Style.to_ansi(style) == "\e[38;5;196m"
    end

    test "256-color bg" do
      style = Style.new(bg_color: 42)
      assert Style.to_ansi(style) == "\e[48;5;42m"
    end

    test "combined bold + named fg + named bg" do
      style = Style.new(bold: true, fg_color: :green, bg_color: :black)
      assert Style.to_ansi(style) == "\e[1;32;40m"
    end

    test "combined bold + italic + underline" do
      style = Style.new(bold: true, italic: true, underline: true)
      assert Style.to_ansi(style) == "\e[1;3;4m"
    end

    test "combined all attributes with RGB colors" do
      style = Style.new(
        bold: true,
        italic: true,
        underline: true,
        fg_color: {255, 0, 0},
        bg_color: {0, 0, 255}
      )

      assert Style.to_ansi(style) == "\e[1;3;4;38;2;255;0;0;48;2;0;0;255m"
    end

    test "combined bold with 256-color fg and named bg" do
      style = Style.new(bold: true, fg_color: 100, bg_color: :cyan)
      assert Style.to_ansi(style) == "\e[1;38;5;100;46m"
    end

    test "ignores invalid fg color atom" do
      style = %{bold: false, italic: false, underline: false, fg_color: :orange, bg_color: nil}
      assert Style.to_ansi(style) == ""
    end

    test "ignores invalid bg color atom" do
      style = %{bold: false, italic: false, underline: false, fg_color: nil, bg_color: :purple}
      assert Style.to_ansi(style) == ""
    end
  end

  describe "reset/0" do
    test "returns ANSI reset sequence" do
      assert Style.reset() == "\e[0m"
    end
  end
end
