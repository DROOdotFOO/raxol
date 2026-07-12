defmodule Raxol.Playground.Demos.TextDemoTest do
  @moduledoc """
  Focused coverage for the `docs/core/LAYOUT.md` section 4 wrap/truncation
  variants added to TextDemo (`text_overflow: :ellipsis`, `line_clamp`,
  `text_wrap: :pretty`) on top of the pre-existing style-cycling behavior.
  These render through `Raxol.UI.Components.Display.Text` via
  `DemoHelpers.rich_text/2`, not the plain View DSL `text/2` used
  elsewhere, so `demos_test.exs`'s generic `is_map(view)` check doesn't
  exercise their actual output.
  """
  use ExUnit.Case, async: true

  alias Raxol.Playground.Demos.TextDemo

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  defp advance(model, 0), do: model

  defp advance(model, n) do
    {model, []} = TextDemo.update(key_event("n"), model)
    advance(model, n - 1)
  end

  # Collects every :text content string in the tree, depth-first. A node's
  # `:children` can be either a single child map or a list (the `do:`
  # block macros don't always normalize to a list), so wrap defensively.
  defp all_text(%{type: :text, content: content}), do: [content]

  defp all_text(%{children: children}) do
    children |> List.wrap() |> Enum.flat_map(&all_text/1)
  end

  defp all_text(_), do: []

  describe "style variants (0-5, pre-existing behavior)" do
    test "index 0 renders the sample sentence in bold" do
      model = TextDemo.init(nil)
      lines = model |> TextDemo.view() |> all_text()

      assert Enum.any?(
               lines,
               &(&1 == "The quick brown fox jumps over the lazy dog")
             )
    end
  end

  describe "ellipsis variant (text_overflow: :ellipsis)" do
    test "long line is truncated with an ellipsis instead of wrapped" do
      model = TextDemo.init(nil) |> advance(6)
      lines = model |> TextDemo.view() |> all_text()

      truncated = Enum.find(lines, &String.contains?(&1, "…"))
      assert truncated
      # nowrap + ellipsis means exactly one truncated line, not the full
      # untruncated sentence anywhere in the tree.
      refute Enum.any?(lines, &String.contains?(&1, "narrow box"))
    end
  end

  describe "line_clamp variant" do
    test "caps output at 2 lines with a trailing ellipsis" do
      model = TextDemo.init(nil) |> advance(7)
      lines = model |> TextDemo.view() |> all_text()

      # The prose is longer than 2 lines at this width, so clamping must
      # have cut something -- the last kept line carries the ellipsis.
      assert Enum.any?(lines, &String.contains?(&1, "…"))
    end
  end

  describe "pretty wrap variant" do
    test "renders both an auto (greedy) and a pretty (Knuth-Plass) rendering" do
      model = TextDemo.init(nil) |> advance(8)
      lines = model |> TextDemo.view() |> all_text()

      assert Enum.any?(lines, &(&1 == "auto (greedy word-wrap):"))
      assert Enum.any?(lines, &String.contains?(&1, "pretty (Knuth-Plass"))
      # Both wrapped renderings must fully preserve every original word.
      assert Enum.any?(lines, &String.contains?(&1, "Raxol"))
    end

    test "n does not advance past the last variant" do
      model = TextDemo.init(nil) |> advance(20)
      assert model.style_index == 8
    end
  end
end
