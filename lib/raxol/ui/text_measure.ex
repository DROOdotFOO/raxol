defmodule Raxol.UI.TextMeasure do
  @moduledoc """
  Single source of truth for text display width measurement, and for
  converting between the three units text is counted in.

  Delegates to CharacterHandling in raxol_terminal when available,
  falls back to String.length for environments without the terminal package.

  All layout, rendering, and text wrapping code should use this module
  instead of String.length for display-width-sensitive calculations.

  ## The three units

  A string has three different lengths, and they are equal only for pure
  ASCII. Mixing them is a recurring defect in this codebase, so the
  conversions live here rather than being re-derived at each call site:

  | Question                        | Unit           | Function                    |
  | ------------------------------- | -------------- | --------------------------- |
  | How wide on screen?             | display cells  | `display_width/1`           |
  | Where did the regex match?      | **bytes**      | `slice_bytes/2`             |
  | What screen column is that at?  | display cells  | `byte_offset_to_column/2`   |
  | What character index is that?   | graphemes      | `byte_offset_to_index/2`    |

  Erlang's `:re` (so `Regex.run/scan` with `return: :index`, and
  `:binary.match/2`) reports **byte** offsets. `String.slice/3`,
  `String.length/1` and `String.at/2` count **graphemes**. Feeding the
  former into the latter silently cuts mid-character on any input with a
  multi-byte character earlier in the string -- an em dash, an accent, CJK,
  an emoji. The result is not a crash: it is a span that loses its leading
  characters, keeps its markup, and colours from the wrong offset.

  So: never hand a regex offset to a `String.*` function. Use
  `slice_bytes/2` to cut at it, or one of the `byte_offset_to_*` functions
  to convert it into the unit you actually want.
  """

  @compile {:no_warn_undefined, Raxol.Terminal.CharacterHandling}

  @doc """
  Returns the display width of a string in terminal columns.

  CJK characters, fullwidth symbols, and emoji count as 2 columns.
  Combining characters count as 0 columns.
  All other characters count as 1 column.

  Delegates to CharacterHandling (raxol_terminal) for correct Unicode
  width calculation. Falls back to String.length if unavailable.
  """
  @spec display_width(String.t()) :: non_neg_integer()
  def display_width(text) when is_binary(text) do
    if Code.ensure_loaded?(Raxol.Terminal.CharacterHandling) do
      Raxol.Terminal.CharacterHandling.get_string_width(text)
    else
      String.length(text)
    end
  end

  @doc """
  Returns the display width of a single grapheme (1 or 2 columns).
  """
  @spec char_display_width(String.t()) :: 1 | 2
  def char_display_width(char) when is_binary(char) do
    if Code.ensure_loaded?(Raxol.Terminal.CharacterHandling) do
      Raxol.Terminal.CharacterHandling.get_char_width(char)
    else
      1
    end
  end

  @doc """
  Splits a string at a given display width boundary.

  Returns `{left, right}` where `left` fits within `width` display columns.
  Will not split a double-width character in half.
  """
  @spec split_at_display_width(String.t(), non_neg_integer()) ::
          {String.t(), String.t()}
  def split_at_display_width(text, width)
      when is_binary(text) and is_integer(width) do
    if Code.ensure_loaded?(Raxol.Terminal.CharacterHandling) do
      Raxol.Terminal.CharacterHandling.split_at_width(text, width)
    else
      {String.slice(text, 0, width), String.slice(text, width..-1//1)}
    end
  end

  @doc """
  Cuts the byte range `{start, length}` out of `text`.

  This is the correct way to consume an offset from `Regex.run/scan` with
  `return: :index` or from `:binary.match/2` -- both report bytes.

  Out-of-range offsets clamp to the string rather than raising, so a stale
  or mis-derived offset degrades to a short slice instead of crashing a
  render. A non-participating regex capture group (`{-1, 0}`) yields `""`.
  """
  @spec slice_bytes(String.t(), {integer(), integer()}) :: String.t()
  def slice_bytes(text, {start, length}) when is_binary(text) do
    size = byte_size(text)
    from = start |> max(0) |> min(size)
    len = length |> max(0) |> min(size - from)

    binary_part(text, from, len)
  end

  @doc """
  Converts a BYTE offset into the display column it sits at -- that is, the
  display width of everything before it.

  Use this when a regex offset has to become a cursor position or a
  highlight span, since those are measured in screen columns, not bytes.
  """
  @spec byte_offset_to_column(String.t(), integer()) :: non_neg_integer()
  def byte_offset_to_column(text, byte_offset) when is_binary(text) do
    text
    |> slice_bytes({0, byte_offset})
    |> display_width()
  end

  @doc """
  Converts a BYTE offset into a grapheme index, for the rarer case where a
  call site genuinely wants a character count (e.g. handing an index back
  to a `String.*` function).

  Prefer `byte_offset_to_column/2` for anything that will be rendered: two
  graphemes and two columns are not the same thing the moment CJK or emoji
  appear.
  """
  @spec byte_offset_to_index(String.t(), integer()) :: non_neg_integer()
  def byte_offset_to_index(text, byte_offset) when is_binary(text) do
    text
    |> slice_bytes({0, byte_offset})
    |> String.length()
  end
end
