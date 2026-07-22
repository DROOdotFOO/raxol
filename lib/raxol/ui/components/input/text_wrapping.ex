defmodule Raxol.UI.Components.Input.TextWrapping do
  @moduledoc """
  Utility functions for text wrapping.

  `width` is always a DISPLAY-COLUMN budget, never a grapheme count. These
  two are equal only for ASCII: a CJK ideograph or emoji is one grapheme and
  two columns, so counting graphemes against a column budget overflows the
  line by up to 2x. Measurement goes through `Raxol.UI.TextMeasure`, the
  repo-wide facade (see its "three units" note).
  """

  alias Raxol.UI.TextMeasure

  @doc """
  Wraps a single line of text to a display-column budget.

  Chunks are cut on grapheme-cluster boundaries and never exceed `width`
  display columns. A cluster wider than the whole budget is emitted alone on
  its own line rather than being split in half.
  """
  def wrap_line_by_char(line, width)
      when is_binary(line) and is_integer(width) and width > 0 do
    do_wrap_char(line, width, [])
  end

  defp do_wrap_char("", _width, []), do: [""]

  defp do_wrap_char("", _width, acc), do: Enum.reverse(acc)

  defp do_wrap_char(text, width, acc) do
    {chunk, rest} = take_columns(text, width)
    do_wrap_char(rest, width, [chunk | acc])
  end

  # `split_at_display_width/2` cuts on cluster boundaries, so a 2-column
  # cluster does not fit in a 1-column budget and comes back as `{"", text}`.
  # Taking one whole cluster in that case is what keeps this terminating --
  # and overflowing by one column beats looping forever or halving a glyph.
  defp take_columns(text, width) do
    case TextMeasure.split_at_display_width(text, width) do
      {"", rest} when rest != "" -> String.next_grapheme(text)
      {chunk, rest} -> {chunk, rest}
    end
  end

  @doc """
  Wraps a single line of text by word boundaries.
  """
  def wrap_line_by_word(line, width)
      when is_binary(line) and is_integer(width) and width > 0 do
    words = String.split(line, " ")
    do_wrap_words(words, width, [], "")
  end

  # Private helper for wrap_line_by_word
  defp do_wrap_words([], _width, lines, ""), do: Enum.reverse(lines)

  defp do_wrap_words([], _width, lines, current_line) do
    Enum.reverse([String.trim(current_line) | lines])
  end

  defp do_wrap_words([word | rest], width, lines, current_line) do
    new_line = build_new_line(current_line, word)

    case categorize_word_fit(word, new_line, width) do
      :word_too_long ->
        handle_long_word(word, rest, width, lines, current_line)

      :fits_current_line ->
        # Word fits on the current line
        do_wrap_words(rest, width, lines, new_line)

      :needs_new_line ->
        # Word doesn't fit, start a new line
        do_wrap_words(
          rest,
          width,
          [String.trim(current_line) | lines],
          word
        )
    end
  end

  defp categorize_word_fit(word, new_line, width) do
    word_length = TextMeasure.display_width(word)
    new_line_length = TextMeasure.display_width(new_line)

    case {word_length > width, new_line_length <= width} do
      {true, _} -> :word_too_long
      {false, true} -> :fits_current_line
      {false, false} -> :needs_new_line
    end
  end

  defp build_new_line("", word), do: word
  defp build_new_line(current_line, word), do: current_line <> " " <> word

  defp handle_long_word(word, rest, width, lines, current_line) do
    # 1. Finalize the current line (if it's not empty) and add it to lines.
    finalized_lines = finalize_current_line(current_line, lines)

    # 2. Wrap the long word by character.
    wrapped_word_parts = wrap_line_by_char(word, width)

    # 3. The last part of the wrapped word becomes the start of the *next* current_line.
    #    The preceding parts are added to the accumulated lines (in reverse order for prepending).
    case Enum.reverse(wrapped_word_parts) do
      [] ->
        # This case should only happen if wrap_line_by_char gets an empty string or width <= 0,
        # which is guarded against, but handle defensively.
        do_wrap_words(rest, width, finalized_lines, "")

      [last_part | initial_parts_rev] ->
        # Prepend already reversed initial parts
        updated_lines = initial_parts_rev ++ finalized_lines

        # 4. Recurse with the rest of the words, using the last part of the wrapped word
        #    as the new current line, and the updated lines accumulator.
        do_wrap_words(rest, width, updated_lines, last_part)
    end
  end

  defp finalize_current_line("", lines), do: lines

  defp finalize_current_line(current_line, lines) do
    [String.trim(current_line) | lines]
  end

  # do_wrap_words end
end

# Module end
