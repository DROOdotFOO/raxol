defmodule Raxol.UI.Components.Input.TextWrappingTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Input.TextWrapping
  alias Raxol.UI.TextMeasure

  # `width` here is a DISPLAY-COLUMN budget. This module used to count
  # graphemes against it, which is the same number only for ASCII -- a CJK
  # ideograph is one grapheme and two columns, so a wide run overflowed its
  # line by up to 2x. The tests below are written as invariants rather than
  # golden strings, so they keep holding as the measurement layer changes.
  @wide_samples [
    {"cjk", "日本語のテキストです"},
    {"mixed", "ab日本cd efgh"},
    {"emoji", "🎉 party 👨‍👩‍👧‍👦 time"},
    {"flags", "🇯🇵🇺🇸 flags"},
    {"combining", "café naïve"},
    {"ascii", "the quick brown fox"}
  ]

  describe "wrap_line_by_char/2 — display-column budget" do
    # The exception is deliberate and load-bearing: a cluster wider than the
    # entire budget has to go somewhere, and emitting it alone (overflowing
    # by a column) beats splitting a glyph in half or looping forever. So the
    # invariant is not "never exceeds width" but "only ever exceeds width by
    # being a single indivisible cluster".
    test "a chunk exceeds the width only when it is one indivisible cluster" do
      for {label, line} <- @wide_samples, width <- 1..8 do
        for chunk <- TextWrapping.wrap_line_by_char(line, width) do
          within_budget? = TextMeasure.display_width(chunk) <= width
          single_cluster? = length(String.graphemes(chunk)) == 1

          assert within_budget? or single_cluster?,
                 "#{label} at width #{width}: #{inspect(chunk)} is over budget " <>
                   "and is not a single cluster"
        end
      end
    end

    test "content is preserved exactly" do
      for {label, line} <- @wide_samples, width <- 1..8 do
        rejoined = line |> TextWrapping.wrap_line_by_char(width) |> Enum.join()

        assert rejoined == line, "#{label} at width #{width} lost content"
      end
    end

    test "grapheme clusters are never split" do
      # A flag split in half becomes two lone letter tiles; a ZWJ family
      # split leaves a dangling joiner.
      for cluster <- ["🇯🇵", "👨‍👩‍👧‍👦", "é", "日"], width <- 1..4 do
        chunks = TextWrapping.wrap_line_by_char(cluster <> "ab", width)

        assert Enum.all?(chunks, &String.valid?/1)

        assert Enum.any?(chunks, &String.contains?(&1, cluster)),
               "#{cluster} at width #{width} was split: #{inspect(chunks)}"
      end
    end

    # A 2-column cluster cannot fit a 1-column budget. It must still make
    # progress -- returning an empty chunk forever would hang the renderer.
    test "a cluster wider than the whole budget is emitted alone, not split" do
      assert ["🇯🇵", "a"] = TextWrapping.wrap_line_by_char("🇯🇵a", 1)
      assert ["日", "本"] = TextWrapping.wrap_line_by_char("日本", 1)
    end

    test "ascii behaviour is unchanged" do
      assert ["abc", "def", "gh"] =
               TextWrapping.wrap_line_by_char("abcdefgh", 3)

      assert [""] = TextWrapping.wrap_line_by_char("", 5)
    end
  end

  describe "wrap_line_by_word/2 — display-column budget" do
    test "no wrapped line exceeds the requested width" do
      # Every word here fits its budget on its own, so word wrapping alone
      # should keep each line inside it.
      for {label, line} <- @wide_samples, width <- 12..20 do
        for wrapped <- TextWrapping.wrap_line_by_word(line, width) do
          assert TextMeasure.display_width(wrapped) <= width,
                 "#{label} at width #{width}: #{inspect(wrapped)} is too wide"
        end
      end
    end

    test "a wide word is measured in columns, not graphemes" do
      # "日本語" is 3 graphemes but 6 columns. Against a 4-column budget it
      # is an overlong word and must be broken, not placed whole.
      for line <- TextWrapping.wrap_line_by_word("日本語 x", 4) do
        assert TextMeasure.display_width(line) <= 4
      end
    end
  end
end
