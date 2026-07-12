defmodule Raxol.CrossTerminal.ModalOverlayTest do
  @moduledoc """
  Modal-as-true-dialog safety net: modals overlay above undisturbed,
  dimmed background content instead of reflowing it.

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
    test "CellDim.dim_color maps atoms through H-K apparent-lightness compression toward ground" do
      assert CellDim.dim_color(:white) == {106, 106, 106}
      assert CellDim.dim_color(:cyan) == {41, 97, 97}
      # unlisted atom resolves to mid-gray before dimming, not a crash
      assert CellDim.dim_color(:some_theme_color) == {66, 66, 66}
    end

    test "CellDim.dim_color pulls {r, g, b} tuples' apparent lightness toward ground and clamps" do
      assert CellDim.dim_color({200, 100, 50}) == {96, 56, 38}
      assert CellDim.dim_color({0, 0, 0}) == {4, 4, 4}
      assert CellDim.dim_color({255, 255, 255}) == {116, 116, 116}
    end

    test "CellDim.dim_color leaves nil and integer/256-color values untouched; hex strings now dim too" do
      assert CellDim.dim_color(nil) == nil
      assert CellDim.dim_color(42) == 42
      assert CellDim.dim_color("#ff0000") == "#78261d"
    end

    test "CellDim.dim_cell only touches fg/bg, not char/coords/attrs" do
      assert CellDim.dim_cell({3, 4, "X", :white, {200, 100, 50}, [:bold]}) ==
               {3, 4, "X", {106, 106, 106}, {96, 56, 38}, [:bold]}
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
      assert by_char["F"] == {{106, 106, 106}, {96, 56, 38}}
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

      # The dialog char and its explicit fg win the overlap; the bg is the
      # theme default (not fixed across envs), so it is not asserted.
      assert {"X", :cyan, _bg, []} = cells[{0, 0}]
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
    # :absolute_layer measures as its flow child so flex parents give it
    # non-zero height and overlays aren't clipped.

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

      # Flow content max y, identified directly (not via `dim_behind_modal`,
      # which now also stamps the sibling -- see the dimming tests below).
      flow_content_elements =
        Enum.reject(elements, &(Map.get(&1, :text) in ["SIBLING", "ZZZZZZ"]))

      assert flow_content_elements != []

      flow_max_y =
        flow_content_elements
        |> Enum.map(&Map.get(&1, :y, 0))
        |> Enum.max()

      # (c) the sibling sits strictly below the flow content -- before the
      # fix it overlapped at y == 0 because the layer contributed no height
      # to the flex column's main-axis allocation.
      sibling_element = Enum.find(elements, &(Map.get(&1, :text) == "SIBLING"))

      refute is_nil(sibling_element)
      assert sibling_element.y > flow_max_y
    end

    test "a sibling outside the absolute_layer dims too when the dialog is open" do
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

      sibling_element = Enum.find(elements, &(Map.get(&1, :text) == "SIBLING"))
      refute is_nil(sibling_element)
      assert sibling_element.dim_behind_modal == true

      # The dialog's own content is never dim-stamped, even though it's a
      # sibling produced from the same layer -- only the flow child and
      # chrome outside the dialog subtree dim.
      dialog_element = Enum.find(elements, &(Map.get(&1, :text) == "ZZZZZZ"))
      refute is_nil(dialog_element)
      refute Map.get(dialog_element, :dim_behind_modal, false)
    end

    test "no sibling dimming when there is no active dialog" do
      dimensions = %{width: 40, height: 20}

      layer = absolute_layer(background(), [overlay(0, 0, dialog_content())])
      sibling = text("SIBLING", fg: :white)

      root = %{
        type: :flex,
        direction: :column,
        children: [layer, sibling]
      }

      elements = Engine.apply_layout(root, dimensions)

      sibling_element = Enum.find(elements, &(Map.get(&1, :text) == "SIBLING"))
      refute is_nil(sibling_element)
      refute Map.get(sibling_element, :dim_behind_modal, false)

      refute Enum.any?(elements, &Map.get(&1, :dim_behind_modal, false))
    end
  end
end
