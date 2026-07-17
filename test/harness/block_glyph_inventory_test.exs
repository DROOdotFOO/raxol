defmodule Raxol.Harness.BlockGlyphInventoryTest do
  @moduledoc """
  The no-emoji tripwire (V's addendum): every glyph the harness transcript
  emits into a cell is a MONOCHROME, TEXT-presentation glyph, one display
  column wide.

  Two invariants, swept over `Block.glyph_inventory/0` (the one enumerated
  source of every literal glyph `Block` can render -- fold arrows, per-kind
  glyphs, role/receipt/outcome markers, the tainted marker):

    1. **Width 1.** Every glyph measures exactly one terminal column via
       `Raxol.UI.TextMeasure`. The compact-line layout math (margin cell,
       truncation budgets, the spinner riding the col-0 margin) all assume
       a single-cell glyph; a width-2 emoji would shear every downstream
       column.

    2. **No forced emoji.** No glyph carries U+FE0F (VARIATION SELECTOR-16,
       the emoji-presentation selector). Dual-presentation bases that a
       terminal might otherwise default to emoji (U+26A0 WARNING) carry
       U+FE0E (VS-15, text presentation) instead -- pinned explicitly.

  A future edit that reaches for an emoji glyph, or drops the FE0E guard on
  the warning marker, breaks this LOUDLY rather than shipping a width-2
  emoji into a monochrome text register.
  """

  use ExUnit.Case, async: true

  alias Raxol.UI.Components.Harness.Block
  alias Raxol.UI.TextMeasure

  @vs16 0xFE0F
  @vs15 0xFE0E

  test "every harness glyph measures exactly one display column" do
    for glyph <- Block.glyph_inventory() do
      assert TextMeasure.display_width(glyph) == 1,
             "glyph #{inspect(glyph)} is not one display column " <>
               "(width #{TextMeasure.display_width(glyph)}) -- a machinery " <>
               "glyph must be a single monochrome text cell"
    end
  end

  test "no harness glyph forces emoji presentation (U+FE0F)" do
    for glyph <- Block.glyph_inventory() do
      refute Enum.any?(String.to_charlist(glyph), &(&1 == @vs16)),
             "glyph #{inspect(glyph)} carries U+FE0F (emoji-presentation " <>
               "selector) -- the harness renders text glyphs only"
    end
  end

  test "the tainted-content marker glyph forces text presentation with U+FE0E" do
    marker =
      Enum.find(Block.glyph_inventory(), fn glyph ->
        0x26A0 in String.to_charlist(glyph)
      end)

    assert marker, "the U+26A0 tainted marker is missing from the inventory"

    codepoints = String.to_charlist(marker)

    assert @vs15 in codepoints,
           "the tainted marker (#{inspect(marker)}) dropped its U+FE0E " <>
             "text-presentation guard -- U+26A0 alone may render as emoji"

    assert TextMeasure.display_width(marker) == 1
  end

  test "the inventory covers the glyphs the compact render actually emits" do
    # A guard against the inventory drifting out of sync with the real
    # glyphs: the per-kind glyphs and the fold arrows must all be present.
    for glyph <- ~w(▸ ▾ » ∴ ⚙ ± ⚑ ◆ ❯ ✓ ✗ ⊘) do
      assert glyph in Block.glyph_inventory(),
             "expected #{inspect(glyph)} in Block.glyph_inventory/0"
    end
  end
end
