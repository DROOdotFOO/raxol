defmodule Raxol.CrossTerminal.OverflowTest do
  @moduledoc """
  The `overflow` container property and Viewport `overflow_anchor`
  bottom-follow.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Renderer.View, as: V
  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.Components.Display.Viewport
  require Raxol.Core.Renderer.View

  describe "overflow: :hidden stamps clip_bounds" do
    defp overflowing_box(overflow) do
      V.box(
        style: %{border: :single, width: 10, height: 4, overflow: overflow},
        children: [V.text("WAY TOO LONG FOR TEN CELLS\nrow2\nrow3\nrow4\nrow5")]
      )
    end

    test "hidden: children carry the box's content rect as clip_bounds" do
      elements = Engine.apply_layout(overflowing_box(:hidden), %{width: 40, height: 20})
      texts = Enum.filter(elements, &(&1.type == :text))
      assert texts != []

      for t <- texts do
        # content rect of a 10x4 box with border at origin: {1,1,8,2}
        assert t.clip_bounds == {1, 1, 8, 2}
      end
    end

    test "visible (default): no clip_bounds stamped" do
      elements = Engine.apply_layout(overflowing_box(:visible), %{width: 40, height: 20})
      texts = Enum.filter(elements, &(&1.type == :text))
      assert Enum.all?(texts, &(Map.get(&1, :clip_bounds) == nil))
    end

    test "painted cells stay inside the clip rect" do
      cells =
        overflowing_box(:hidden)
        |> Engine.apply_layout(%{width: 40, height: 20})
        |> Raxol.UI.Renderer.render_to_cells(nil)

      text_cells =
        Enum.filter(cells, fn {_x, _y, char, _fg, _bg, _attrs} ->
          char =~ ~r/[A-Za-z0-9]/
        end)

      assert text_cells != []

      for {x, y, _char, _fg, _bg, _attrs} <- text_cells do
        assert x in 1..8 and y in 1..2,
               "cell escaped clip rect: {#{x}, #{y}}"
      end
    end

    test "nested overflow boxes intersect clip rects" do
      inner =
        V.box(
          style: %{width: 20, height: 10, overflow: :hidden},
          children: [V.text("deep content")]
        )

      outer =
        V.box(
          style: %{border: :single, width: 8, height: 4, overflow: :hidden},
          children: [inner]
        )

      elements = Engine.apply_layout(outer, %{width: 40, height: 20})
      text = Enum.find(elements, &(&1.type == :text))
      assert text != nil
      # outer content rect {1,1,6,2} intersected with inner rect
      {x1, y1, x2, y2} = text.clip_bounds
      assert x2 <= 6 and y2 <= 2 and x1 >= 1 and y1 >= 1
    end
  end

  describe "Viewport overflow_anchor" do
    defp viewport(props) do
      {:ok, state} = Viewport.init(props)
      state
    end

    defp rows(n), do: Enum.map(1..n, &%{type: :text, content: "row #{&1}"})

    test "auto: pinned at bottom follows content growth" do
      state = viewport(children: rows(20), visible_height: 5, scroll_top: 15)
      assert state.scroll_top == 15

      {state, _} = Viewport.update({:set_children, rows(30)}, state)
      # was at bottom (15 == 20-5) -> follows to new bottom (30-5)
      assert state.scroll_top == 25
    end

    test "auto: scrolled up does NOT follow" do
      state = viewport(children: rows(20), visible_height: 5, scroll_top: 3)
      {state, _} = Viewport.update({:set_children, rows(30)}, state)
      assert state.scroll_top == 3
    end

    test "none: never moves on content change" do
      state =
        viewport(
          children: rows(20),
          visible_height: 5,
          scroll_top: 15,
          overflow_anchor: :none
        )

      {state, _} = Viewport.update({:set_children, rows(30)}, state)
      assert state.scroll_top == 15
    end

    test "auto: shrinking content clamps scroll" do
      state = viewport(children: rows(30), visible_height: 5, scroll_top: 10)
      {state, _} = Viewport.update({:set_children, rows(8)}, state)
      assert state.scroll_top == 3
    end
  end
end
