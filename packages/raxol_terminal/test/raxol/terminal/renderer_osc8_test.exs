defmodule Raxol.Terminal.RendererOSC8Test do
  @moduledoc """
  OSC 8 hyperlink emission in the live terminal render path.

  A cell whose style carries `:hyperlink` is wrapped in an OSC 8 open/close
  pair so the text is cmd-clickable in OSC 8-aware terminals. Cells without a
  hyperlink render exactly as before.
  """
  use ExUnit.Case, async: true
  alias Raxol.Terminal.{AdvancedFeatures, Renderer, ScreenBuffer}

  # OSC 8 bare form: ESC ] 8 ; ; URL ST  ...  ESC ] 8 ; ; ST  (ST = ESC \)
  defp osc8_open(url), do: "\e]8;;" <> url <> "\e\\"
  @osc8_close "\e]8;;\e\\"

  defp linked_buffer(url) do
    ScreenBuffer.new(4, 1)
    |> ScreenBuffer.write_char(0, 0, "g", %{hyperlink: url})
    |> ScreenBuffer.write_char(1, 0, "o", %{hyperlink: url})
  end

  defp rendered_cell(content, url) do
    buffer = ScreenBuffer.new(1, 1)
    [[cell]] = buffer.cells
    buffer = %{buffer | cells: [[%{cell | char: content, style: %{hyperlink: url}}]]}
    buffer |> Renderer.new() |> Renderer.render()
  end

  defp count(haystack, needle),
    do: haystack |> String.split(needle) |> length() |> Kernel.-(1)

  describe "individual rendering (default)" do
    test "wraps linked cells in OSC 8 open/close" do
      url = "https://basescan.org/tx/0xabc"
      renderer = Renderer.new(linked_buffer(url))

      output = Renderer.render(renderer)

      assert String.contains?(output, osc8_open(url))
      assert String.contains?(output, @osc8_close)
    end

    test "no OSC 8 for cells without a hyperlink" do
      buffer = ScreenBuffer.new(4, 1) |> ScreenBuffer.write_char(0, 0, "x")
      output = Renderer.render(Renderer.new(buffer))

      refute String.contains?(output, "\e]8")
    end
  end

  describe "batched rendering" do
    test "wraps a run of same-style linked cells once" do
      url = "https://example.com/tx"
      renderer = Renderer.new(linked_buffer(url), %{}, %{}, true)

      output = Renderer.render(renderer)

      assert String.contains?(output, osc8_open(url))
      assert String.contains?(output, @osc8_close)
    end
  end

  describe "coalescing a contiguous run into one OSC 8 pair" do
    test "individual mode wraps a multi-cell run once, not per glyph" do
      url = "https://raxol.io"
      output = Renderer.render(Renderer.new(linked_buffer(url)))

      assert count(output, osc8_open(url)) == 1
      assert count(output, @osc8_close) == 1
    end

    test "one OSC 8 pair spans a run even when SGR styling varies within it" do
      url = "https://raxol.io"

      buffer =
        ScreenBuffer.new(4, 1)
        |> ScreenBuffer.write_char(0, 0, "g", %{hyperlink: url, foreground: :red})
        |> ScreenBuffer.write_char(1, 0, "o", %{hyperlink: url, foreground: :blue})

      output =
        Renderer.render(Renderer.new(buffer, %{foreground: %{red: "#F00", blue: "#00F"}}))

      # single hyperlink wrap...
      assert count(output, osc8_open(url)) == 1
      assert count(output, @osc8_close) == 1
      # ...but two distinct SGR colors inside it
      assert String.contains?(output, "g")
      assert String.contains?(output, "o")
    end

    test "adjacent runs with different URLs get separate pairs" do
      a = "https://a.example"
      b = "https://b.example"

      buffer =
        ScreenBuffer.new(4, 1)
        |> ScreenBuffer.write_char(0, 0, "a", %{hyperlink: a})
        |> ScreenBuffer.write_char(1, 0, "b", %{hyperlink: b})

      output = Renderer.render(Renderer.new(buffer))

      assert count(output, osc8_open(a)) == 1
      assert count(output, osc8_open(b)) == 1
      assert count(output, @osc8_close) == 2
    end
  end

  describe "the emitted URL is confined at this sink" do
    defp rendered(url), do: url |> linked_buffer() |> Renderer.new() |> Renderer.render()

    # `style.hyperlink` is populated by `TextFormatting.set_hyperlink/2`
    # straight from an OSC 8 sequence this emulator parsed out of untrusted
    # program output, and re-emitted verbatim it escapes our own sequence:
    # the ESC below closes this OSC 8 and opens an OSC 52 clipboard write.
    # Asserted as an ESC COUNT against a clean render, because a correct
    # OSC 8 emission is itself made of ESCs.
    test "a URL cannot smuggle an escape sequence into the OSC 8 open" do
      out = rendered("http://x\e]52;c;cHduZWQ=\a")

      assert String.contains?(out, osc8_open("http://x"))
      assert count(out, "\e") == count(rendered("http://x"), "\e")
    end

    # An OSC body only ends at BEL or ST, so a URL parsed out of real input
    # can carry CR, BS, DEL and a raw 8-bit CSI (0x9B) with no ESC at all.
    test "no control byte of any class survives into the emitted URL" do
      for {name, byte} <- [
            {"BEL", "\a"},
            {"CR", "\r"},
            {"LF", "\n"},
            {"TAB", "\t"},
            {"BS", "\b"},
            {"DEL", <<0x7F>>},
            {"raw 8-bit CSI", <<0x9B>>},
            {"C1 CSI (U+009B)", "\u009B"}
          ] do
        out = rendered("http://ok" <> byte <> "tail")

        assert out == rendered("http://oktail"), "#{name}: #{inspect(out)}"

        refute String.contains?(out, byte),
               "#{name} survived into the emitted URL: #{inspect(out)}"
      end
    end

    test "a URL that is entirely control bytes emits no hyperlink at all" do
      refute String.contains?(rendered("\e[2J\r" <> <<0x7F>>), "\e]8")
    end
  end

  describe "display text confinement" do
    test "text is sanitized before framework SGR and OSC 8 are assembled" do
      output =
        rendered_cell(
          "safe\e[2J\e]52;c;payload\a\r\n\t tail",
          "https://example.com"
        )

      assert output == osc8_open("https://example.com") <> "safe tail" <> @osc8_close
      refute output =~ "\e]52"
      refute output =~ "\e[2J"
    end

    test "non-binary cell content fails closed" do
      refute rendered_cell(%{unsafe: "\e]52;c;payload\a"}, "https://example.com") =~
               "\e]8"
    end
  end

  describe "direct OSC emitters" do
    test "advanced hyperlinks sanitize text, URL, and params" do
      output =
        AdvancedFeatures.create_hyperlink(
          "label\e]52;c;text\a",
          "https://example.com\e]52;c;url\a",
          %{
            id: "link\e]52;c;id\a",
            tooltip: "tip\e]52;c;tip\a",
            params: %{"key\e]52;c;key\a" => "value\e]52;c;value\a"}
          }
        )

      assert output =~ "label"
      assert output =~ "https://example.com"
      refute output =~ "\e]52"
      refute output =~ "\a"
    end

    test "advanced emitters fail closed for non-binary terminal fields" do
      assert AdvancedFeatures.create_hyperlink("label", %{unsafe: true}) == "label"

      refute AdvancedFeatures.create_hyperlink(%{unsafe: true}, "https://example.com") =~
               "%{"

      assert AdvancedFeatures.notify(%{unsafe: true}) == "\e]9;\e\\"
      assert AdvancedFeatures.set_pointer_shape(%{unsafe: true}) == "\e]22;\e\\"
    end

    test "other OSC payload emitters cannot open OSC 52" do
      notification = AdvancedFeatures.notify("done\e]52;c;payload\a tail")
      pointer = AdvancedFeatures.set_pointer_shape("text\e]52;c;payload\a")

      title =
        ExUnit.CaptureIO.capture_io(fn ->
          assert AdvancedFeatures.set_window_title("title\e]52;c;payload\a tail") == :ok
        end)

      for output <- [notification, pointer, title] do
        refute output =~ "\e]52"
        refute output =~ "\a"
      end
    end
  end
end
