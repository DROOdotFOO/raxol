defmodule Raxol.Terminal.RendererTest do
  use ExUnit.Case
  alias Raxol.Terminal.{Renderer, ScreenBuffer}

  defp default_buffer(width \\ 80, height \\ 24) do
    ScreenBuffer.new(width, height)
  end

  describe "new/1" do
    test ~c"creates a new renderer with a screen buffer" do
      buffer = default_buffer()
      renderer = Renderer.new(buffer)
      assert renderer.screen_buffer == buffer
      assert renderer.cursor == nil
      assert renderer.theme == %{}
      assert renderer.font_settings == %{}
    end

    test ~c"creates a new renderer with theme and font settings" do
      buffer = default_buffer()
      theme = %{foreground: :blue}
      font_settings = %{size: 12}
      renderer = Renderer.new(buffer, theme, font_settings)
      assert renderer.screen_buffer == buffer
      assert renderer.theme == theme
      assert renderer.font_settings == font_settings
    end
  end

  describe "render/1" do
    test ~c"renders empty screen buffer" do
      buffer = default_buffer(10, 1)
      renderer = Renderer.new(buffer)
      output = Renderer.render(renderer)
      # Empty buffer with no theme produces unstyled spaces (no ANSI codes)
      assert output == String.duplicate(" ", 10)
    end

    test ~c"renders screen buffer with content" do
      buffer = default_buffer(5, 1)
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "H", %{foreground: :red})
      buffer = ScreenBuffer.write_char(buffer, 1, 0, "i")

      renderer =
        Renderer.new(buffer, %{foreground: %{default: "#FFF", red: "#F00"}})

      output = Renderer.render(renderer)

      # "H" has red foreground via theme (#F00 -> 24-bit ANSI)
      # "i" and spaces have default foreground (#FFF -> 24-bit ANSI)
      assert String.contains?(output, "H")
      assert String.contains?(output, "i")
      assert String.contains?(output, "\e[")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders multiple rows" do
      buffer = default_buffer(3, 2)
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "A")
      buffer = ScreenBuffer.write_char(buffer, 1, 1, "B")

      renderer = Renderer.new(buffer, %{foreground: %{default: "#CCC"}})
      output = Renderer.render(renderer)

      # Multiple rows separated by newline
      assert String.contains?(output, "\n")
      assert String.contains?(output, "A")
      assert String.contains?(output, "B")
    end
  end

  describe "set_cursor/2" do
    test ~c"sets the cursor position" do
      buffer = default_buffer()
      renderer = Renderer.new(buffer)
      renderer = Renderer.set_cursor(renderer, {10, 5})
      assert renderer.cursor == {10, 5}
    end
  end

  describe "clear_cursor/1" do
    test ~c"clears the cursor position" do
      buffer = default_buffer()
      renderer = Renderer.new(buffer)
      renderer = Renderer.set_cursor(renderer, {10, 5})
      renderer = Renderer.clear_cursor(renderer)
      assert renderer.cursor == nil
    end
  end

  describe "set_theme/2" do
    test ~c"updates the theme" do
      buffer = default_buffer()
      renderer = Renderer.new(buffer)
      theme = %{foreground: %{default: "#ABC"}}
      renderer = Renderer.set_theme(renderer, theme)
      assert renderer.theme == theme
    end
  end

  describe "set_font_settings/2" do
    test ~c"updates the font settings" do
      buffer = default_buffer()
      renderer = Renderer.new(buffer)
      settings = %{family: "Fira Code"}
      renderer = Renderer.set_font_settings(renderer, settings)
      assert renderer.font_settings == settings
    end
  end

  describe "render_cell (via render)" do
    test ~c"renders basic cell" do
      buffer = ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X")
      renderer = Renderer.new(buffer, %{foreground: %{default: "#FFF"}})
      output = Renderer.render(renderer)
      # Should contain the character with ANSI styling
      assert String.contains?(output, "X")
      assert String.contains?(output, "\e[38;2;255;255;255m")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders cell with foreground color" do
      style = %{foreground: :red}

      buffer =
        ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X", style)

      theme = %{foreground: %{red: "#FF0000"}}
      renderer = Renderer.new(buffer, theme)
      output = Renderer.render(renderer)
      # Red foreground via theme: 24-bit ANSI
      assert String.contains?(output, "\e[38;2;255;0;0m")
      assert String.contains?(output, "X")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders cell with background color" do
      style = %{background: :blue}

      buffer =
        ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X", style)

      theme = %{background: %{blue: "#0000FF"}}
      renderer = Renderer.new(buffer, theme)
      output = Renderer.render(renderer)
      # Blue background via theme: 24-bit ANSI
      assert String.contains?(output, "\e[48;2;0;0;255m")
      assert String.contains?(output, "X")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders cell with bold style" do
      style = %{bold: true}

      buffer =
        ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X", style)

      renderer = Renderer.new(buffer)
      output = Renderer.render(renderer)
      assert String.contains?(output, "\e[1m")
      assert String.contains?(output, "X")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders cell with underline style" do
      style = %{underline: true}

      buffer =
        ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X", style)

      renderer = Renderer.new(buffer)
      output = Renderer.render(renderer)
      assert String.contains?(output, "\e[4m")
      assert String.contains?(output, "X")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders cell with italic style" do
      style = %{italic: true}

      buffer =
        ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X", style)

      renderer = Renderer.new(buffer)
      output = Renderer.render(renderer)
      assert String.contains?(output, "\e[3m")
      assert String.contains?(output, "X")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders cell with multiple styles" do
      style = %{
        foreground: :green,
        background: :black,
        bold: true,
        italic: true
      }

      buffer =
        ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X", style)

      theme = %{
        foreground: %{green: "#00FF00"},
        background: %{black: "#000000"}
      }

      renderer = Renderer.new(buffer, theme)
      output = Renderer.render(renderer)

      assert String.contains?(output, "X")
      # Foreground green via 24-bit ANSI
      assert String.contains?(output, "\e[38;2;0;255;0m")
      # Background black via 24-bit ANSI
      assert String.contains?(output, "\e[48;2;0;0;0m")
      # Bold
      assert String.contains?(output, "\e[1m")
      # Italic
      assert String.contains?(output, "\e[3m")
      # Reset
      assert String.contains?(output, "\e[0m")
    end

    test ~c"uses default theme colors when cell style is nil" do
      buffer = ScreenBuffer.new(1, 1) |> ScreenBuffer.write_char(0, 0, "X", %{})

      theme = %{
        foreground: %{default: "#AABBCC"},
        background: %{default: "#DDEEFF"}
      }

      renderer = Renderer.new(buffer, theme)
      output = Renderer.render(renderer)

      assert String.contains?(output, "X")
      # Default fg: #AABBCC
      assert String.contains?(output, "\e[38;2;170;187;204m")
      # Default bg: #DDEEFF
      assert String.contains?(output, "\e[48;2;221;238;255m")
      assert String.contains?(output, "\e[0m")
      # No bold/italic/underline
      refute String.contains?(output, "\e[1m")
      refute String.contains?(output, "\e[3m")
      refute String.contains?(output, "\e[4m")
    end

    test ~c"handles missing theme colors gracefully" do
      buffer =
        ScreenBuffer.new(1, 1)
        |> ScreenBuffer.write_char(0, 0, "X", %{foreground: :red})

      renderer = Renderer.new(buffer, %{})
      output = Renderer.render(renderer)
      # With empty theme, red falls back to standard ANSI code 31
      assert String.contains?(output, "\e[31m")
      assert String.contains?(output, "X")
      assert String.contains?(output, "\e[0m")
    end

    test ~c"renders cell with standard ANSI color when no theme" do
      buffer =
        ScreenBuffer.new(1, 1)
        |> ScreenBuffer.write_char(0, 0, "X", %{foreground: :green})

      renderer = Renderer.new(buffer)
      output = Renderer.render(renderer)
      assert String.contains?(output, "\e[32m")
      assert String.contains?(output, "X")
    end
  end

  describe "render_rows/1 and render_row/2" do
    defp styled_multi_row_buffer do
      ScreenBuffer.new(6, 3)
      |> ScreenBuffer.write_char(0, 0, "h", %{foreground: :red, bold: true})
      |> ScreenBuffer.write_char(1, 0, "i", %{foreground: :red})
      |> ScreenBuffer.write_char(0, 1, "世", %{})
      |> ScreenBuffer.write_char(0, 2, "z", %{background: :blue})
    end

    test ~c"render/1 is join(render_rows, \\n) -- the G1 pin" do
      for buffer <- [styled_multi_row_buffer(), default_buffer(10, 4)],
          batching <- [false, true] do
        renderer = Renderer.new(buffer, %{}, %{}, batching)

        assert Renderer.render(renderer) ==
                 Enum.join(Renderer.render_rows(renderer), "\n")
      end
    end

    test ~c"render_row/2 equals its slice of render_rows/1" do
      renderer = Renderer.new(styled_multi_row_buffer(), %{}, %{}, true)
      rows = Renderer.render_rows(renderer)

      for y <- 0..(length(rows) - 1) do
        assert Renderer.render_row(renderer, y) == Enum.at(rows, y)
      end
    end

    test ~c"render_row/2 renders a row in isolation with no pen bleed" do
      renderer = Renderer.new(styled_multi_row_buffer(), %{}, %{}, true)
      # row 0 opens its own SGR; it does not depend on any prior row's pen
      assert Renderer.render_row(renderer, 0) =~ "\e[31m"
      assert Renderer.render_row(renderer, 0) =~ "\e[0m"
    end

    test ~c"render_row/2 out of range is empty" do
      renderer = Renderer.new(ScreenBuffer.new(4, 2), %{}, %{}, false)
      assert Renderer.render_row(renderer, 99) == ""
    end
  end
end
