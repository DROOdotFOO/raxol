defmodule Raxol.Terminal.ANSI.CharacterTranslations do
  @moduledoc """
  Provides character translation tables for different character sets.
  Maps characters between different character sets according to ANSI standards.
  """

  # US ASCII character set (G0)
  @us_ascii_map %{
                  # Control characters (0x00-0x1F) are not translated
                  # Printable ASCII (0x20-0x7E) are not translated
                  # DEL (0x7F) is not translated
                }

  # UK character set (G1)
  @uk_map %{
    # # -> £
    0x23 => 0xA3,
    # @ -> £
    0x40 => 0xA3,
    # [ -> £
    0x5B => 0xA3,
    # \ -> £
    0x5C => 0xA3,
    # ] -> £
    0x5D => 0xA3,
    # { -> £
    0x7B => 0xA3,
    # | -> £
    0x7C => 0xA3,
    # } -> £
    0x7D => 0xA3,
    # ~ -> £
    0x7E => 0xA3
  }

  # French character set (G1)
  @french_map %{
    # # -> £
    0x23 => 0xA3,
    # @ -> à
    0x40 => 0xE0,
    # [ -> °
    0x5B => 0xB0,
    # \ -> ç
    0x5C => 0xE7,
    # ] -> §
    0x5D => 0xA7,
    # { -> é
    0x7B => 0xE9,
    # | -> ù
    0x7C => 0xF9,
    # } -> è
    0x7D => 0xE8,
    # ~ -> ù
    0x7E => 0xF9
  }

  # German character set (G1)
  @german_map %{
    # # -> £
    0x23 => 0xA3,
    # @ -> §
    0x40 => 0xA7,
    # [ -> Ä
    0x5B => 0xC4,
    # \ -> Ö
    0x5C => 0xD6,
    # ] -> Ü
    0x5D => 0xDC,
    # { -> ä
    0x7B => 0xE4,
    # | -> ö
    0x7C => 0xF6,
    # } -> ü
    0x7D => 0xFC,
    # ~ -> ß
    0x7E => 0xDF
  }

  # Latin-1 character set (ISO-8859-1)
  @latin1_map %{
    # Add Latin-1 specific mappings
    # Euro sign
    0x80 => 0x20AC,
    # Control character
    0x81 => 0x0081,
    # Single low-9 quotation mark
    0x82 => 0x201A,
    # Latin small f with hook
    0x83 => 0x0192,
    # Double low-9 quotation mark
    0x84 => 0x201E,
    # Horizontal ellipsis
    0x85 => 0x2026,
    # Dagger
    0x86 => 0x2020,
    # Double dagger
    0x87 => 0x2021,
    # Modifier letter circumflex accent
    0x88 => 0x02C6,
    # Per mille sign
    0x89 => 0x2030,
    # Latin capital letter S with caron
    0x8A => 0x0160,
    # Single left-pointing angle quotation mark
    0x8B => 0x2039,
    # Latin capital ligature OE
    0x8C => 0x0152,
    # Control character
    0x8D => 0x008D,
    # Latin capital letter Z with caron
    0x8E => 0x017D,
    # Control character
    0x8F => 0x008F,
    # Control character
    0x90 => 0x0090,
    # Left single quotation mark
    0x91 => 0x2018,
    # Right single quotation mark
    0x92 => 0x2019,
    # Left double quotation mark
    0x93 => 0x201C,
    # Right double quotation mark
    0x94 => 0x201D,
    # Bullet
    0x95 => 0x2022,
    # En dash
    0x96 => 0x2013,
    # Em dash
    0x97 => 0x2014,
    # Small tilde
    0x98 => 0x02DC,
    # Trade mark sign
    0x99 => 0x2122,
    # Latin small letter s with caron
    0x9A => 0x0161,
    # Single right-pointing angle quotation mark
    0x9B => 0x203A,
    # Latin small ligature oe
    0x9C => 0x0153,
    # Control character
    0x9D => 0x009D,
    # Latin small letter z with caron
    0x9E => 0x017E,
    # Latin capital letter Y with diaeresis
    0x9F => 0x0178
  }

  # DEC Special Graphics Character Set
  @dec_special_graphics_map %{
    # _ -> Non-breaking space
    0x5F => 0xA0,
    # ` -> Diamond (◆)
    0x60 => 0x25C6,
    # a -> Checkerboard (▒)
    0x61 => 0x2592,
    # b -> HT symbol (HT)
    0x62 => 0x2409,
    # c -> FF symbol (FF)
    0x63 => 0x240C,
    # d -> CR symbol (CR)
    0x64 => 0x240D,
    # e -> LF symbol (LF)
    0x65 => 0x240A,
    # f -> Degree sign (°)
    0x66 => 0x00B0,
    # g -> Plus/minus sign (±)
    0x67 => 0x00B1,
    # h -> NL symbol (NL)
    0x68 => 0x2424,
    # i -> VT symbol (VT)
    0x69 => 0x240B,
    # j -> Lower right corner (┘)
    0x6A => 0x2518,
    # k -> Upper right corner (┐)
    0x6B => 0x2510,
    # l -> Upper left corner (┌)
    0x6C => 0x250C,
    # m -> Lower left corner (└)
    0x6D => 0x2514,
    # n -> Crossing lines (+) (┼)
    0x6E => 0x253C,
    # o -> Scan line 1 (⎺)
    0x6F => 0x23BA,
    # p -> Scan line 3 (⎻)
    0x70 => 0x23BB,
    # q -> Scan line 5 / Horizontal line (─)
    0x71 => 0x2500,
    # r -> Scan line 7 (⎼)
    0x72 => 0x23BC,
    # s -> Scan line 9 (⎽)
    0x73 => 0x23BD,
    # t -> Tee pointing right (├)
    0x74 => 0x251C,
    # u -> Tee pointing left (┤)
    0x75 => 0x2524,
    # v -> Tee pointing up (┴)
    0x76 => 0x2534,
    # w -> Tee pointing down (┬)
    0x77 => 0x252C,
    # x -> Vertical line (│)
    0x78 => 0x2502,
    # y -> Less than or equal to (≤)
    0x79 => 0x2264,
    # z -> Greater than or equal to (≥)
    0x7A => 0x2265,
    # { -> Pi (π)
    0x7B => 0x03C0,
    # | -> Not equal to (≠)
    0x7C => 0x2260,
    # } -> Pound sign (£)
    0x7D => 0x00A3,
    # ~ -> Centered dot (·)
    0x7E => 0x00B7
  }

  # DEC Technical Character Set
  @dec_technical_map %{
    # Add DEC Technical character set mappings
    # Degree sign
    0x60 => 0x00B0,
    # Plus-minus sign
    0x61 => 0x00B1,
    # Superscript two
    0x62 => 0x00B2,
    # Superscript three
    0x63 => 0x00B3,
    # Acute accent
    0x64 => 0x00B4,
    # Micro sign
    0x65 => 0x00B5,
    # Pilcrow sign
    0x66 => 0x00B6,
    # Middle dot
    0x67 => 0x00B7,
    # Cedilla
    0x68 => 0x00B8,
    # Superscript one
    0x69 => 0x00B9,
    # Masculine ordinal indicator
    0x6A => 0x00BA,
    # Right-pointing double angle quotation mark
    0x6B => 0x00BB,
    # Vulgar fraction one quarter
    0x6C => 0x00BC,
    # Vulgar fraction one half
    0x6D => 0x00BD,
    # Vulgar fraction three quarters
    0x6E => 0x00BE,
    # Inverted question mark
    0x6F => 0x00BF,
    # Latin capital letter A with grave
    0x70 => 0x00C0,
    # Latin capital letter A with acute
    0x71 => 0x00C1,
    # Latin capital letter A with circumflex
    0x72 => 0x00C2,
    # Latin capital letter A with tilde
    0x73 => 0x00C3,
    # Latin capital letter A with diaeresis
    0x74 => 0x00C4,
    # Latin capital letter A with ring above
    0x75 => 0x00C5,
    # Latin capital letter AE
    0x76 => 0x00C6,
    # Latin capital letter C with cedilla
    0x77 => 0x00C7,
    # Latin capital letter E with grave
    0x78 => 0x00C8,
    # Latin capital letter E with acute
    0x79 => 0x00C9,
    # Latin capital letter E with circumflex
    0x7A => 0x00CA,
    # Latin capital letter E with diaeresis
    0x7B => 0x00CB,
    # Latin capital letter I with grave
    0x7C => 0x00CC,
    # Latin capital letter I with acute
    0x7D => 0x00CD,
    # Latin capital letter I with circumflex
    0x7E => 0x00CE
  }

  # DEC Supplementary Character Set
  @dec_supplementary_map %{
    # Add DEC Supplementary character set mappings
    # Non-breaking space
    0x60 => 0x00A0,
    # Inverted exclamation mark
    0x61 => 0x00A1,
    # Cent sign
    0x62 => 0x00A2,
    # Pound sign
    0x63 => 0x00A3,
    # Currency sign
    0x64 => 0x00A4,
    # Yen sign
    0x65 => 0x00A5,
    # Broken bar
    0x66 => 0x00A6,
    # Section sign
    0x67 => 0x00A7,
    # Diaeresis
    0x68 => 0x00A8,
    # Copyright sign
    0x69 => 0x00A9,
    # Feminine ordinal indicator
    0x6A => 0x00AA,
    # Left-pointing double angle quotation mark
    0x6B => 0x00AB,
    # Not sign
    0x6C => 0x00AC,
    # Soft hyphen
    0x6D => 0x00AD,
    # Registered sign
    0x6E => 0x00AE,
    # Macron
    0x6F => 0x00AF,
    # Degree sign
    0x70 => 0x00B0,
    # Plus-minus sign
    0x71 => 0x00B1,
    # Superscript two
    0x72 => 0x00B2,
    # Superscript three
    0x73 => 0x00B3,
    # Acute accent
    0x74 => 0x00B4,
    # Micro sign
    0x75 => 0x00B5,
    # Pilcrow sign
    0x76 => 0x00B6,
    # Middle dot
    0x77 => 0x00B7,
    # Cedilla
    0x78 => 0x00B8,
    # Superscript one
    0x79 => 0x00B9,
    # Masculine ordinal indicator
    0x7A => 0x00BA,
    # Right-pointing double angle quotation mark
    0x7B => 0x00BB,
    # Vulgar fraction one quarter
    0x7C => 0x00BC,
    # Vulgar fraction one half
    0x7D => 0x00BD,
    # Vulgar fraction three quarters
    0x7E => 0x00BE
  }

  # DEC Supplementary Graphics Character Set
  @dec_supplementary_graphics_map %{
    # Add DEC Supplementary Graphics character set mappings
    # Black square
    0x60 => 0x25A0,
    # White square
    0x61 => 0x25A1,
    # White square with rounded corners
    0x62 => 0x25A2,
    # White square containing black small square
    0x63 => 0x25A3,
    # Square with horizontal fill
    0x64 => 0x25A4,
    # Square with vertical fill
    0x65 => 0x25A5,
    # Square with orthogonal crosshatch fill
    0x66 => 0x25A6,
    # Square with upper left to lower right fill
    0x67 => 0x25A7,
    # Square with upper right to lower left fill
    0x68 => 0x25A8,
    # Square with diagonal crosshatch fill
    0x69 => 0x25A9,
    # Black small square
    0x6A => 0x25AA,
    # White small square
    0x6B => 0x25AB,
    # Black rectangle
    0x6C => 0x25AC,
    # White rectangle
    0x6D => 0x25AD,
    # Black vertical rectangle
    0x6E => 0x25AE,
    # White vertical rectangle
    0x6F => 0x25AF,
    # Black parallelogram
    0x70 => 0x25B0,
    # White parallelogram
    0x71 => 0x25B1,
    # Black up-pointing triangle
    0x72 => 0x25B2,
    # White up-pointing triangle
    0x73 => 0x25B3,
    # Black up-pointing small triangle
    0x74 => 0x25B4,
    # White up-pointing small triangle
    0x75 => 0x25B5,
    # Black right-pointing triangle
    0x76 => 0x25B6,
    # White right-pointing triangle
    0x77 => 0x25B7,
    # Black right-pointing small triangle
    0x78 => 0x25B8,
    # White right-pointing small triangle
    0x79 => 0x25B9,
    # Black right-pointing pointer
    0x7A => 0x25BA,
    # White right-pointing pointer
    0x7B => 0x25BB,
    # Black down-pointing triangle
    0x7C => 0x25BC,
    # White down-pointing triangle
    0x7D => 0x25BD,
    # Black down-pointing small triangle
    0x7E => 0x25BE
  }

  # Map of character set names to their translation tables
  @charset_tables %{
    us_ascii: @us_ascii_map,
    uk: @uk_map,
    french: @french_map,
    german: @german_map,
    latin1: @latin1_map,
    dec_special_graphics: @dec_special_graphics_map,
    dec_technical: @dec_technical_map,
    dec_supplementary: @dec_supplementary_map,
    dec_supplementary_graphics: @dec_supplementary_graphics_map
  }

  @doc """
  Returns the US ASCII character set translation table.

  ## Returns

    * Map containing US ASCII character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.us_ascii()
      %{...}
  """
  def us_ascii, do: @us_ascii_map

  @doc """
  Returns the UK character set translation table.

  ## Returns

    * Map containing UK character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.uk()
      %{...}
  """
  def uk, do: @uk_map

  @doc """
  Returns the French character set translation table.

  ## Returns

    * Map containing French character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.french()
      %{...}
  """
  def french, do: @french_map

  @doc """
  Returns the German character set translation table.

  ## Returns

    * Map containing German character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.german()
      %{...}
  """
  def german, do: @german_map

  @doc """
  Returns the Latin-1 character set translation table.

  ## Returns

    * Map containing Latin-1 character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.latin1()
      %{...}
  """
  def latin1, do: @latin1_map

  @doc """
  Returns the DEC Special Graphics character set translation table.

  ## Returns

    * Map containing DEC Special Graphics character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.dec_special()
      %{...}
  """
  def dec_special, do: @dec_special_graphics_map

  @doc """
  Returns the DEC Supplementary character set translation table.

  ## Returns

    * Map containing DEC Supplementary character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.dec_supplementary()
      %{...}
  """
  def dec_supplementary, do: @dec_supplementary_map

  @doc """
  Returns the DEC Technical character set translation table.

  ## Returns

    * Map containing DEC Technical character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.dec_technical()
      %{...}
  """
  def dec_technical, do: @dec_technical_map

  @doc """
  Returns the DEC Supplementary Graphics character set translation table.

  ## Returns

    * Map containing DEC Supplementary Graphics character translations

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.dec_supplementary_graphics()
      %{...}
  """
  def dec_supplementary_graphics, do: @dec_supplementary_graphics_map

  @doc """
  Translates a character from the source character set to the target character set.

  ## Parameters

    * `char_codepoint` - The Unicode codepoint of the character to translate
    * `charset` - The target character set to translate to (e.g., `:us_ascii`, `:uk`, `:french`)

  ## Returns

    * Binary containing the translated character in UTF-8 encoding
    * The original character if no translation exists

  ## Examples

      iex> Raxol.Terminal.ANSI.CharacterTranslations.translate_char(?é, :us_ascii)
      "e"

      iex> Raxol.Terminal.ANSI.CharacterTranslations.translate_char(?a, :us_ascii)
      "a"
  """
  @spec translate_char(char_codepoint :: integer(), charset :: atom()) ::
          binary()
  def translate_char(char, charset) when is_integer(char) do
    map = Map.get(@charset_tables, charset, %{})
    codepoint = Map.get(map, char, char)

    case Raxol.Core.ErrorHandling.safe_call(fn -> <<codepoint::utf8>> end) do
      {:ok, result} ->
        result

      {:error, _reason} ->
        # Fallback for invalid codepoints
        Raxol.Core.Runtime.Log.warning_with_context(
          "Invalid codepoint #{codepoint} in charset #{charset}",
          %{}
        )

        <<char>>
    end
  end

  @doc """
  Translates a string from the source character set to the target character set.
  Handles invalid bytes gracefully by passing them through as-is.
  """
  @spec translate_string(string :: String.t(), charset :: atom()) :: String.t()
  def translate_string(string, charset) when is_binary(string) do
    charlist = get_charlist(string)
    translated = translate_charlist(charlist, charset)
    IO.iodata_to_binary(translated)
  end

  defp get_charlist(string) do
    # :unicode.characters_to_list returns a list on success, not {:ok, list, _}
    case :unicode.characters_to_list(string, :utf8) do
      {:error, _, _} -> :binary.bin_to_list(string)
      {:incomplete, _, _} -> :binary.bin_to_list(string)
      charlist when is_list(charlist) -> charlist
    end
  end

  defp translate_charlist(charlist, charset) do
    Enum.map(charlist, fn
      [0] -> translate_char(0, charset)
      int when is_integer(int) -> translate_char(int, charset)
      _ -> ""
    end)
  end

  @doc """
  Map of Unicode codepoints to their ANSI terminal equivalents.
  """
  def unicode_to_ansi do
    %{
      # NO-BREAK SPACE
      0x00A0 => 32,
      # EN DASH
      0x2013 => 45,
      # EM DASH
      0x2014 => 45,
      # LEFT SINGLE QUOTATION MARK
      0x2018 => 39,
      # RIGHT SINGLE QUOTATION MARK
      0x2019 => 39,
      # LEFT DOUBLE QUOTATION MARK
      0x201C => 34,
      # RIGHT DOUBLE QUOTATION MARK
      0x201D => 34,
      # HORIZONTAL ELLIPSIS
      0x2026 => 46,
      # LINE SEPARATOR
      0x2028 => 10,
      # PARAGRAPH SEPARATOR
      0x2029 => 10,
      # NARROW NO-BREAK SPACE
      0x202F => 32,
      # MEDIUM MATHEMATICAL SPACE
      0x205F => 32,
      # IDEOGRAPHIC SPACE
      0x3000 => 32
    }
  end
end
