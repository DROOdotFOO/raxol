defmodule Raxol.Core.Renderer.View.Components.Text do
  @moduledoc """
  Handles text rendering for the Raxol view system.
  Provides text styling, wrapping, and alignment functionality.
  """

  @doc """
  Creates a new text view.

  ## Options
    * `:fg` - Foreground color
    * `:bg` - Background color
    * `:style` - List of style atoms (e.g., [:bold, :underline])
    * `:align` - Text alignment (:left, :center, :right)
    * `:wrap` - Text wrapping mode (:none, :char, :word)
    * `:link` - OSC 8 hyperlink URL; makes the text cmd-clickable in
      terminals that support OSC 8 (iTerm2, kitty, WezTerm, ...)

  ## Examples

      Text.new("Hello, World!", fg: :red, style: [:bold])
      Text.new("Centered text", align: :center)
      Text.new("0x7f3a..e21", link: "https://basescan.org/tx/0x7f3a..e21")
  """
  def new(content, opts \\ []) when is_binary(content) do
    %{
      type: :text,
      content: content,
      size: Keyword.get(opts, :size, {1, 1}),
      fg: Keyword.get(opts, :fg),
      bg: Keyword.get(opts, :bg),
      style: Keyword.get(opts, :style, []),
      align: Keyword.get(opts, :align, :left),
      wrap: Keyword.get(opts, :wrap, :none),
      link: Keyword.get(opts, :link)
    }
  end

  @doc """
  Renders text with the given options and width.
  """
  def render(text, width) do
    text.content
    |> wrap_text(width, text.wrap)
    |> align_text(width, text.align)
    |> apply_styles(text.style)
  end

  defp wrap_text(text, _width, :none), do: [text]
  defp wrap_text(text, width, :char), do: wrap_by_char(text, width)
  defp wrap_text(text, width, :word), do: wrap_by_word(text, width)

  defp wrap_by_char(text, width) do
    text
    |> String.graphemes()
    |> Enum.chunk_every(width)
    |> Enum.map(&Enum.join/1)
  end

  defp wrap_by_word(text, width) do
    text
    |> String.split(" ")
    |> Enum.reduce({[], ""}, &process_word(&1, &2, width))
    |> finalize_word_wrap()
  end

  defp finalize_word_wrap({lines, ""}), do: Enum.reverse(lines)

  defp finalize_word_wrap({lines, last_line}),
    do: Enum.reverse([last_line | lines])

  defp process_word(word, {lines, current_line}, width) do
    case Raxol.UI.TextMeasure.display_width(current_line) +
           Raxol.UI.TextMeasure.display_width(word) + 1 <= width do
      true ->
        new_line = build_line(current_line, word)
        {lines, new_line}

      false ->
        {[current_line | lines], word}
    end
  end

  defp build_line("", word), do: word
  defp build_line(current_line, word), do: current_line <> " " <> word

  defp align_text(lines, _width, :left), do: lines

  defp align_text(lines, width, :right),
    do: Enum.map(lines, &String.pad_leading(&1, width))

  defp align_text(lines, width, :center),
    do:
      Enum.map(
        lines,
        &String.pad_leading(
          &1,
          div(width + Raxol.UI.TextMeasure.display_width(&1), 2)
        )
      )

  defp apply_styles(lines, styles) do
    Enum.map(lines, fn line ->
      Enum.reduce(styles, line, fn style, acc ->
        apply_style(acc, style)
      end)
    end)
  end

  defp apply_style(text, :bold), do: "\e[1m#{text}\e[0m"
  defp apply_style(text, :underline), do: "\e[4m#{text}\e[0m"
  defp apply_style(text, :italic), do: "\e[3m#{text}\e[0m"
  defp apply_style(text, :strikethrough), do: "\e[9m#{text}\e[0m"
  defp apply_style(text, _), do: text
end
