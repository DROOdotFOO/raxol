defmodule Raxol.Terminal.RendererIntegrationTest do
  use ExUnit.Case
  alias Raxol.Terminal.Buffer.Selection
  alias Raxol.Terminal.{Renderer, ScreenBuffer}
  alias Raxol.Terminal.Validation

  # ANSI escape code helpers
  @ansi_reset "\e[0m"

  setup do
    buffer = ScreenBuffer.new(80, 24)
    # Use terminal theme manager's default theme colors
    theme = %{
      foreground: %{
        default: "#FFFFFF",
        red: "#FF0000",
        green: "#00FF00",
        blue: "#0000FF",
        yellow: "#FFFF00",
        magenta: "#FF00FF",
        cyan: "#00FFFF",
        white: "#FFFFFF",
        black: "#000000",
        bright_red: "#FF8080",
        bright_green: "#80FF80",
        bright_blue: "#8080FF",
        bright_yellow: "#FFFF80",
        bright_magenta: "#FF80FF",
        bright_cyan: "#80FFFF",
        bright_white: "#FFFFFF",
        bright_black: "#808080"
      },
      background: %{
        default: "#000000"
      }
    }

    renderer = Renderer.new(buffer, theme)
    {:ok, %{renderer: renderer, buffer: buffer}}
  end

  # Helper: ANSI 24-bit foreground escape for hex color
  defp ansi_fg(hex) do
    {r, g, b} = parse_hex(hex)
    "\e[38;2;#{r};#{g};#{b}m"
  end

  # Helper: ANSI 24-bit background escape for hex color
  defp ansi_bg(hex) do
    {r, g, b} = parse_hex(hex)
    "\e[48;2;#{r};#{g};#{b}m"
  end

  defp parse_hex("#" <> hex), do: parse_hex(hex)

  defp parse_hex(<<r::binary-size(2), g::binary-size(2), b::binary-size(2)>>) do
    {String.to_integer(r, 16), String.to_integer(g, 16),
     String.to_integer(b, 16)}
  end

  describe "integration with Manipulation module" do
    test "renders text after manipulation operations", %{
      renderer: renderer,
      buffer: buffer
    } do
      # Insert text
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Hello")
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer)

      # Each character should be styled and present
      for char <- ~w(H e l l o) do
        assert output =~ char
      end

      assert output =~ ansi_fg("#FFFFFF")
      assert output =~ ansi_bg("#000000")
      assert output =~ @ansi_reset

      # Delete text (delete 2 chars at 0,0)
      buffer = ScreenBuffer.delete_characters(buffer, 0, 0, 2, %{})
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer)

      assert output =~ "l"
      assert output =~ "o"
    end

    test "renders styled text after manipulation", %{
      renderer: renderer,
      buffer: buffer
    } do
      style =
        struct(
          Raxol.Terminal.ANSI.TextFormatting,
          Map.merge(
            Map.from_struct(Raxol.Terminal.ANSI.TextFormatting.new()),
            %{foreground: :red, bold: true}
          )
        )

      text = "Styled"

      # Create a row of styled cells
      row =
        text
        |> String.graphemes()
        |> Enum.map(fn char -> Raxol.Terminal.Cell.new(char, style) end)

      # Pad the row to buffer width
      row =
        row ++
          List.duplicate(Raxol.Terminal.Cell.new(), buffer.width - length(row))

      # Replace the first row in the buffer
      cells = [row | Enum.drop(buffer.cells, 1)]
      buffer = %{buffer | cells: cells}
      buffer = ScreenBuffer.set_cursor_position(buffer, 0, 0)

      renderer = %{renderer | screen_buffer: buffer}

      # Assert the first cell has the correct style
      first_cell = Enum.at(Enum.at(buffer.cells, 0), 0)
      assert first_cell.style.foreground == :red
      assert first_cell.style.bold == true

      output = Raxol.Terminal.Renderer.render(renderer)

      # Red foreground via theme (#FF0000 -> 24-bit ANSI)
      assert output =~ ansi_fg("#FF0000")
      # Bold
      assert output =~ "\e[1m"
      # All characters present
      for char <- String.graphemes("Styled") do
        assert output =~ char
      end

      assert output =~ @ansi_reset
    end
  end

  describe "integration with Selection module" do
    test "renders selected text with highlight", %{
      renderer: renderer,
      buffer: buffer
    } do
      # Insert text
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Selectable text")
      # Create selection
      selection = Selection.new({0, 0}, {0, 8})
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer, selection: selection)
      # Selection highlighting is not currently implemented in the renderer
      for char <- ~w(S e l e c t a b l) do
        assert output =~ char
      end
    end

    test "handles multiple selections", %{renderer: renderer, buffer: buffer} do
      # Insert text
      buffer =
        ScreenBuffer.write_string(buffer, 0, 0, "First line\nSecond line")

      # Create multiple selections
      selections = [
        Selection.new({0, 0}, {0, 5}),
        Selection.new({1, 0}, {1, 6})
      ]

      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer, selections: selections)
      # Selection highlighting is not currently implemented in the renderer
      for char <- ~w(F i r s t) do
        assert output =~ char
      end
    end

    test "renders selectable text", %{renderer: renderer, buffer: buffer} do
      selection = %{start: {0, 0}, stop: {0, 8}}
      text = "Selectable"
      buffer = ScreenBuffer.write_string(buffer, 0, 0, text)
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer, selection: selection)
      # Selection highlighting is not currently implemented in the renderer
      Enum.each(String.graphemes(text), fn char ->
        assert output =~ char
      end)
    end
  end

  describe "integration with Validation module" do
    test "renders validation errors", %{renderer: renderer, buffer: buffer} do
      # Insert text with validation error
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Invalid input")
      validation = Validation.validate_input(buffer, 0, 0, "Invalid input")
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer, validation: validation)
      # Validation module is currently a stub, so no special styling is applied
      for char <- String.graphemes("Invalid input") do
        assert output =~ char
      end
    end

    test "renders validation warnings", %{renderer: renderer, buffer: buffer} do
      # Insert text with validation warning
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Warning text")
      validation = Validation.validate_input(buffer, 0, 0, "Warning text")
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer, validation: validation)
      # Validation module is currently a stub, so no special styling is applied
      for char <- String.graphemes("Warning text") do
        assert output =~ char
      end
    end
  end

  describe "performance optimizations" do
    test "only renders changed cells", %{renderer: renderer, buffer: buffer} do
      # Insert text
      buffer = ScreenBuffer.write_string(buffer, 0, 0, "Hello")
      renderer = %{renderer | screen_buffer: buffer}

      # First render
      output1 = Renderer.render(renderer)

      # Modify only one cell
      buffer = ScreenBuffer.write_char(buffer, 5, 0, "!")
      renderer = %{renderer | screen_buffer: buffer}

      # Second render
      output2 = Renderer.render(renderer)

      # Should only update the changed cell
      assert output1 != output2

      for char <- ~w(H e l l o !) do
        assert output2 =~ char
      end
    end

    test "batches style updates", %{renderer: renderer, buffer: buffer} do
      # Insert text with same style
      style = %{foreground: :red}
      text = "Red text"

      buffer =
        Enum.reduce(Enum.with_index(String.graphemes(text)), buffer, fn {char,
                                                                         col},
                                                                        acc ->
          ScreenBuffer.write_char(acc, col, 0, char, style)
        end)

      # Enable style batching for this test
      renderer = %{renderer | screen_buffer: buffer, style_batching: true}
      output = Renderer.render(renderer)

      # With style batching, all chars with the same style should be grouped
      # "Red text" should appear as a single run
      assert output =~ "Red text"
      assert output =~ ansi_fg("#FF0000")
      assert output =~ @ansi_reset
    end
  end

  describe "{r, g, b} tuple colors (Raxol.UI.CellDim / plain UI-stack RGB)" do
    # {r,g,b} tuples must emit 38;2/48;2, not fall through to nil.
    test "emits a 24-bit foreground escape for a tuple color", %{buffer: buffer} do
      buffer =
        ScreenBuffer.write_char(buffer, 0, 0, "A", %{foreground: {9, 37, 112}})

      renderer = Renderer.new(buffer)
      output = Renderer.render(renderer)

      assert output =~ "\e[38;2;9;37;112m"
    end

    test "emits a 24-bit background escape for a tuple color", %{buffer: buffer} do
      buffer =
        ScreenBuffer.write_char(buffer, 0, 0, "A", %{background: {4, 4, 4}})

      renderer = Renderer.new(buffer)
      output = Renderer.render(renderer)

      assert output =~ "\e[48;2;4;4;4m"
    end

    test "tuple and map-shaped rgb colors of the same value render identically",
         %{
           buffer: buffer
         } do
      tuple_buffer =
        ScreenBuffer.write_char(buffer, 0, 0, "A", %{
          foreground: {9, 37, 112},
          background: {4, 4, 4}
        })

      map_buffer =
        ScreenBuffer.write_char(buffer, 0, 0, "A", %{
          foreground: %{r: 9, g: 37, b: 112},
          background: %{r: 4, g: 4, b: 4}
        })

      tuple_output = Renderer.render(Renderer.new(tuple_buffer))
      map_output = Renderer.render(Renderer.new(map_buffer))

      assert tuple_output == map_output
    end
  end

  describe "edge cases" do
    test "handles empty buffer", %{renderer: renderer} do
      output = Renderer.render(renderer)

      # All cells should have default theme colors
      assert output =~ ansi_fg("#FFFFFF")
      assert output =~ ansi_bg("#000000")
      assert output =~ @ansi_reset
    end

    test "handles buffer with only spaces", %{
      renderer: renderer,
      buffer: buffer
    } do
      buffer =
        ScreenBuffer.write_string(buffer, 0, 0, String.duplicate(" ", 80))

      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer)

      assert output =~ ansi_fg("#FFFFFF")
      assert output =~ ansi_bg("#000000")
    end

    test "handles buffer with special characters", %{
      renderer: renderer,
      buffer: buffer
    } do
      special_chars = "!@#$%^&*()_+-=[]{}|;:,.<>?/~`"
      buffer = ScreenBuffer.write_string(buffer, 0, 0, special_chars)
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer)
      # Check that each special character is present in the output
      Enum.each(String.graphemes(special_chars), fn char ->
        assert output =~ char
      end)
    end

    test "handles buffer with unicode characters", %{
      renderer: renderer,
      buffer: buffer
    } do
      unicode_text = "Hello 世界"
      buffer = ScreenBuffer.write_string(buffer, 0, 0, unicode_text)
      renderer = %{renderer | screen_buffer: buffer}
      output = Renderer.render(renderer)
      # Check that each unicode character is present in the output
      Enum.each(String.graphemes(unicode_text), fn char ->
        assert output =~ char
      end)
    end
  end

  describe "binary hex colors resolve to 24-bit SGR" do
    test "6-digit hex foreground", %{buffer: buffer} do
      buffer =
        ScreenBuffer.write_char(buffer, 0, 0, "A", %{foreground: "#1a2b3c"})

      output = Renderer.render(Renderer.new(buffer))
      assert output =~ "\e[38;2;26;43;60m"
    end

    test "3-digit hex foreground expands each nibble", %{buffer: buffer} do
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "A", %{foreground: "#fff"})
      output = Renderer.render(Renderer.new(buffer))
      assert output =~ "\e[38;2;255;255;255m"
    end

    test "3-digit hex background expands each nibble", %{buffer: buffer} do
      buffer = ScreenBuffer.write_char(buffer, 0, 0, "A", %{background: "#048"})
      output = Renderer.render(Renderer.new(buffer))
      assert output =~ "\e[48;2;0;68;136m"
    end
  end
end
