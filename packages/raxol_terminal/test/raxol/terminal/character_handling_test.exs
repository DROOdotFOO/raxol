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
end
