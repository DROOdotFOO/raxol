defmodule Raxol.Terminal.CharacterHandling do
  @moduledoc """
  Handles wide character and bidirectional text support for the terminal emulator.

  This module provides functions for:
  - Determining character width (single, double, or variable width)
  - Handling bidirectional text rendering
  - Managing character combining
  - Supporting Unicode character properties
  """


  @doc """
  Determines if a character is a wide character (takes up two cells).
  """
  @spec wide_char?(char()) :: boolean()
  def wide_char?(char) do
    wide_ranges = [
      # CJK Unified Ideographs
      {0x4E00, 0x9FFF},
      # CJK Unified Ideographs Extension A
      {0x3400, 0x4DBF},
      # CJK Unified Ideographs Extension B
      {0x20000, 0x2A6DF},
      # CJK Unified Ideographs Extension C
      {0x2A700, 0x2B73F},
      # CJK Unified Ideographs Extension D
      {0x2B740, 0x2B81F},
      # CJK Unified Ideographs Extension E
      {0x2B820, 0x2CEAF},
      # CJK Unified Ideographs Extension F
      {0x2CEB0, 0x2EBEF},
      # CJK Unified Ideographs Extension G
      {0x30000, 0x3134F},
      # CJK Compatibility Ideographs
      {0xF900, 0xFAFF},
      # Hangul Syllables
      {0xAC00, 0xD7AF},
      # Fullwidth ASCII variants
      {0xFF01, 0xFF60},
      # Fullwidth symbols
      {0xFFE0, 0xFFE6},
      # Miscellaneous Symbols and Pictographs
      {0x1F300, 0x1FAFF}
    ]

    Enum.any?(wide_ranges, fn {start, finish} ->
      char >= start and char <= finish
    end)
  end

  @doc """
  Determine the display width of a given character code point or string.
  """
  @spec get_char_width(codepoint :: integer() | String.t()) :: 1 | 2
  def get_char_width(codepoint) when is_integer(codepoint) do
    case wide_char?(codepoint) do
      true -> 2
      false -> 1
    end
  end

  def get_char_width(str) when is_binary(str) do
    case String.to_charlist(str) do
      [cp | _] -> get_char_width(cp)
      [] -> 1
    end
  end

  @doc """
  Determines if a character is a combining character.
  """
  @spec combining_char?(char()) :: boolean()
  def combining_char?(char) do
    combining_ranges = [
      # Combining Diacritical Marks
      {0x0300, 0x036F},
      # Combining Diacritical Marks Extended
      {0x1AB0, 0x1AFF},
      # Combining Diacritical Marks Supplement
      {0x1DC0, 0x1DFF},
      # Combining Diacritical Marks for Symbols
      {0x20D0, 0x20FF},
      # Combining Half Marks
      {0xFE20, 0xFE2F}
    ]

    Enum.any?(combining_ranges, fn {start, finish} ->
      char >= start and char <= finish
    end)
  end

  @doc """
  Determines the bidirectional character type.
  Returns :LTR, :RTL, :NEUTRAL, or :COMBINING.
  """
  @dialyzer {:nowarn_function, get_bidi_type: 1}
  def get_bidi_type(char) do
    bidi_checks = [
      {&combining_char?/1, :COMBINING},
      {fn c -> char_in_ranges(c, rtl_ranges()) end, :RTL},
      {fn c -> char_in_ranges(c, ltr_ranges()) end, :LTR}
    ]

    Enum.find_value(bidi_checks, :NEUTRAL, fn {check, type} ->
      case check.(char) do
        true -> type
        false -> nil
      end
    end)
  end

  defp rtl_ranges do
    [
      # Hebrew
      {0x0590, 0x05FF},
      # Arabic
      {0x0600, 0x06FF},
      # Arabic Supplement
      {0x0750, 0x077F},
      # Arabic Extended-A
      {0x08A0, 0x08FF},
      # Arabic Presentation Forms-A
      {0xFB50, 0xFDFF},
      # Arabic Presentation Forms-B
      {0xFE70, 0xFEFF},
      # Unicode control characters for RTL
      # Right-to-Left Override (RLO)
      {0x202E, 0x202E},
      # Left-to-Right Override (LRO)
      {0x202D, 0x202D},
      # Right-to-Left Embedding (RLE)
      {0x202B, 0x202B},
      # Left-to-Right Embedding (LRE)
      {0x202A, 0x202A}
    ]
  end

  defp ltr_ranges do
    [
      # Basic Latin Uppercase
      {0x0041, 0x005A},
      # Basic Latin Lowercase
      {0x0061, 0x007A},
      # Latin-1 Supplement
      {0x00C0, 0x00FF},
      # Latin Extended-A & B
      {0x0100, 0x024F},
      # Digits
      {0x0030, 0x0039},
      # Space
      {0x0020, 0x0020}
    ]
  end

  defp char_in_ranges(char, ranges) do
    Enum.any?(ranges, fn {start, finish} -> char >= start and char <= finish end)
  end

  @doc """
  Processes a string for bidirectional text rendering.
  Returns a list of segments with their rendering order.
  """
  @spec process_bidi_text(String.t()) ::
          list({:LTR | :RTL | :NEUTRAL, String.t()})
  @dialyzer {:nowarn_function, process_bidi_text: 1}
  def process_bidi_text(nil), do: []
  def process_bidi_text(""), do: []

  def process_bidi_text(string) when is_binary(string) do
    string
    |> String.to_charlist()
    |> Enum.reduce([], &handle_bidi_segment/2)
    |> Enum.reverse()
  end

  defp handle_bidi_segment(char, acc) do
    bidi_type = get_bidi_type(char)
    char_str = <<char::utf8>>

    case acc do
      [] ->
        [{bidi_type, char_str}]

      [{prev_type, prev_str} | rest] ->
        case prev_type == bidi_type do
          true -> [{prev_type, prev_str <> char_str} | rest]
          false -> [{bidi_type, char_str}, {prev_type, prev_str} | rest]
        end
    end
  end

  @doc """
  Gets the effective width of a string, taking into account wide characters
  and ignoring combining characters.
  """
  @spec get_string_width(String.t()) :: non_neg_integer()
  def get_string_width(string) do
    string
    |> String.graphemes()
    |> Enum.map(&get_char_width/1)
    |> Enum.sum()
  end

  @doc """
  Splits a string at a given width, respecting wide characters.
  """
  @spec split_at_width(String.t(), non_neg_integer()) ::
          {String.t(), String.t()}
  def split_at_width(string, width) do
    {before_text, remaining} = do_split_at_width(string, width, 0, "")
    {before_text, remaining}
  end

  defp do_split_at_width("", _width, _current_width, acc) do
    {acc, ""}
  end

  defp do_split_at_width(
         <<char::utf8, rest::binary>>,
         width,
         current_width,
         acc
       ) do
    char_width = get_char_width(char)

    case current_width + char_width <= width do
      true ->
        do_split_at_width(
          rest,
          width,
          current_width + char_width,
          acc <> <<char::utf8>>
        )

      false ->
        {acc, <<char::utf8, rest::binary>>}
    end
  end
end
