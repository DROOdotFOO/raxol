defmodule Raxol.Playground.Demos.SplitPaneDemoTest do
  @moduledoc """
  Focused coverage for `{:pct, n}` proportional sizing
  (`docs/core/LAYOUT.md` section 1): without a width/height style on the
  panes, `ratio` only changes the displayed percentage text -- the boxes
  don't actually resize. These tests inspect the raw view tree the demo
  returns to confirm the panes are styled with `{:pct, n}` and that the
  two percentages always sum to 100 regardless of ratio or direction.
  """
  use ExUnit.Case, async: true

  alias Raxol.Playground.Demos.SplitPaneDemo

  defp key_event(char) do
    %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}
  end

  # Walk the view tree and collect every box's `style` map. A node's
  # `:children` can be either a single child map or a list (the `do:`
  # block macros don't always normalize to a list), so wrap defensively.
  defp box_styles(%{type: :box, style: style, children: children}) do
    [style | children |> List.wrap() |> Enum.flat_map(&box_styles/1)]
  end

  defp box_styles(%{children: children}) do
    children |> List.wrap() |> Enum.flat_map(&box_styles/1)
  end

  defp box_styles(_), do: []

  defp pane_pct_styles(model) do
    model
    |> SplitPaneDemo.view()
    |> box_styles()
    |> Enum.filter(fn style ->
      match?({:pct, _}, style[:width]) or match?({:pct, _}, style[:height])
    end)
  end

  describe "horizontal split (default)" do
    test "both panes are styled with {:pct, n} width" do
      model = SplitPaneDemo.init(nil)
      [left, right] = pane_pct_styles(model)

      assert {:pct, 50} = left[:width]
      assert {:pct, 50} = right[:width]
      refute Map.has_key?(left, :height)
    end

    test "resizing the ratio changes the pct split and the two halves sum to 100" do
      model = SplitPaneDemo.init(nil)
      {model, []} = SplitPaneDemo.update(key_event("="), model)

      [left, right] = pane_pct_styles(model)
      {:pct, left_pct} = left[:width]
      {:pct, right_pct} = right[:width]

      assert left_pct == 60
      assert left_pct + right_pct == 100
    end

    test "extreme ratios still sum to 100" do
      model = %{SplitPaneDemo.init(nil) | ratio: 0.1}
      [left, right] = pane_pct_styles(model)
      {:pct, left_pct} = left[:width]
      {:pct, right_pct} = right[:width]

      assert left_pct == 10
      assert left_pct + right_pct == 100
    end
  end

  describe "vertical split" do
    test "toggling direction switches panes to {:pct, n} height" do
      model = SplitPaneDemo.init(nil)
      {model, []} = SplitPaneDemo.update(key_event("d"), model)

      [left, right] = pane_pct_styles(model)
      assert {:pct, 50} = left[:height]
      assert {:pct, 50} = right[:height]
      refute Map.has_key?(left, :width)
    end
  end
end
