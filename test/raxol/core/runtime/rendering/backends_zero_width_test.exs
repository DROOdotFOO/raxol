defmodule Raxol.Core.Runtime.Rendering.BackendsZeroWidthTest do
  @moduledoc """
  A cell in the buffer is one screen column. A STANDALONE zero-width
  character cannot honour that contract: it occupies a cell, so the buffer
  budgets a column for it, but it paints nothing, so the terminal advances
  zero — and the row comes out a column short of its own width. That is the
  writer/renderer disagreement that produces creeping misalignment.

  The resolution is to refuse the character at the write boundary rather than
  to answer "how wide is it?" — width is the wrong question for something
  that cannot occupy a cell, and answering 0 would require a cell model where
  a grapheme can live inside its neighbour (see
  `docs/proposals/in-flight/unicode-width-table.md` §7).

  The distinction that matters: a zero-width joiner INSIDE an emoji cluster
  is load-bearing and must survive untouched.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Terminal.CharacterHandling
  alias Raxol.Terminal.Renderer

  @zero_width [
    {"ZWSP", "​"},
    {"ZWNJ", "‌"},
    {"ZWJ (standalone)", "‍"},
    {"LRM", "‎"},
    {"soft hyphen", "­"},
    {"BOM / ZWNBSP", "﻿"},
    {"VS16 (bare)", "️"}
  ]

  defp paint(text, width) do
    cells =
      Raxol.UI.Renderer.render_to_cells(
        [%{type: :text, x: 0, y: 0, text: text, attrs: %{}}],
        %{}
      )

    buffer = Backends.apply_cells_to_buffer(cells, %{width: width, height: 1})

    Renderer.new(buffer, %{}, %{}, true)
    |> Renderer.render_row(0)
    |> String.replace(~r/\e\[[0-9;]*[A-Za-z]/, "")
  end

  describe "standalone zero-width characters" do
    test "a painted row is still exactly as wide as its buffer" do
      for {label, zw} <- @zero_width do
        row = paint("ab" <> zw <> "cd", 20)

        assert CharacterHandling.get_string_width(row) == 20,
               "#{label} left the row a different width than its buffer"
      end
    end

    # The invariant is about COLUMNS, not bytes. Several of these
    # (ZWNJ, ZWJ, VS16) are `Grapheme_Extend`, so they cluster with the
    # character before them and arrive as part of that cell's grapheme
    # rather than as a cell of their own — they ride along invisibly and
    # cost nothing. Only the ones that form their own grapheme can strand a
    # column, and those are the ones being refused. So the assertion is that
    # inserting one never changes the layout, not that the byte disappears.
    test "inserting one never changes the painted width" do
      baseline = CharacterHandling.get_string_width(paint("abcd", 20))

      for {label, zw} <- @zero_width do
        row = paint("ab" <> zw <> "cd", 20)

        assert CharacterHandling.get_string_width(row) == baseline,
               "#{label} changed the painted width"
      end
    end

    # KNOWN LIMITATION, deliberately pinned rather than worked around.
    #
    # ZWSP is not `Grapheme_Extend`, so it forms its own grapheme and the UI
    # layer has already allocated it a column by the time this boundary sees
    # it (`char_display_width/1` still answers 1). Blanking it keeps the row
    # the right WIDTH — which is the invariant that prevents frame
    # corruption — but the character surfaces as a space rather than
    # disappearing, so the text shifts one column against the author's
    # intent.
    #
    # Removing the column outright requires width 0 to reach the element
    # renderer, which is the `0 | 1 | 2` widening deferred in
    # docs/proposals/in-flight/unicode-width-table.md §3. This test exists so
    # that change flips a red test rather than passing silently.
    test "a standalone zero-width grapheme currently becomes a space" do
      row = paint("ab​cd", 20)

      refute String.contains?(row, "​"),
             "a standalone ZWSP was painted into a cell"

      assert String.trim_trailing(row) == "ab cd",
             "expected the documented space; update the proposal if this " <>
               "now renders as \"abcd\""
    end
  end

  describe "zero-width characters INSIDE a cluster" do
    # The carve-out that makes this safe: cells hold whole grapheme
    # clusters, so a joiner within an emoji never arrives as its own char.
    test "a ZWJ sequence survives intact" do
      row = paint("a👨‍👩‍👧‍👦b", 20)

      assert String.contains?(row, "👨‍👩‍👧‍👦"),
             "the ZWJ family was broken up: #{inspect(row)}"

      assert CharacterHandling.get_string_width(row) == 20
    end

    test "a VS16 sequence survives intact and stays two columns" do
      row = paint("a⚠️b", 20)

      assert String.contains?(row, "⚠️")
      assert CharacterHandling.get_string_width(row) == 20
    end

    test "a combining mark stays attached to its base" do
      row = paint("café", 20)

      assert String.contains?(row, "é")
      assert CharacterHandling.get_string_width(row) == 20
    end
  end

  test "ordinary text is unaffected" do
    row = paint("plain ascii", 20)

    assert String.trim_trailing(row) == "plain ascii"
    assert CharacterHandling.get_string_width(row) == 20
  end
end
