defmodule Raxol.UI.ChromeGlyphWidthTest do
  use ExUnit.Case, async: true

  alias Raxol.UI.TextMeasure

  # Every non-ASCII glyph the UI layer actually draws as CHROME -- borders,
  # rules, bullets, arrows, status marks. Audited by scanning `lib/raxol/ui/`
  # for non-ASCII graphemes; regenerate that list the same way when adding a
  # glyph.
  #
  # Why pin this at all: nearly every character here is East Asian
  # *Ambiguous* (box-drawing, arrows, geometric shapes). Their width is not a
  # property of the character -- it depends on the terminal's locale and font,
  # and Unicode declines to decide. We resolve Ambiguous to 1 column, and that
  # choice is load-bearing precisely BECAUSE it is our own chrome: if the
  # policy is ever flipped to 2, every table border and frame in the app
  # doubles its computed width while the terminal keeps drawing it single, and
  # every layout in the product breaks at once.
  #
  # So this is not a test of Unicode. It is a tripwire on a policy decision,
  # placed at the blast radius. (Technique borrowed from xai-org/grok-build's
  # `glyphs.rs`, which pins its chrome palette the same way -- including
  # keeping every spinner frame the same width so an animating icon never
  # shifts the label beside it.)
  @chrome_glyphs [
    # Box drawing -- table borders, frames, rules
    "─",
    "│",
    "┼",
    "┌",
    "┐",
    "└",
    "┘",
    "┤",
    # Block elements -- meters, gauges, spinners
    "█",
    "▌",
    "░",
    # Geometric -- markers, disclosure indicators
    "▸",
    "▾",
    "○",
    "◆",
    # Arrows
    "→",
    "↑",
    "↓",
    # Punctuation and marks
    "—",
    "…",
    "·",
    "•",
    "»",
    "§",
    "⁖",
    # Status marks
    "✓",
    "✗",
    "⚠",
    "⚙",
    "ℹ",
    "⏸",
    "⊘",
    "❯",
    "❮",
    # Math/logic used in prose chrome
    "±",
    "≈",
    "∴",
    "∵",
    "Δ",
    "γ"
  ]

  describe "chrome glyph width stability" do
    test "every chrome glyph is exactly one column" do
      for glyph <- @chrome_glyphs do
        assert TextMeasure.display_width(glyph) == 1,
               "#{glyph} (#{codepoint(glyph)}) is not 1 column -- if this " <>
                 "changed deliberately, every border and frame in the app " <>
                 "needs re-checking"
      end
    end

    test "every chrome glyph is a single grapheme cluster" do
      # A multi-cluster "glyph" would be splittable by truncation, which is
      # how a border ends up half-drawn at a clip boundary.
      for glyph <- @chrome_glyphs do
        assert length(String.graphemes(glyph)) == 1,
               "#{glyph} (#{codepoint(glyph)}) is not a single cluster"
      end
    end

    # `⚠` and `⚙` are Emoji=Yes but Emoji_Presentation=No: bare they are text
    # presentation and one column, and only VS16 promotes them to two. Some
    # width libraries get this wrong in the confident direction and report 2,
    # which would silently widen every status line that uses one.
    test "text-presentation symbols are not treated as emoji" do
      for glyph <- ["⚠", "⚙", "ℹ", "○", "◆", "⏸"] do
        assert TextMeasure.display_width(glyph) == 1,
               "#{glyph} was measured as emoji-presentation"
      end
    end

    test "adding VS16 to one of them does promote it to two columns" do
      # The counterpart to the test above: the distinction must be real, not
      # an accident of the symbol falling outside every range we know about.
      assert TextMeasure.display_width("⚠️") == 2
      assert TextMeasure.display_width("ℹ️") == 2
    end
  end

  defp codepoint(glyph) do
    [cp | _] = String.to_charlist(glyph)
    "U+" <> String.pad_leading(Integer.to_string(cp, 16), 4, "0")
  end
end
