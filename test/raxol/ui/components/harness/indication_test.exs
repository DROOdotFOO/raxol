defmodule Raxol.UI.Components.Harness.IndicationTest do
  @moduledoc """
  The indication container — the harness's one left-edge primitive. These
  pin the contour law: content at column 2, the gutter (column 0) rendered
  down the content's full height per the strategy. Every harness contour
  (speaker sigils, the ∵…∴ thought bracket, a range rule) is a
  parametrization of this one node.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.Components.Harness.Indication

  @dims %{width: 30, height: 12}

  # All positioned {x, y, text} triples, sorted.
  defp texts(view) do
    view
    |> Engine.apply_layout(@dims)
    |> Enum.filter(&(&1[:type] == :text))
    |> Enum.map(fn e -> {e.x, e.y, e.text} end)
    |> Enum.sort()
  end

  defp gutter_cells(view), do: view |> texts() |> Enum.filter(fn {x, _, _} -> x == 0 end)
  defp content_cells(view), do: view |> texts() |> Enum.filter(fn {x, _, _} -> x >= 2 end)

  describe "content column" do
    test "content is always indented to column 2" do
      for view <- [
            Indication.plain("hi"),
            Indication.speaker("hi", "❯"),
            Indication.bracket("a\nb", "∵", "∴"),
            Indication.rule("a\nb", "·")
          ] do
        assert [{2, 0, _} | _] = content_cells(view)
      end
    end

    test "nothing but the gutter ever touches column 0/1" do
      # column 1 is the blank gap; content starts at 2.
      view = Indication.speaker("hello", "❯")
      assert Enum.all?(texts(view), fn {x, _, _} -> x == 0 or x >= 2 end)
    end
  end

  describe ":none — a plain indented block" do
    test "no gutter glyphs at all" do
      view = Indication.plain("plain text")
      assert gutter_cells(view) == []
      assert content_cells(view) == [{2, 0, "plain text"}]
    end
  end

  describe "{:corners, top, nil} — a speaker turn" do
    test "top-left glyph only, at the first row" do
      view = Indication.speaker("hello world", "❯")
      assert gutter_cells(view) == [{0, 0, "❯"}]
      assert content_cells(view) == [{2, 0, "hello world"}]
    end

    test "the sigil is bold" do
      styled =
        Indication.speaker("x", "❯")
        |> Engine.apply_layout(@dims)
        |> Enum.find(&(&1[:type] == :text and &1.text == "❯"))

      assert styled.style[:bold] == true
    end
  end

  describe "{:corners, top, bottom} — a bracketed range (∵…∴)" do
    test "top glyph at the first row, bottom glyph at the LAST row" do
      view = Indication.bracket("a\nb\nc", "∵", "∴")
      assert gutter_cells(view) == [{0, 0, "∵"}, {0, 2, "∴"}]
    end

    test "a single-row container shows only the top glyph (bottom needs >=2 rows)" do
      view = Indication.bracket("only one line", "∵", "∴")
      assert gutter_cells(view) == [{0, 0, "∵"}]
    end

    test "brackets span a NODE's laid-out height, not just strings" do
      node =
        Raxol.View.Components.column(
          gap: 0,
          children: [
            %{type: :text, content: "first"},
            %{type: :text, content: "second"}
          ]
        )

      view = Indication.bracket(node, "∵", "∴")
      content = content_cells(view)
      top_y = content |> Enum.map(fn {_, y, _} -> y end) |> Enum.min()
      bottom_y = content |> Enum.map(fn {_, y, _} -> y end) |> Enum.max()

      assert {0, ^top_y, "∵"} = Enum.find(gutter_cells(view), &match?({0, ^top_y, "∵"}, &1))
      assert {0, ^bottom_y, "∴"} = Enum.find(gutter_cells(view), &match?({0, ^bottom_y, "∴"}, &1))
    end
  end

  describe "{:rule, glyph} — a vertical range indicator" do
    test "the glyph repeats down EVERY row of the content" do
      view = Indication.rule("x\ny\nz", "·")
      assert gutter_cells(view) == [{0, 0, "·"}, {0, 1, "·"}, {0, 2, "·"}]
    end
  end

  describe "measure_element" do
    test "measures as content width + the 2-cell gutter indent" do
      m = Engine.measure_element(Indication.plain("abcd"), @dims)
      assert m.width == 4 + 2
      assert m.height == 1
    end
  end
end
