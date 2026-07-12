defmodule Raxol.CrossTerminal.ModalOverlayTest do
  @moduledoc """
  Modal-as-true-dialog safety net (issue: modals rendered inline in flow,
  reflowing background content instead of overlaying it dimmed).

  Covers the mechanism at the layout/render level, independent of the
  `Modal` component and `ModalDemo`:

    a. flow content cell coordinates are identical whether a dialog
       overlay is present or not (no reflow)
    b. cells behind an active dialog are dimmed toward the background;
       the dialog's own cells stay full color
    c. dialog cells win over flow cells at overlapping coordinates under
       the renderer's real last-write-wins cell composition
    d. a layer with no dialog overlay is a byte-identical no-op

  `test/raxol/components/modal_test.exs` covers `Modal.as_dialog_overlay/2`
  structurally; `test/cross_terminal/modal_demo_headless_test.exs` covers
  the playground demo end-to-end via a real headless session.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.Renderer, as: UIRenderer
  alias Raxol.UI.CellDim

  import Raxol.UI.Components.AbsoluteLayer

  @dimensions %{width: 40, height: 12}

  defp text(content, opts) do
    Map.merge(%{type: :text, content: content}, Map.new(opts))
  end

  defp background do
    %{
      type: :box,
      children: [
        text("FFFFFFFFFF", fg: :white, bg: {200, 100, 50})
      ]
    }
  end

  defp dialog_content do
    %{type: :box, children: [text("ZZZZZZ", fg: :cyan, bg: {10, 200, 10})]}
  end

  defp positioned_signature(elements) do
    elements
    |> Enum.map(fn el ->
      {Map.get(el, :type), Map.get(el, :x), Map.get(el, :y),
       Map.get(el, :content) || Map.get(el, :text)}
    end)
    |> Enum.sort()
  end

  # Mirrors `Raxol.Core.Runtime.Rendering.Backends.apply_cells_to_buffer/2`'s
  # fold: cells later in the list win at a shared coordinate. This is the
  # real production semantics `render_to_cells`' flat cell list is composed
  # under, so it is the correct oracle for "X painted over Y".
  defp fold_last_write_wins(cells) do
    Enum.reduce(cells, %{}, fn {x, y, char, fg, bg, attrs}, acc ->
      Map.put(acc, {x, y}, {char, fg, bg, attrs})
    end)
  end

  describe "a. no reflow: flow content positions are unaffected by an active dialog" do
    test "flow element positions are identical open vs closed" do
      closed = absolute_layer(background(), [])

      open =
        absolute_layer(background(), [dialog_overlay(8, 3, dialog_content())])

      closed_elements = Engine.apply_layout(closed, @dimensions)
      open_elements = Engine.apply_layout(open, @dimensions)

      # Elements the flow child produced are exactly the ones stamped
      # `:dim_behind_modal` while a dialog overlay is active.
      open_flow_elements =
        Enum.filter(open_elements, &Map.get(&1, :dim_behind_modal, false))

      assert open_flow_elements != []

      assert positioned_signature(closed_elements) ==
               positioned_signature(open_flow_elements)
    end

    test "background text cell (x, y) set is identical open vs closed" do
      closed = absolute_layer(background(), [])

      open =
        absolute_layer(background(), [dialog_overlay(8, 3, dialog_content())])

      closed_coords =
        Engine.apply_layout(closed, @dimensions)
        |> UIRenderer.render_to_cells()
        |> Enum.map(fn {x, y, _c, _fg, _bg, _a} -> {x, y} end)
        |> MapSet.new()

      open_coords =
        Engine.apply_layout(open, @dimensions)
        |> UIRenderer.render_to_cells()
        |> Enum.filter(fn {x, y, _c, _fg, _bg, _a} -> y == 0 and x < 10 end)
        |> Enum.map(fn {x, y, _c, _fg, _bg, _a} -> {x, y} end)
        |> MapSet.new()

      assert MapSet.subset?(open_coords, closed_coords)
      assert MapSet.size(open_coords) > 0
    end
  end

  describe "b. dim mechanics: behind-cells dim, dialog cells stay full color" do
    test "CellDim.dim_color maps atoms to their pale equivalent" do
      assert CellDim.dim_color(:white) == {140, 140, 140}
      assert CellDim.dim_color(:cyan) == {90, 120, 130}
      # unlisted atom falls back to dim gray, not a crash
      assert CellDim.dim_color(:some_theme_color) == {90, 90, 90}
    end

    test "CellDim.dim_color scales {r, g, b} tuples toward black and clamps" do
      assert CellDim.dim_color({200, 100, 50}) == {90, 45, 23}
      assert CellDim.dim_color({0, 0, 0}) == {0, 0, 0}
      assert CellDim.dim_color({255, 255, 255}) == {115, 115, 115}
    end

    test "CellDim.dim_color leaves nil and unrecognized formats untouched" do
      assert CellDim.dim_color(nil) == nil
      assert CellDim.dim_color(42) == 42
      assert CellDim.dim_color("#ff0000") == "#ff0000"
    end

    test "CellDim.dim_cell only touches fg/bg, not char/coords/attrs" do
      assert CellDim.dim_cell({3, 4, "X", :white, {200, 100, 50}, [:bold]}) ==
               {3, 4, "X", {140, 140, 140}, {90, 45, 23}, [:bold]}
    end

    test "a background cell's painted colors are dimmed; the dialog's are not" do
      layer =
        absolute_layer(background(), [dialog_overlay(8, 3, dialog_content())])

      cells =
        Engine.apply_layout(layer, @dimensions) |> UIRenderer.render_to_cells()

      by_char =
        Enum.reduce(cells, %{}, fn {_x, _y, char, fg, bg, _attrs}, acc ->
          Map.put_new(acc, char, {fg, bg})
        end)

      # background painted fg :white / bg {200,100,50} -> dimmed
      assert by_char["F"] == {{140, 140, 140}, {90, 45, 23}}
      # dialog painted fg :cyan / bg {10,200,10} -- full color, untouched
      assert by_char["Z"] == {:cyan, {10, 200, 10}}
    end

    test "no dialog overlay present -> nothing is dimmed" do
      layer = absolute_layer(background(), [overlay(0, 0, dialog_content())])

      cells =
        Engine.apply_layout(layer, @dimensions) |> UIRenderer.render_to_cells()

      by_char =
        Enum.reduce(cells, %{}, fn {_x, _y, char, fg, bg, _attrs}, acc ->
          Map.put_new(acc, char, {fg, bg})
        end)

      assert by_char["F"] == {:white, {200, 100, 50}}
    end
  end

  describe "c. dialog paints over flow content at overlapping coordinates" do
    test "the dialog's cells win under the renderer's real last-write-wins fold" do
      # Force an actual overlap: a 1x1 dialog pinned at (0, 0), exactly
      # where the background's first character paints.
      overlapping_dialog = %{
        x: 0,
        y: 0,
        element: text("X", fg: :cyan),
        dialog: true
      }

      layer = absolute_layer(background(), [overlapping_dialog])

      cells =
        Engine.apply_layout(layer, @dimensions)
        |> UIRenderer.render_to_cells()
        |> fold_last_write_wins()

      assert {"X", :cyan, :black, []} = cells[{0, 0}]
    end
  end

  describe "d. no-op when there is no dialog overlay" do
    test "an absolute_layer with no overlays renders byte-identical cells to the bare tree" do
      bare_cells =
        background()
        |> Engine.apply_layout(@dimensions)
        |> UIRenderer.render_to_cells()

      layered_cells =
        absolute_layer(background(), [])
        |> Engine.apply_layout(@dimensions)
        |> UIRenderer.render_to_cells()

      assert Enum.sort(bare_cells) == Enum.sort(layered_cells)
    end
  end

  describe "e. embedded as a flex child (playground preview panel shape)" do
    # Regression for: `measure_element/2` had no clause for `:absolute_layer`
    # and fell through to the catch-all, returning `%{width: 0, height: 0}`.
    # When a demo view rooted in `:absolute_layer` is a flex child (e.g. the
    # playground's demo preview panel), the flex solver allocated it zero
    # height. That silently dropped every overlay (`process_overlay`'s
    # `in_bounds?` check rejects any y against a zero-height space) and let
    # the following flex sibling overlap the (still-rendered, unclipped)
    # flow content instead of being positioned below it.

    test "measure_element on the absolute_layer returns the flow child's size, not 0x0" do
      available = %{width: 40, height: 20}

      layer =
        absolute_layer(background(), [dialog_overlay(8, 3, dialog_content())])

      flow_size = Engine.measure_element(background(), available)
      layer_size = Engine.measure_element(layer, available)

      refute layer_size == %{width: 0, height: 0}
      assert layer_size == flow_size
    end

    test "overlays survive and the following sibling lands below the flow content" do
      dimensions = %{width: 40, height: 20}

      layer =
        absolute_layer(background(), [dialog_overlay(8, 3, dialog_content())])

      sibling = text("SIBLING", fg: :white)

      root = %{
        type: :flex,
        direction: :column,
        children: [layer, sibling]
      }

      elements = Engine.apply_layout(root, dimensions)

      # (a) the dialog overlay's own content made it into the output --
      # before the fix, the layer's zero-height space clipped every overlay.
      assert Enum.any?(elements, &(Map.get(&1, :text) == "ZZZZZZ"))

      # Flow content (dimmed behind the active dialog) also made it through.
      background_elements =
        Enum.filter(elements, &Map.get(&1, :dim_behind_modal, false))

      assert background_elements != []

      flow_max_y =
        background_elements
        |> Enum.map(&Map.get(&1, :y, 0))
        |> Enum.max()

      # (c) the sibling sits strictly below the flow content -- before the
      # fix it overlapped at y == 0 because the layer contributed no height
      # to the flex column's main-axis allocation.
      sibling_element = Enum.find(elements, &(Map.get(&1, :text) == "SIBLING"))

      refute is_nil(sibling_element)
      assert sibling_element.y > flow_max_y
    end
  end
end
