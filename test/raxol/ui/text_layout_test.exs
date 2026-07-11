defmodule Raxol.UI.TextLayoutTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.Components.Input.TextWrapping
  alias Raxol.UI.TextLayout

  # --- Characterization pins ---------------------------------------------
  #
  # These pin the pre-existing output of
  # Raxol.UI.Components.Input.TextWrapping.wrap_line_by_word/2 *before* any
  # unification work, so a regression in TextLayout's :normal delegation
  # (which must stay bit-identical) fails loudly. Five pins per the task
  # spec, including the known CJK divergence (wrap_line_by_word does its
  # fit-check with String.length, not display width, so it is not
  # CJK-width-safe -- this is intentionally preserved, not fixed, by
  # :normal).
  describe "characterization: TextWrapping.wrap_line_by_word/2 (pre-refactor pins)" do
    test "collapses nothing -- internal double spaces pass through untouched" do
      assert TextWrapping.wrap_line_by_word("a  b  c", 10) == ["a  b  c"]
    end

    test "basic word wrap" do
      assert TextWrapping.wrap_line_by_word("one two three four", 10) ==
               ["one two", "three four"]
    end

    test "overlong single word breaks by character count" do
      assert TextWrapping.wrap_line_by_word(
               "supercalifragilisticexpialidocious",
               10
             ) == ["supercalif", "ragilistic", "expialidoc", "ious"]
    end

    test "CJK: fit-check is character-count based, not display-width based (known divergence)" do
      # "中文字符串" is 5 graphemes / String.length 5, so it passes the
      # "<=6" character-count check even though its display width is 10.
      # This is the pre-existing (buggy, for CJK) behavior that :normal
      # must preserve bit-for-bit.
      assert TextWrapping.wrap_line_by_word("中文字符串 test", 6) ==
               ["中文字符串", "test"]
    end

    test "trailing spaces are trimmed off the final line" do
      assert TextWrapping.wrap_line_by_word("trailing spaces   ", 10) ==
               ["trailing", "spaces"]
    end
  end

  # --- :normal ---------------------------------------------------------

  describe "wrap/3 :normal (default)" do
    test "delegates to TextWrapping.wrap_line_by_word/2 bit-for-bit" do
      for {text, width} <- [
            {"a  b  c", 10},
            {"one two three four", 10},
            {"supercalifragilisticexpialidocious", 10},
            {"中文字符串 test", 6},
            {"trailing spaces   ", 10},
            {"hello world", 5},
            {"emoji 🎉🎉 party", 8},
            {"word", 4},
            {"ab", 1}
          ] do
        assert TextLayout.wrap(text, width, :normal) ==
                 TextWrapping.wrap_line_by_word(text, width),
               "mismatch for #{inspect(text)} @ #{width}"
      end
    end

    test "default white_space arg is :normal" do
      assert TextLayout.wrap("one two three four", 10) ==
               TextLayout.wrap("one two three four", 10, :normal)
    end

    test "empty string yields a single empty line" do
      assert TextLayout.wrap("", 10, :normal) == [""]
    end

    test "width <= 0 returns text unchanged" do
      assert TextLayout.wrap("hello world", 0, :normal) == ["hello world"]
      assert TextLayout.wrap("hello world", -1, :normal) == ["hello world"]
    end
  end

  # --- :nowrap ------------------------------------------------------------

  describe "wrap/3 :nowrap" do
    test "collapses whitespace runs (including newlines) to a single space, one line" do
      assert TextLayout.wrap("hello   world", 5, :nowrap) == ["hello world"]

      assert TextLayout.wrap("line one\nline two", 5, :nowrap) ==
               ["line one line two"]
    end

    test "trims leading/trailing whitespace" do
      assert TextLayout.wrap("  padded  ", 20, :nowrap) == ["padded"]
    end

    test "ignores width entirely -- never wraps" do
      assert TextLayout.wrap("this is a long line of text", 4, :nowrap) ==
               ["this is a long line of text"]
    end

    test "empty string" do
      assert TextLayout.wrap("", 10, :nowrap) == [""]
    end

    test "all-whitespace collapses to a single empty line" do
      assert TextLayout.wrap("   \n  \t ", 10, :nowrap) == [""]
    end

    test "CJK/emoji pass through uncollapsed content unchanged" do
      assert TextLayout.wrap("中文  emoji 🎉", 4, :nowrap) == ["中文 emoji 🎉"]
    end
  end

  # --- :pre -----------------------------------------------------------

  describe "wrap/3 :pre" do
    test "preserves whitespace exactly, only splits on explicit newlines" do
      assert TextLayout.wrap("a  b\tc", 10, :pre) == ["a  b\tc"]
    end

    test "splits on newlines, ignoring width" do
      assert TextLayout.wrap("line one\nline two\nline three", 4, :pre) ==
               ["line one", "line two", "line three"]
    end

    test "preserves blank lines" do
      assert TextLayout.wrap("a\n\nb", 10, :pre) == ["a", "", "b"]
    end

    test "empty string" do
      assert TextLayout.wrap("", 10, :pre) == [""]
    end

    test "never wraps even a very long line" do
      long = String.duplicate("x", 50)
      assert TextLayout.wrap(long, 5, :pre) == [long]
    end
  end

  # --- :pre_wrap ------------------------------------------------------

  describe "wrap/3 :pre_wrap" do
    test "wraps at width but preserves internal whitespace runs" do
      assert TextLayout.wrap("one  two three", 8, :pre_wrap) ==
               ["one  two", "three"]
    end

    test "whitespace that would itself overflow the wrap point is dropped, not hung" do
      # "one  two " would be 9 wide (over the width-8 budget) -- the space
      # itself doesn't fit, so it's dropped and the break happens there.
      # The next break ("three four" doesn't fit) is *word*-caused, so the
      # already-attached single space before "four" is preserved as-is.
      assert TextLayout.wrap("one  two three four", 8, :pre_wrap) ==
               ["one  two", "three ", "four"]
    end

    test "preserves explicit newlines as hard breaks" do
      assert TextLayout.wrap("ab cd\nef gh", 8, :pre_wrap) ==
               ["ab cd", "ef gh"]
    end

    test "preserves blank lines" do
      assert TextLayout.wrap("a\n\nb", 10, :pre_wrap) == ["a", "", "b"]
    end

    test "empty string" do
      assert TextLayout.wrap("", 10, :pre_wrap) == [""]
    end

    test "overlong single word breaks by display width, CJK/emoji-safe" do
      # each 中 is 2 columns wide; width 6 fits exactly 3 of them
      assert TextLayout.wrap("中中中中中", 6, :pre_wrap) == ["中中中", "中中"]
    end

    test "trailing spaces are preserved (not trimmed)" do
      lines = TextLayout.wrap("trailing spaces   ", 30, :pre_wrap)
      assert lines == ["trailing spaces   "]
    end

    test "single grapheme wider than width is emitted alone, exceeding width" do
      assert TextLayout.wrap("中", 1, :pre_wrap) == ["中"]
    end
  end

  # --- :pre_line ------------------------------------------------------

  describe "wrap/3 :pre_line" do
    test "collapses spaces within a line but preserves newlines" do
      assert TextLayout.wrap("a   b\nc     d", 10, :pre_line) ==
               ["a b", "c d"]
    end

    test "wraps collapsed content at width" do
      assert TextLayout.wrap("one   two three   four", 10, :pre_line) ==
               ["one two", "three four"]
    end

    test "preserves blank lines" do
      assert TextLayout.wrap("a\n\nb", 10, :pre_line) == ["a", "", "b"]
    end

    test "empty string" do
      assert TextLayout.wrap("", 10, :pre_line) == [""]
    end

    test "CJK-aware overlong word breaking (display-width safe, unlike :normal)" do
      assert TextLayout.wrap("中文字符串", 6, :pre_line) == ["中文字", "符串"]
    end

    test "trailing spaces on a segment collapse away" do
      assert TextLayout.wrap("trailing spaces   ", 30, :pre_line) ==
               ["trailing spaces"]
    end
  end

  # --- Properties -------------------------------------------------------

  describe "property: :normal never exceeds width in character count" do
    # :normal's fit-check is String.length-based (pinned, pre-existing
    # behavior -- see the characterization tests above), so this property
    # is scoped to character count, not TextMeasure display width, and to
    # ASCII input so the two measures coincide. This intentionally does
    # not claim CJK display-width safety for :normal; that gap is
    # documented, not covered by this property.
    property "output lines never exceed width in grapheme count, except a single overlong grapheme" do
      check all(
              width <- integer(1..40),
              words <-
                list_of(string(?a..?z, min_length: 1, max_length: 60),
                  min_length: 0,
                  max_length: 12
                ),
              text = Enum.join(words, " "),
              max_runs: 200
            ) do
        lines = TextLayout.wrap(text, width, :normal)

        Enum.each(lines, fn line ->
          len = String.length(line)

          assert len <= width or len == 1,
                 "line #{inspect(line)} (len #{len}) exceeds width #{width}"
        end)
      end
    end
  end

  describe "property: :pre_wrap and :pre_line never exceed display width except a single overlong grapheme" do
    property "display width bound holds for the width-aware, display-width-safe modes" do
      check all(
              width <- integer(1..40),
              words <-
                list_of(
                  string([?a..?z, ?中, ?文, ?🎉],
                    min_length: 1,
                    max_length: 8
                  ),
                  min_length: 0,
                  max_length: 10
                ),
              mode <- member_of([:pre_wrap, :pre_line]),
              text = Enum.join(words, " "),
              max_runs: 200
            ) do
        lines = TextLayout.wrap(text, width, mode)

        Enum.each(lines, fn line ->
          w = Raxol.UI.TextMeasure.display_width(line)
          graphemes = String.graphemes(line)

          single_overlong_grapheme? =
            length(graphemes) == 1 and
              Raxol.UI.TextMeasure.char_display_width(hd(graphemes)) > width

          assert w <= width or single_overlong_grapheme?,
                 "line #{inspect(line)} (width #{w}) exceeds width #{width} for mode #{mode}"
        end)
      end
    end
  end

  # --- truncate/3 (text-overflow) ----------------------------------------

  describe "truncate/3 :ellipsis" do
    test "ASCII: cuts to make room for a trailing single-cell ellipsis" do
      assert TextLayout.truncate("hello world", 8, :ellipsis) == "hello w…"
    end

    test "CJK at cut boundary: never splits a double-width grapheme" do
      # "abc你好": "abc"=3, 你=2 (total 5, fits exactly), 好=2 (would be 7).
      # width 5 forces the cut before 你 fits alongside the ellipsis: only
      # "abc" (3 cols) + "…" (1 col) = 4 cols fit within the width-5 budget.
      assert TextLayout.truncate("abc你好", 5, :ellipsis) == "abc…"
    end

    test "emoji: fits whole emoji graphemes, never splits" do
      assert TextLayout.truncate("🎉🎉🎉", 3, :ellipsis) == "🎉…"
      assert TextLayout.truncate("🎉🎉🎉", 5, :ellipsis) == "🎉🎉…"
    end

    test "width 0: empty string" do
      assert TextLayout.truncate("hello", 0, :ellipsis) == ""
    end

    test "negative width: empty string, no crash" do
      assert TextLayout.truncate("hello", -3, :ellipsis) == ""
    end

    test "width 1 with overflow: just the ellipsis" do
      assert TextLayout.truncate("ab", 1, :ellipsis) == "…"
      assert TextLayout.truncate("中", 1, :ellipsis) == "…"
    end

    test "line already fits: returned unchanged, no ellipsis appended" do
      assert TextLayout.truncate("hi", 10, :ellipsis) == "hi"
      assert TextLayout.truncate("hi", 2, :ellipsis) == "hi"
    end
  end

  describe "truncate/3 :clip" do
    test "ASCII: hard cut at width, no ellipsis" do
      assert TextLayout.truncate("hello world", 8, :clip) == "hello wo"
    end

    test "CJK: never splits a double-width grapheme, cuts one column early" do
      assert TextLayout.truncate("abc你好", 5, :clip) == "abc你"
    end

    test "width 1 with an overlong double-width grapheme yields empty" do
      assert TextLayout.truncate("中", 1, :clip) == ""
    end

    test "width 1 with a narrow grapheme yields that grapheme" do
      assert TextLayout.truncate("ab", 1, :clip) == "a"
    end

    test "width 0: empty string" do
      assert TextLayout.truncate("hello", 0, :clip) == ""
    end

    test "line already fits: returned unchanged" do
      assert TextLayout.truncate("hi", 10, :clip) == "hi"
    end
  end

  describe "property: truncate/3 output display width never exceeds the requested width" do
    property "holds for both :ellipsis and :clip across ASCII/CJK/emoji input" do
      check all(
              width <- integer(0..40),
              mode <- member_of([:ellipsis, :clip]),
              graphemes <-
                list_of(member_of(["a", "b", " ", "中", "文", "🎉"]),
                  min_length: 0,
                  max_length: 30
                ),
              line = Enum.join(graphemes),
              max_runs: 200
            ) do
        result = TextLayout.truncate(line, width, mode)

        assert Raxol.UI.TextMeasure.display_width(result) <= width,
               "truncate(#{inspect(line)}, #{width}, #{mode}) => #{inspect(result)} exceeds width"
      end
    end

    property "never crashes for any width, including negative" do
      check all(
              text <- string(:printable, max_length: 40),
              width <- integer(-10..40),
              mode <- member_of([:ellipsis, :clip]),
              max_runs: 200
            ) do
        result = TextLayout.truncate(text, width, mode)
        assert is_binary(result)
      end
    end
  end

  # --- clamp/4 (line-clamp) -----------------------------------------------

  describe "clamp/4" do
    test "content fits entirely within max_lines: unchanged, no ellipsis" do
      assert TextLayout.clamp("one two", 10, 2) == ["one two"]
    end

    test "exact line count match: unchanged, no ellipsis" do
      assert TextLayout.clamp("one two three four five six", 10, 3) ==
               ["one two", "three four", "five six"]
    end

    test "clamps with block-ellipsis on the last kept line" do
      assert TextLayout.clamp("one two three four five six", 10, 2) ==
               ["one two", "three fou…"]
    end

    test "max_lines 1" do
      assert TextLayout.clamp("one two three", 10, 1) == ["one two…"]
    end

    test "last kept line exactly fills width: re-truncates to make room for the ellipsis" do
      assert TextLayout.clamp("abcdefghij klmno", 10, 1) == ["abcdefghi…"]
    end

    test ":pre_line white_space combination: collapses/wraps then clamps" do
      assert TextLayout.clamp("a\nb\nc\nd", 10, 2, white_space: :pre_line) ==
               ["a", "b…"]
    end

    test "max_lines <= 0 yields an empty list" do
      assert TextLayout.clamp("anything", 10, 0) == []
      assert TextLayout.clamp("anything", 10, -1) == []
    end

    test "empty text yields a single empty line, matching wrap/3" do
      assert TextLayout.clamp("", 10, 2) == [""]
    end

    test "default white_space is :normal" do
      assert TextLayout.clamp("one two three four five six", 10, 2) ==
               TextLayout.clamp("one two three four five six", 10, 2,
                 white_space: :normal
               )
    end
  end

  describe "property: clamp/4 output line count never exceeds max_lines" do
    property "holds across white_space modes and widths" do
      check all(
              width <- integer(1..20),
              max_lines <- integer(1..6),
              white_space <-
                member_of([:normal, :nowrap, :pre, :pre_wrap, :pre_line]),
              words <-
                list_of(string(?a..?z, min_length: 1, max_length: 8),
                  min_length: 0,
                  max_length: 15
                ),
              text = Enum.join(words, " "),
              max_runs: 200
            ) do
        lines =
          TextLayout.clamp(text, width, max_lines, white_space: white_space)

        assert length(lines) <= max_lines
      end
    end
  end

  describe "property: no mode ever crashes and every mode round-trips to a list of strings" do
    property "wrap/3 always returns a list of binaries for any text/width/mode" do
      check all(
              text <- string(:printable, max_length: 60),
              width <- integer(-5..40),
              white_space <-
                member_of([:normal, :nowrap, :pre, :pre_wrap, :pre_line]),
              max_runs: 300
            ) do
        lines = TextLayout.wrap(text, width, white_space)
        assert is_list(lines)
        assert Enum.all?(lines, &is_binary/1)
      end
    end
  end
end
