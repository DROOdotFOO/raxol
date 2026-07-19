defmodule Raxol.Terminal.CharacterHandlingTest do
  use ExUnit.Case
  alias Raxol.Terminal.CharacterHandling

  describe "wide character detection" do
    test ~c"identifies wide characters correctly" do
      assert CharacterHandling.wide_char?(?中)
      assert CharacterHandling.wide_char?(?日)
      refute CharacterHandling.wide_char?(?a)
      refute CharacterHandling.wide_char?(?1)
    end
  end

  describe "character width" do
    test ~c"calculates character width correctly" do
      assert Raxol.Terminal.CharacterHandling.get_char_width("中") == 2
      assert Raxol.Terminal.CharacterHandling.get_char_width("日") == 2
      assert Raxol.Terminal.CharacterHandling.get_char_width("a") == 1
      assert Raxol.Terminal.CharacterHandling.get_char_width("1") == 1
    end

    test ~c"kana and CJK punctuation are East Asian Wide (2 cells)" do
      # Hiragana
      assert CharacterHandling.wide_char?(?こ)
      assert Raxol.Terminal.CharacterHandling.get_char_width("は") == 2
      # Katakana (incl. the prolonged sound mark)
      assert CharacterHandling.wide_char?(?テ)
      assert Raxol.Terminal.CharacterHandling.get_char_width("ト") == 2
      assert Raxol.Terminal.CharacterHandling.get_char_width("ー") == 2
      # Katakana Phonetic Extensions
      assert Raxol.Terminal.CharacterHandling.get_char_width("ㇰ") == 2
      # CJK Symbols and Punctuation: ideographic space, comma, corner bracket
      assert Raxol.Terminal.CharacterHandling.get_char_width("　") == 2
      assert Raxol.Terminal.CharacterHandling.get_char_width("、") == 2
      assert Raxol.Terminal.CharacterHandling.get_char_width("「") == 2

      # Mixed-script strings measure per grapheme: 7 kana = 14 cells
      assert Raxol.Terminal.CharacterHandling.get_string_width("こんにちは世界") ==
               14

      assert Raxol.Terminal.CharacterHandling.get_string_width("テスト") == 6
    end
  end

  describe "combining characters" do
    test ~c"handles combining characters correctly" do
      assert Raxol.Terminal.CharacterHandling.combining_char?(0x0301)
      assert Raxol.Terminal.CharacterHandling.get_char_width("e\u0301") == 1
    end
  end

  describe "bidirectional text" do
    test ~c"processes bidirectional text correctly" do
      # Using a proper RTL character sequence
      # \u202E is RTL mark
      text = "Hello \u202E World"
      # The function returns character-level segmentation, not word-level
      # Each character is processed individually and grouped by type
      result = CharacterHandling.process_bidi_text(text)
      # Verify the structure: list of tuples with direction and text
      assert is_list(result)

      assert Enum.all?(result, fn {direction, text} ->
               direction in [:LTR, :RTL, :NEUTRAL, :COMBINING] and
                 is_binary(text)
             end)

      # Verify we have at least some segments
      assert [_ | _] = result
    end
  end

  describe "string width" do
    test ~c"calculates string width correctly" do
      assert Raxol.Terminal.CharacterHandling.get_string_width("Hello") == 5
      # 5 (Hello) + 1 (space) + 2 (世) + 2 (界) = 10
      assert Raxol.Terminal.CharacterHandling.get_string_width("Hello 世界") == 10
      # 'e' + combining accent = width 1. 5 + 0 = 5
      # Width doesn't include combining char
      assert Raxol.Terminal.CharacterHandling.get_string_width("Hello\u0301") ==
               5
    end
  end

  # Regional indicators (U+1F1E6..U+1F1FF) sit BELOW the {0x1F300, 0x1FAFF}
  # emoji range, so a flag fell through to a first-codepoint lookup and
  # measured one column instead of two.
  describe "regional indicator flags" do
    test "a flag is two columns wide" do
      assert CharacterHandling.get_string_width("🇯🇵") == 2
      assert CharacterHandling.get_string_width("🇺🇸") == 2
      assert CharacterHandling.get_char_width("🇯🇵") == 2
    end

    test "a lone regional indicator stays one column" do
      # Not a flag on its own -- it renders as a narrow letter tile.
      assert CharacterHandling.get_char_width("🇯") == 1
    end

    test "flags measure the same as other two-column emoji" do
      for emoji <- ["🇯🇵", "🎉", "👨‍👩‍👧‍👦", "👩‍💻"] do
        assert CharacterHandling.get_string_width(emoji) == 2,
               "#{emoji} did not measure 2 columns"
      end
    end

    test "a flag in a sentence contributes two columns" do
      assert CharacterHandling.get_string_width("a🇯🇵b") == 4
    end
  end

  # The width table is an ALLOWLIST: anything outside a curated range
  # silently measures 1. Each of these was a real gap found by probing.
  describe "emoji presentation below the 0x1F300 block" do
    test "dingbats and misc symbols with emoji presentation are two columns" do
      for emoji <- ["✅", "❌", "⭐", "⛔", "✨", "⌚", "⏰"] do
        assert CharacterHandling.get_string_width(emoji) == 2,
               "#{emoji} did not measure 2 columns"
      end
    end

    test "text-presentation characters in the same blocks stay one column" do
      # The reason the whole U+2600..27BF block cannot simply be widened.
      for text <- ["✓", "→", "…", "│", "★"] do
        assert CharacterHandling.get_string_width(text) == 1,
               "#{text} should be a single column"
      end
    end

    test "enclosed alphanumerics follow Emoji_Presentation, not their block" do
      # U+1F21A / U+1F22F are Emoji_Presentation=Yes -> 2 columns.
      assert CharacterHandling.get_string_width("🈚") == 2
      assert CharacterHandling.get_string_width("🈯") == 2

      # U+1F170 is Emoji_Presentation=NO despite sitting in the same area
      # and looking like an emoji -- bare it is text presentation, one
      # column, and only VS16 makes it two. Widening by block would get
      # this wrong in the confident direction.
      assert CharacterHandling.get_string_width("🅰") == 1
      assert CharacterHandling.get_string_width("🅰️") == 2
    end
  end

  describe "variation selectors" do
    test "VS16 forces emoji presentation, and therefore two columns" do
      assert CharacterHandling.get_string_width("❤️") == 2
      assert CharacterHandling.get_string_width("⚠️") == 2
    end

    test "the same base WITHOUT VS16 stays one column" do
      # The pair that must not collapse to one answer.
      assert CharacterHandling.get_string_width("❤") == 1
      assert CharacterHandling.get_string_width("⚠") == 1
    end

    test "keycap sequences are two columns" do
      assert CharacterHandling.get_string_width("1️⃣") == 2
      assert CharacterHandling.get_string_width("#️⃣") == 2
    end
  end

  # `split_at_width/2` used to walk codepoints, so it cut grapheme clusters
  # in half. It backs `TextLayout.truncate/3`, which clips table cells,
  # button labels and composer text -- so this fired wherever a clipped
  # string contained an emoji, flag, or accented character.
  describe "split_at_width/2 cluster safety" do
    @clusters ["🇯🇵", "👨‍👩‍👧‍👦", "❤️", "1️⃣", "é", "日"]

    test "never splits a cluster, at any width" do
      for cluster <- @clusters, width <- 0..4 do
        text = cluster <> "ab"
        {left, right} = CharacterHandling.split_at_width(text, width)

        assert left <> right == text
        assert String.valid?(left) and String.valid?(right)

        # The cluster is wholly on one side or the other -- never divided.
        assert left == "" or String.starts_with?(left, cluster),
               "width #{width} cut #{cluster}: left=#{inspect(left)}"
      end
    end

    test "the two halves' widths sum to the original" do
      for cluster <- @clusters, width <- 0..4 do
        text = cluster <> "ab"
        {left, right} = CharacterHandling.split_at_width(text, width)

        assert CharacterHandling.get_string_width(left) +
                 CharacterHandling.get_string_width(right) ==
                 CharacterHandling.get_string_width(text),
               "width #{width} on #{cluster} did not conserve width"
      end
    end

    test "the left side never exceeds the requested width" do
      for cluster <- @clusters, width <- 0..4 do
        {left, _right} =
          CharacterHandling.split_at_width(cluster <> "ab", width)

        assert CharacterHandling.get_string_width(left) <= width
      end
    end

    test "a two-column cluster does not fit in one column" do
      assert {"", "🇯🇵"} = CharacterHandling.split_at_width("🇯🇵", 1)
      assert {"🇯🇵", ""} = CharacterHandling.split_at_width("🇯🇵", 2)
    end
  end
end
