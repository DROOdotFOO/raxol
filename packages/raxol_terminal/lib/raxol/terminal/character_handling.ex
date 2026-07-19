defmodule Raxol.Terminal.CharacterHandling do
  @moduledoc """
  Handles wide character and bidirectional text support for the terminal emulator.

  This module provides functions for:
  - Determining character width (single, double, or variable width)
  - Handling bidirectional text rendering
  - Managing character combining
  - Supporting Unicode character properties
  """

  # Codepoints with Unicode's Emoji_Presentation=Yes that fall BELOW the
  # {0x1F300, 0x1FAFF} block -- the pre-Unicode-6 pictographs, plus the
  # enclosed alphanumerics and regional indicators. Terminals draw these two
  # columns wide, but the block-shaped ranges above all start at 0x1F300, so
  # every one of them measured 1 and silently overflowed its container.
  #
  # This is deliberately NOT "all of U+2600..27BF": that block mixes
  # emoji-presentation characters (2 columns: U+2705 ✅, U+274C ❌) with
  # text-presentation ones (1 column: U+2713 ✓, U+2600 ☀ bare). Widening the
  # whole block would fix the first group by breaking the second. Only
  # Emoji_Presentation=Yes subranges are listed.
  #
  # Maintaining this by hand is the same fragile pattern that hid the flag
  # bug; a future pass should derive it from Unicode data instead.
  @emoji_presentation_ranges [
    # Watch, hourglass
    {0x231A, 0x231B},
    # Fast-forward / rewind, alarm clock, hourglass flowing
    {0x23E9, 0x23EC},
    {0x23F0, 0x23F0},
    {0x23F3, 0x23F3},
    # Small squares
    {0x25FD, 0x25FE},
    # Umbrella with rain, hot beverage
    {0x2614, 0x2615},
    # Zodiac
    {0x2648, 0x2653},
    # Wheelchair, anchor, high voltage
    {0x267F, 0x267F},
    {0x2693, 0x2693},
    {0x26A1, 0x26A1},
    # Circles
    {0x26AA, 0x26AB},
    # Sports
    {0x26BD, 0x26BE},
    {0x26C4, 0x26C5},
    {0x26CE, 0x26CE},
    # No entry, church, fountain, tent, fuel pump
    {0x26D4, 0x26D4},
    {0x26EA, 0x26EA},
    {0x26F2, 0x26F3},
    {0x26F5, 0x26F5},
    {0x26FA, 0x26FA},
    {0x26FD, 0x26FD},
    # Check mark button, raised fist / hand
    {0x2705, 0x2705},
    {0x270A, 0x270B},
    # Sparkles, cross mark, cross mark button
    {0x2728, 0x2728},
    {0x274C, 0x274C},
    {0x274E, 0x274E},
    # Question / exclamation marks
    {0x2753, 0x2755},
    {0x2757, 0x2757},
    # Heavy plus / minus / division
    {0x2795, 0x2797},
    # Curly loops
    {0x27B0, 0x27B0},
    {0x27BF, 0x27BF},
    # Large squares, star, circle
    {0x2B1B, 0x2B1C},
    {0x2B50, 0x2B50},
    {0x2B55, 0x2B55},
    # Mahjong red dragon, playing card black joker
    {0x1F004, 0x1F004},
    {0x1F0CF, 0x1F0CF},
    # Enclosed alphanumerics (negative squared letters, CJK ideographs)
    {0x1F18E, 0x1F18E},
    {0x1F191, 0x1F19A},
    {0x1F201, 0x1F201},
    {0x1F21A, 0x1F21A},
    {0x1F22F, 0x1F22F},
    {0x1F232, 0x1F236},
    {0x1F238, 0x1F23A},
    {0x1F250, 0x1F251}
    # Regional indicators are deliberately ABSENT: a lone one is a narrow
    # letter tile, and a PAIR is a flag recognised as a grapheme in
    # `get_char_width/1`.
  ]

  @doc """
  Determines if a character is a wide character (takes up two cells).
  """
  @spec wide_char?(char()) :: boolean()
  def wide_char?(char) do
    wide_ranges =
      [
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
        # CJK Symbols and Punctuation (ideographic space, 、。「」...)
        {0x3000, 0x303E},
        # Hiragana + Katakana (incl. the ー prolonged sound mark). Kana are
        # East Asian Wide just like Han -- this range was missing, so kana
        # measured 1 cell and every downstream layout budget drifted
        # (caught by the harness diff viewer's unicode fixture).
        {0x3041, 0x30FF},
        # Katakana Phonetic Extensions
        {0x31F0, 0x31FF},
        # Hangul Syllables
        {0xAC00, 0xD7AF},
        # Fullwidth ASCII variants
        {0xFF01, 0xFF60},
        # Fullwidth symbols
        {0xFFE0, 0xFFE6},
        # Miscellaneous Symbols and Pictographs. Everything emoji-presentation
        # BELOW this block lives in @emoji_presentation_ranges instead.
        {0x1F300, 0x1FAFF}
      ] ++ @emoji_presentation_ranges

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
      # Variation Selector-16 forces EMOJI presentation on a base character
      # that defaults to text presentation, and emoji presentation is two
      # columns. This is why `❤` (U+2665, correctly 1) and `❤️` (the same
      # base plus VS16, 2) must not measure the same -- ignoring the
      # selector made every VS16 sequence, including keycaps like `1️⃣`,
      # measure one column short. Checked before the first-codepoint
      # lookup because the base codepoint alone cannot answer this.
      codepoints when is_list(codepoints) and codepoints != [] ->
        emoji_presentation_width(codepoints)

      [] ->
        1
    end
  end

  # A flag is a PAIR of regional indicators (U+1F1E6..U+1F1FF) that Unicode
  # groups into one grapheme and terminals draw two columns wide. The pair
  # sits below the {0x1F300, 0x1FAFF} emoji range, so falling through to the
  # first-codepoint lookup measured a flag as ONE column: every line
  # containing one overflowed its container, pushing the frame border out.
  #
  # A LONE regional indicator is deliberately still 1 -- on its own it
  # renders as a narrow letter tile, not a flag.
  defp emoji_presentation_width([a, b | _] = codepoints) do
    cond do
      regional_indicator?(a) and regional_indicator?(b) -> 2
      variation_selector_16?(codepoints) -> 2
      true -> get_char_width(a)
    end
  end

  defp emoji_presentation_width([cp | _]), do: get_char_width(cp)

  defp variation_selector_16?(codepoints), do: 0xFE0F in codepoints

  defp regional_indicator?(cp), do: cp >= 0x1F1E6 and cp <= 0x1F1FF

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
    do_split_at_width(string, width)
  end

  # Walks GRAPHEMES, not codepoints. Splitting per codepoint cut clusters in
  # half: a flag became two lone regional indicators, a ZWJ family left a
  # dangling joiner at the head of the right side, a combining mark was
  # orphaned from its base, and VS16 was stripped from its base -- which
  # silently changed the left side's width from 2 to 1, so the two halves no
  # longer summed to the original and the caller's layout budget drifted.
  #
  # Width is a property of the cluster (see `get_char_width/1`'s binary
  # clause), so it can only be spent one cluster at a time.
  defp do_split_at_width(text, width) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({"", "", 0}, fn grapheme, {left, _right, used} ->
      grapheme_width = get_char_width(grapheme)

      case used + grapheme_width <= width do
        true -> {:cont, {left <> grapheme, "", used + grapheme_width}}
        false -> {:halt, {left, :rest, used}}
      end
    end)
    |> case do
      {left, :rest, _used} ->
        {left, binary_part(text, byte_size(left), byte_size(text) - byte_size(left))}

      {left, _right, _used} ->
        {left, ""}
    end
  end
end
