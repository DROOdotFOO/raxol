defmodule Raxol.UI.Components.Harness.WordDiffTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.WordDiff

  describe "word_ranges/2" do
    test "identical lines have no ranges on either side" do
      assert WordDiff.word_ranges("same", "same") == {[], []}
    end

    test "a single changed word becomes one range per side, excluding the shared space" do
      assert WordDiff.word_ranges("foo bar", "baz bar") == {[{0, 3}], [{0, 3}]}
    end

    test "the changed word can be anywhere in the line" do
      assert WordDiff.word_ranges("keep foo", "keep baz") ==
               {[{5, 3}], [{5, 3}]}
    end

    test "a purely appended word has no old-side range and a new-side range at the tail" do
      {old_ranges, new_ranges} = WordDiff.word_ranges("hello", "hello world")
      assert old_ranges == []
      assert new_ranges == [{5, 6}]
    end

    test "word-alt merges two changed words separated by a single unchanged space" do
      # "red"->"blue" and "apple"->"mango" are each changed, separated by
      # one unchanged space token -- word-alt absorbs that space into one
      # contiguous changed range per side instead of two ranges with an
      # unchanged gap between them. "pie" is untouched on both sides.
      assert WordDiff.word_ranges("red apple pie", "blue mango pie") ==
               {[{0, 9}], [{0, 10}]}
    end

    test "two changed words separated by more than one token are NOT merged" do
      # "foo"->"qux" and "baz"->"quux" are separated by the unchanged
      # word "bar" (3 chars, not a single-char whitespace chunk), so each
      # stays its own range.
      {old_ranges, _new_ranges} =
        WordDiff.word_ranges("foo bar baz", "qux bar quux")

      assert length(old_ranges) == 2
    end

    test "lines over 1000 characters skip the intra-line diff entirely" do
      long = String.duplicate("a", 1001)
      assert WordDiff.word_ranges(long, "short") == {[], []}
      assert WordDiff.word_ranges("short", long) == {[], []}
    end

    test "a line at exactly the 1000 character guard still gets diffed" do
      prefix = String.duplicate("a", 999)
      refute WordDiff.word_ranges(prefix <> "x", prefix <> "y") == {[], []}
    end

    test "whitespace-only differences are still ranges" do
      assert WordDiff.word_ranges("a  b", "a b") != {[], []}
    end
  end
end
