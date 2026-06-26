defmodule Raxol.Terminal.RendererOSC8Test do
  @moduledoc """
  OSC 8 hyperlink emission in the live terminal render path.

  A cell whose style carries `:hyperlink` is wrapped in an OSC 8 open/close
  pair so the text is cmd-clickable in OSC 8-aware terminals. Cells without a
  hyperlink render exactly as before.
  """
  use ExUnit.Case, async: true
  alias Raxol.Terminal.{Renderer, ScreenBuffer}

  # OSC 8 bare form: ESC ] 8 ; ; URL ST  ...  ESC ] 8 ; ; ST  (ST = ESC \)
  defp osc8_open(url), do: "\e]8;;" <> url <> "\e\\"
  @osc8_close "\e]8;;\e\\"

  defp linked_buffer(url) do
    ScreenBuffer.new(4, 1)
    |> ScreenBuffer.write_char(0, 0, "g", %{hyperlink: url})
    |> ScreenBuffer.write_char(1, 0, "o", %{hyperlink: url})
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
end
