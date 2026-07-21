defmodule Raxol.UI.TextLayout.PrettyTest do
  @moduledoc """
  Tests for `Raxol.UI.TextLayout.Pretty`, the Knuth-Plass-style `text-wrap:
  pretty` dynamic program. Self-contained: does not import
  `Raxol.UI.TextLayout`; uses a private greedy reference wrap for
  comparison in property/cost-sanity tests.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.TextLayout.Pretty
  alias Raxol.UI.TextMeasure

  # ---------------------------------------------------------------------
  # Private greedy reference (word-list based, no hyphenation/CJK
  # splitting -- used only for comparison in property/cost-sanity tests).
  # ---------------------------------------------------------------------

  defp greedy_wrap([], _width), do: [""]

  defp greedy_wrap(words, width) do
    words
    |> Enum.reduce([], fn word, lines ->
      case lines do
        [] ->
          [word]

        [current | rest] ->
          candidate_width =
            TextMeasure.display_width(current) + 1 +
              TextMeasure.display_width(word)

          if candidate_width <= width do
            [current <> " " <> word | rest]
          else
            [word, current | rest]
          end
      end
    end)
    |> Enum.reverse()
  end

  defp line_word_count(line),
    do: line |> String.split(" ", trim: true) |> length()

  # Cost function mirroring Pretty's default DP cost: sum of squared slack
  # for all but the last line, plus an orphan penalty (width^2) if the
  # last line is a single word while the paragraph has more than 2 words.
  defp total_cost(lines, width, total_words) do
    {body, [last]} = Enum.split(lines, length(lines) - 1)

    body_cost =
      Enum.reduce(body, 0, fn line, acc ->
        diff = width - TextMeasure.display_width(line)
        acc + diff * diff
      end)

    orphan_cost =
      if line_word_count(last) == 1 and total_words > 2 do
        width * width
      else
        0
      end

    body_cost + orphan_cost
  end

  describe "goldens" do
    test "classic raggedness case: pretty balances the orphan, greedy doesn't" do
      words = ~w(The quick brown fox jumps over the lazy dog today)
      text = Enum.join(words, " ")
      width = 15

      greedy = greedy_wrap(words, width)
      pretty = Pretty.wrap(text, width)

      # Greedy leaves a single-word orphan on the last line.
      assert greedy == [
               "The quick brown",
               "fox jumps over",
               "the lazy dog",
               "today"
             ]

      assert line_word_count(List.last(greedy)) == 1

      # Pretty pulls a second word down onto the last line instead.
      assert pretty == [
               "The quick",
               "brown fox jumps",
               "over the lazy",
               "dog today"
             ]

      assert line_word_count(List.last(pretty)) == 2

      for line <- pretty, do: assert(TextMeasure.display_width(line) <= width)
    end

    test "CJK paragraph breaks between ideographs with no spaces" do
      text = "日本語のテキストです今日はとても良い天気ですね"
      width = 10

      assert Pretty.wrap(text, width) == [
               "日本語のテ",
               "キストです",
               "今日はとて",
               "も良い天気",
               "ですね"
             ]
    end

    test "hyphenated word breaks after the hyphen" do
      text = "a well-known algorithm for wrapping text"
      width = 12

      assert Pretty.wrap(text, width) == [
               "a well-known",
               "algorithm",
               "for wrapping",
               "text"
             ]
    end

    test "single word wider than width is force-broken grapheme-safe" do
      text = "supercalifragilisticexpialidocious"
      width = 10

      lines = Pretty.wrap(text, width)

      assert lines == ["supercalif", "ragilistic", "expialidoc", "ious"]
      assert Enum.join(lines) == text
    end

    test "empty string wraps to a single empty line" do
      assert Pretty.wrap("", 10) == [""]
    end

    test "width 1 forces one character per line" do
      lines = Pretty.wrap("cat sat", 1)

      assert lines == ["c", "a", "t", "s", "a", "t"]
      assert Enum.all?(lines, &(TextMeasure.display_width(&1) <= 1))
    end
  end

  # ---------------------------------------------------------------------
  # Unit tests: extra behavior not covered by the goldens
  # ---------------------------------------------------------------------

  describe "multi-paragraph handling" do
    test "paragraphs separated by \\n are wrapped independently and concatenated" do
      text = "para one here\n\npara two here also long enough"

      lines = Pretty.wrap(text, 12)

      # blank paragraph between the two produces a blank line
      assert "" in lines
      assert Enum.join(lines, " ") |> String.contains?("para one here")
      assert Enum.join(lines, " ") |> String.contains?("para two")
    end

    test "single-word paragraph is never penalized for being alone (total_words <= 2)" do
      assert Pretty.wrap("hi", 20) == ["hi"]
      assert Pretty.wrap("hi there", 20) == ["hi there"]
    end
  end

  describe "argument validation" do
    test "raises for non-positive width" do
      assert_raise ArgumentError, fn -> Pretty.wrap("hello", 0) end
      assert_raise ArgumentError, fn -> Pretty.wrap("hello", -5) end
    end
  end

  describe "options" do
    test "orphan_penalty: 0 disables the orphan-avoidance behavior" do
      words = ~w(The quick brown fox jumps over the lazy dog today)
      text = Enum.join(words, " ")
      width = 15

      pretty_default = Pretty.wrap(text, width)
      pretty_no_orphan = Pretty.wrap(text, width, orphan_penalty: 0)
      greedy = greedy_wrap(words, width)

      # With the default orphan penalty, the single-word orphan is avoided.
      assert line_word_count(List.last(pretty_default)) == 2

      # With the penalty disabled, minimizing squared slack alone reverts
      # to the same maximal packing greedy finds -- the orphan returns.
      assert line_word_count(List.last(pretty_no_orphan)) == 1
      assert pretty_no_orphan == greedy
    end
  end

  describe "cost sanity" do
    test "DP picks a lower total badness than greedy on the classic example" do
      words = ~w(The quick brown fox jumps over the lazy dog today)
      text = Enum.join(words, " ")
      width = 15

      greedy = greedy_wrap(words, width)
      pretty = Pretty.wrap(text, width)

      greedy_cost = total_cost(greedy, width, length(words))
      pretty_cost = total_cost(pretty, width, length(words))

      assert pretty_cost < greedy_cost
    end
  end

  # ---------------------------------------------------------------------
  # Properties
  # ---------------------------------------------------------------------

  # Words are bounded to <= width so the "single overlong token" exception
  # never triggers; every line must respect width exactly.
  defp bounded_word(width) do
    StreamData.string(:alphanumeric, min_length: 1, max_length: width)
  end

  defp width_and_words_gen do
    StreamData.bind(StreamData.integer(3..25), fn width ->
      StreamData.bind(
        StreamData.list_of(bounded_word(width), min_length: 1, max_length: 15),
        fn words -> StreamData.constant({width, words}) end
      )
    end)
  end

  property "every output line fits within width when no single token exceeds it" do
    check all({width, words} <- width_and_words_gen(), max_runs: 100) do
      text = Enum.join(words, " ")
      lines = Pretty.wrap(text, width)

      assert Enum.all?(lines, fn line ->
               TextMeasure.display_width(line) <= width
             end)
    end
  end

  property "output reconstructs the input words in order" do
    check all({width, words} <- width_and_words_gen(), max_runs: 100) do
      text = Enum.join(words, " ")
      lines = Pretty.wrap(text, width)

      reconstructed =
        lines
        |> Enum.flat_map(&String.split(&1, " ", trim: true))

      assert reconstructed == words
    end
  end

  property "pretty never produces more lines than greedy + 1 (safety bound)" do
    check all({width, words} <- width_and_words_gen(), max_runs: 100) do
      text = Enum.join(words, " ")
      pretty_lines = Pretty.wrap(text, width)
      greedy_lines = greedy_wrap(words, width)

      assert length(pretty_lines) <= length(greedy_lines) + 1
    end
  end
end
