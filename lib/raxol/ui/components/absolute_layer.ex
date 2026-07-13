defmodule Raxol.UI.Components.AbsoluteLayer do
  @moduledoc """
  Absolute / overlay layer primitive for terminal chrome.

  Wraps a flow child with positioned overlays that draw at fixed coordinates
  inside the layer's available space without consuming layout flow. Use this
  for screen frames, status rails, breadcrumb borders, and other decorative
  chrome that must not push or reflow body content.

  ## Element shape

      %{
        type: :absolute_layer,
        flow_child: body_element,
        overlays: [
          %{x: 0, y: 0, element: top_border},
          %{x: 0, y: :bottom, element: bottom_border},
          %{x: 0, y: 1, element: left_rail},
          %{x: :right, y: 1, element: right_rail}
        ]
      }

  Coordinates accept:

    * non-negative integers -- pixel offsets from the layer's top-left corner
    * negative integers -- offsets from the far edge (`-1` = last cell)
    * `:left` / `:top` -- alias for `0`
    * `:right` -- last column (`width - 1`)
    * `:bottom` -- last row (`height - 1`)
    * `:center` -- midpoint on the axis (the overlay's own origin lands
      there; its bounding box is not centered unless it happens to be 1
      cell wide/tall)
    * `{:center_of, size}` -- centers an overlay of known `size` on that
      axis, i.e. `origin + (length - size) / 2`. Use this to actually
      center a fixed-width/height overlay such as a modal dialog.

  Overlays whose resolved coordinates fall outside the layer's space are
  clipped silently (no cells emitted).

  ## Usage

      import Raxol.UI.Components.AbsoluteLayer

      def view(model) do
        absolute_layer(
          body(model),
          [
            overlay(0, 0, top_border()),
            overlay(0, :bottom, bottom_border()),
            overlay(0, 1, left_rail()),
            overlay(:right, 1, right_rail())
          ]
        )
      end
  """

  @type axis_coord ::
          non_neg_integer()
          | integer()
          | :left
          | :right
          | :top
          | :bottom
          | :center
          | {:center_of, non_neg_integer()}

  @type overlay :: %{
          required(:x) => axis_coord(),
          required(:y) => axis_coord(),
          required(:element) => map(),
          optional(:dialog) => boolean()
        }

  @doc """
  Builds an `:absolute_layer` element wrapping `flow_child` with `overlays`.

  Either argument may be `nil` / `[]` -- a layer with neither flow nor
  overlays is a no-op but is still valid.
  """
  @spec absolute_layer(map() | nil, [overlay()]) :: map()
  def absolute_layer(flow_child, overlays \\ [])
      when is_list(overlays) do
    %{
      type: :absolute_layer,
      flow_child: flow_child,
      overlays: overlays
    }
  end

  @doc """
  Builds a single overlay descriptor at coordinates `{x, y}`.
  """
  @spec overlay(axis_coord(), axis_coord(), map()) :: overlay()
  def overlay(x, y, element) when is_map(element) do
    %{x: x, y: y, element: element}
  end

  @doc """
  Builds a dialog overlay descriptor: `element` (a `width` x `height`
  surface, e.g. a modal box) centered on both axes via `{:center_of, _}`,
  and marked `dialog: true`.

  The `:dialog` marker tells the layout engine to dim every element the
  layer's flow content produces (pulling painted fg/bg toward the
  background) while leaving this overlay's own cells at full color --
  the "dialog active" / "inside active dialog" pair described in
  `Raxol.UI.Layout.Engine`'s `:absolute_layer` handling.
  """
  @spec dialog_overlay(non_neg_integer(), non_neg_integer(), map()) ::
          overlay()
  def dialog_overlay(width, height, element)
      when is_map(element) and is_integer(width) and is_integer(height) do
    %{
      x: {:center_of, width},
      y: {:center_of, height},
      element: element,
      dialog: true
    }
  end
end
