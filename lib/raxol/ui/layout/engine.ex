defmodule Raxol.UI.Layout.Engine do
  @moduledoc """
  Core layout engine that translates the logical view structure into absolute positions.

  This module is responsible for:
  * Calculating element positions based on available space
  * Resolving layout constraints
  * Managing the layout pipeline
  """

  alias Raxol.UI.Layout.{
    CSSGrid,
    Elements,
    Flexbox,
    Grid,
    Inputs,
    Panels,
    PreparedElement,
    Responsive,
    SplitPane,
    Table
  }

  @known_style_attrs [
    :bold,
    :italic,
    :underline,
    :strikethrough,
    :reverse,
    :dim
  ]

  @typedoc """
  Terminal viewport dimensions in cells.
  """
  @type dimensions :: %{
          required(:width) => non_neg_integer(),
          required(:height) => non_neg_integer()
        }

  @typedoc """
  Available space for a layout pass. Origin (`x`, `y`) and extent
  (`width`, `height`) all in cell units relative to the viewport.
  Additional keys (e.g. `:prepared_cache` for the Pretext measurement
  cache) may also be present; only the four geometry keys are required.
  """
  @type space :: %{
          required(:x) => non_neg_integer(),
          required(:y) => non_neg_integer(),
          required(:width) => non_neg_integer(),
          required(:height) => non_neg_integer(),
          optional(atom()) => any()
        }

  @typedoc """
  Input element. Every layout element has a `:type` atom; the rest of the
  shape is type-specific. Containers carry `:children`; leaves carry
  primitive fields like `:text`, `:content`, or `:width`/`:height`.

  Container types: `:view`, `:panel`, `:row`, `:column`, `:grid`, `:flex`,
  `:css_grid`, `:responsive`, `:responsive_grid`, `:box`, `:split_pane`,
  `:absolute_layer`.

  Leaf types: `:text`, `:label`, `:button`, `:text_input`, `:checkbox`,
  `:image`, `:divider`, `:spacer`, `:table`.
  """
  @type element :: %{required(:type) => atom(), optional(atom()) => any()}

  @typedoc """
  Output of `apply_layout/3`: a flat list of positioned elements where each
  carries absolute coordinates and dimensions. The renderer consumes these
  in order to produce cell tuples.
  """
  @type positioned_element :: %{
          required(:type) => atom(),
          required(:x) => non_neg_integer(),
          required(:y) => non_neg_integer(),
          optional(:width) => non_neg_integer(),
          optional(:height) => non_neg_integer(),
          optional(atom()) => any()
        }

  @typedoc """
  Intrinsic measurement -- the minimum space an element wants when laid out.
  """
  @type measurement :: %{
          required(:width) => non_neg_integer(),
          required(:height) => non_neg_integer()
        }

  @doc """
  Applies layout to a view, calculating absolute positions for all elements.

  ## Parameters

  * `view` - The view to calculate layout for
  * `dimensions` - Terminal dimensions `%{width: w, height: h}`
  * `prepared_tree` - Optional `PreparedElement` tree with cached text
    measurements from the prepare phase (Pretext two-phase architecture).
    When provided, `measure_element` will use cached `measured_width` /
    `measured_height` instead of re-calling `TextMeasure.display_width`.

  ## Returns

  A list of positioned elements with absolute coordinates.
  """
  @spec apply_layout(element(), dimensions(), PreparedElement.t() | nil) ::
          [positioned_element()]
  def apply_layout(view, dimensions, prepared_tree \\ nil) do
    # Start with the full screen as available space; carry the prepared
    # measurement cache through the recursion so leaf measure functions
    # can look up cached widths/heights instead of re-measuring.
    available_space = %{
      x: 0,
      y: 0,
      width: dimensions.width,
      height: dimensions.height,
      prepared_cache: build_measurement_cache(prepared_tree)
    }

    view
    |> process_element(available_space, [])
    |> List.flatten()
    |> dim_behind_dialog()
  end

  # Global post-pass: dim every non-`:in_dialog` element once the whole
  # tree is flat, since dialog scope can span siblings outside the
  # hosting `:absolute_layer` (e.g. a sidebar/header). No-op if no dialog
  # is active.
  defp dim_behind_dialog(elements) do
    if Enum.any?(elements, &Map.get(&1, :in_dialog, false)) do
      Enum.map(elements, fn element ->
        case Map.pop(element, :in_dialog, false) do
          {true, stripped} -> stripped
          {false, stripped} -> Map.put(stripped, :dim_behind_modal, true)
        end
      end)
    else
      elements
    end
  end

  # Build a flat map from element content hash to {measured_width, measured_height}.
  defp build_measurement_cache(nil), do: %{}

  defp build_measurement_cache(%PreparedElement{} = pe) do
    entry =
      if pe.content_hash && (pe.measured_width > 0 || pe.measured_height > 0) do
        %{{pe.type, pe.content_hash} => {pe.measured_width, pe.measured_height}}
      else
        %{}
      end

    children_entries =
      case pe.children do
        children when is_list(children) ->
          Enum.reduce(children, %{}, fn child, acc ->
            Map.merge(acc, build_measurement_cache(child))
          end)

        _ ->
          %{}
      end

    Map.merge(entry, children_entries)
  end

  # --- Element Processing Logic ---
  # Moved all process_element/3 definitions here for grouping

  @doc """
  Lays out a single element against `space`, prepending positioned elements
  to `acc`. Dispatches by `:type`; falls through to a logged warning for
  unknown types.

  Used internally by `apply_layout/3` and by container layout modules
  (`Containers`, `Flexbox`, `Grid`, etc.) when recursing into children.
  """
  @spec process_element(element() | any(), space(), [positioned_element()]) ::
          [positioned_element()]
  # Process a view element
  def process_element(%{type: :view, children: children}, space, acc)
      when is_list(children) do
    # Process children with the available space
    process_children(children, space, acc)
  end

  def process_element(%{type: :view, children: children}, space, acc) do
    # Handle case where children is not a list
    process_element(children, space, acc)
  end

  def process_element(%{type: :panel} = panel, space, acc) do
    # Delegate to panel-specific layout processing
    Panels.process(panel, space, acc)
  end

  # Literal :row/:column run on the flex engine via the old Containers
  # dialect's compat map — see containers_compat_to_flex/2.
  def process_element(%{type: type} = el, space, acc)
      when type in [:row, :column] do
    process_element(containers_compat_to_flex(el, :layout), space, acc)
  end

  def process_element(%{type: :grid} = grid, space, acc) do
    # Delegate to grid layout processing
    Grid.process(grid, space, acc)
  end

  def process_element(%{type: :flex} = flex, space, acc) do
    # Build attrs from top-level keys so parse_flex_properties works
    # (View DSL puts direction/gap/etc. at top level, not in :attrs)
    enriched = enrich_flex_attrs(flex)
    Flexbox.process_flex(enriched, space, acc)
  end

  def process_element(%{type: :css_grid} = css_grid, space, acc) do
    # Delegate to CSS Grid layout processing
    CSSGrid.process_css_grid(css_grid, space, acc)
  end

  def process_element(%{type: :responsive} = responsive, space, acc) do
    # Delegate to responsive layout processing
    Responsive.process_responsive(responsive, space, acc)
  end

  def process_element(%{type: :responsive_grid} = responsive_grid, space, acc) do
    # Delegate to responsive grid layout processing
    Responsive.process_responsive_grid(responsive_grid, space, acc)
  end

  # Process basic text/label (old format with :attrs)
  def process_element(%{type: type, attrs: attrs} = _element, space, acc)
      when type in [:label, :text] do
    # Convert keyword list to map if needed
    attrs_map = convert_attrs_to_map(attrs)

    # Create a text element at the given position
    style_map = style_to_map(Map.get(attrs_map, :style, %{}))

    text_element =
      %{
        type: :text,
        x: space.x,
        y: space.y,
        text: Map.get(attrs_map, :content, Map.get(attrs_map, :text, "")),
        fg: Map.get(attrs_map, :fg),
        bg: Map.get(attrs_map, :bg),
        style: style_map,
        link: Map.get(attrs_map, :link),
        # Pass original attributes through, let Renderer handle styling
        attrs: Map.put(attrs_map, :original_type, type)
      }
      |> stamp_paint_bound(space)

    [text_element | acc]
  end

  # Process text elements in new widget format (flat map with :content)
  def process_element(%{type: :text, content: content} = element, space, acc)
      when is_binary(content) do
    style_map = style_to_map(Map.get(element, :style, %{}))

    # A text element may carry a relative `:position` offset in its style
    # (chart cells emitted by `Raxol.UI.Charts.ViewBridge` use this to draw
    # cells at specific (x, y) coordinates inside the container's space).
    # Apply the offset so the cell lands where the chart asked.
    {dx, dy} =
      case Map.get(style_map, :position) || Map.get(element, :position) do
        {x, y} when is_integer(x) and is_integer(y) -> {x, y}
        _ -> {0, 0}
      end

    text_element =
      %{
        type: :text,
        # Carry the declaration id and explicit geometry at the top level so
        # accessibility surfaces can map this cell span back to the source node
        # (Browser data-raxol-id, ARIA). The renderer already honors an explicit
        # width/height, so setting them here is behavior-preserving.
        id: Map.get(element, :id),
        x: space.x + dx,
        y: space.y + dy,
        width: Raxol.UI.TextMeasure.display_width(content),
        # Match measure_element's line count: the renderer paints one row per
        # `\n`-split line, so layout must reserve the same rows or later
        # siblings get painted over.
        height: content |> String.split("\n") |> length(),
        text: content,
        fg: Map.get(element, :fg),
        bg: Map.get(element, :bg),
        style: style_map,
        link: Map.get(element, :link),
        attrs: %{
          style: style_map,
          id: Map.get(element, :id),
          original_type: :text
        }
      }
      |> stamp_paint_bound(space)

    [text_element | acc]
  end

  def process_element(%{type: :button, attrs: attrs} = element, space, acc) do
    text = Map.get(attrs, :label, "Button")
    component_attrs = Map.put(attrs, :component_type, :button)

    build_button_elements(text, component_attrs, space, Map.get(element, :id)) ++
      acc
  end

  # New-DSL form: `text_input(value: ..., placeholder: ...)` builds an
  # element with top-level keys instead of `:attrs`. Rewrite into the
  # `:attrs`-shaped form and forward.
  def process_element(%{type: :text_input} = element, space, acc)
      when not is_map_key(element, :attrs) do
    attrs =
      element
      |> Map.take([
        :value,
        :placeholder,
        :on_change,
        :aria_label,
        :aria_description,
        :style,
        :fg,
        :bg
      ])
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    process_element(Map.put(element, :attrs, attrs), space, acc)
  end

  def process_element(%{type: :text_input, attrs: attrs} = element, space, acc) do
    # Create a text input element composed of box and text
    value = Map.get(attrs, :value, "")
    placeholder = Map.get(attrs, :placeholder, "")
    display_text = get_display_text(value, placeholder)

    # Add component_type, potentially pass placeholder/value info if Renderer needs it
    component_attrs = Map.put(attrs, :component_type, :text_input)

    style_map = style_to_map(Map.get(attrs, :style, %{}))

    text_input_elements = [
      # Input box. Carry the declaration id so accessibility surfaces can map
      # the box's cell span back to the text_input node (data-raxol-id, ARIA).
      %{
        type: :box,
        id: Map.get(element, :id),
        x: space.x,
        y: space.y,
        width:
          min(Raxol.UI.TextMeasure.display_width(display_text) + 4, space.width),
        height: 3,
        style: style_map,
        attrs: component_attrs
      },
      # Input text (or placeholder)
      %{
        type: :text,
        x: space.x + 2,
        y: space.y + 1,
        text: display_text,
        fg: Map.get(attrs, :fg),
        bg: Map.get(attrs, :bg),
        style: style_map,
        # Pass component_attrs; Renderer can check :value == "" and use placeholder style
        attrs:
          Map.merge(component_attrs, %{
            placeholder: value == "",
            style: style_map
          })
      }
    ]

    text_input_elements ++ acc
  end

  def process_element(%{type: :checkbox, attrs: attrs} = element, space, acc) do
    # Create a checkbox element (simple text for now)
    checked = Map.get(attrs, :checked, false)
    label = Map.get(attrs, :label, "")
    component_attrs = Map.put(attrs, :component_type, :checkbox)

    checkbox_text = get_checkbox_text(checked)
    display_text = "#{checkbox_text} #{label}"

    style_map = style_to_map(Map.get(attrs, :style, %{}))

    checkbox_elements = [
      # Checkbox text (box + label). Carry the declaration id and explicit
      # geometry so accessibility surfaces can map this cell span back to the
      # checkbox node (Browser data-raxol-id, ARIA).
      %{
        type: :text,
        id: Map.get(element, :id),
        x: space.x,
        y: space.y,
        width: Raxol.UI.TextMeasure.display_width(display_text),
        height: 1,
        text: display_text,
        fg: Map.get(attrs, :fg),
        bg: Map.get(attrs, :bg),
        style: style_map,
        # Pass attributes for theme styling
        attrs: Map.put(component_attrs, :style, style_map)
      }
    ]

    checkbox_elements ++ acc
  end

  # Process box elements in new View DSL format (no :attrs key)
  def process_element(%{type: :box, children: %{} = child} = box, space, acc) do
    process_element(%{box | children: [child]}, space, acc)
  end

  def process_element(%{type: :box, children: children} = box, space, acc)
      when is_list(children) do
    style = resolve_style(box)
    padding = Map.get(box, :padding, 0)
    border = Map.get(box, :border) || Map.get(style, :border, :none)

    # Honor explicit width/height (style or element), clamped to available
    # space; boxes without explicit dimensions keep filling the space.
    {explicit_w, explicit_h} = resolve_box_dimensions(box, style, space)

    width =
      if is_integer(explicit_w),
        do: min(explicit_w, space.width),
        else: space.width

    height =
      if is_integer(explicit_h),
        do: min(explicit_h, space.height),
        else: space.height

    box_space = %{space | width: width, height: height}
    inner_space = box_inner_space(box_space, border, padding)

    children_space =
      stamp_text_paint_bound(inner_space, style, border, explicit_w)

    box_style = Map.get(box, :style, %{})
    animation_hints = Map.get(box, :animation_hints, [])

    box_element = %{
      type: :box,
      # Carry the declaration id so accessibility surfaces can map this
      # cell span back to the source node (Browser data-raxol-id, ARIA),
      # matching how text/button/text_input boxes already do it.
      id: Map.get(box, :id),
      x: space.x,
      y: space.y,
      width: width,
      height: height,
      style: box_style,
      animation_hints: animation_hints,
      attrs: %{
        border: border,
        padding: padding,
        style: box_style
      }
    }

    children_acc =
      children
      |> process_children(children_space, [])
      |> apply_overflow_clip(style, inner_space, space)

    [box_element | children_acc] ++ acc
  end

  # Chart widget types are emitted by `Components.chart/1` as :box elements
  # whose `:type` is overridden to one of these atoms so MCP ToolProvider
  # can discover them. Layout-wise they behave identically to :box, so
  # rewrite the type and forward.
  def process_element(%{type: type} = element, space, acc)
      when type in [:line_chart, :bar_chart, :scatter_chart, :heatmap] do
    process_element(%{element | type: :box}, space, acc)
  end

  # The harness approval block's render root is stamped :approval_prompt for
  # MCP tool derivation + event routing; layout-wise it IS the column it was
  # built as (a type alias, like the chart discovery types above).
  def process_element(%{type: :approval_prompt} = element, space, acc) do
    process_element(%{element | type: :column}, space, acc)
  end

  # Process button elements in new View DSL format (no :attrs key)
  def process_element(%{type: :button, text: text} = button, space, acc)
      when is_binary(text) do
    style_map = style_to_map(Map.get(button, :style, %{}))

    component_attrs = %{
      component_type: :button,
      label: text,
      on_click: Map.get(button, :on_click),
      fg: Map.get(button, :fg),
      bg: Map.get(button, :bg),
      style: style_map
    }

    build_button_elements(text, component_attrs, space, Map.get(button, :id)) ++
      acc
  end

  def process_element(%{type: :split_pane} = split, space, acc) do
    SplitPane.process(split, space, acc)
  end

  # Absolute layer: lay out the flow child against the parent's full available
  # space (overlays consume nothing), then resolve each overlay against the
  # same space at declared coordinates. Overlays are appended AFTER flow
  # content in the returned list so they sit on top under the renderer's
  # last-write-wins cell composition (`Backends.apply_cells_to_buffer`
  # folds the cell list in order, later entries winning at a shared
  # coordinate -- flow content must come first, overlays last).
  #
  # Element shape:
  #   %{
  #     type: :absolute_layer,
  #     flow_child: element | nil,
  #     overlays: [
  #       %{x: 0, y: 0, element: top_border},
  #       %{x: 0, y: :bottom, element: bottom_border},
  #       %{x: :right, y: :center, element: side_panel}
  #     ]
  #   }
  #
  # Overlay coordinates are relative to the layer's space. Symbolic
  # coordinates (`:left`, `:right`, `:top`, `:bottom`, `:center`) and negative
  # integers (offset from far edge) are resolved against the current space.
  # `{:center_of, size}` centers an overlay of known footprint `size` on that
  # axis (unlike bare `:center`, which anchors the overlay's origin at the
  # midpoint rather than centering its bounding box).
  #
  # An overlay descriptor may carry `dialog: true` (see
  # `Raxol.UI.Components.AbsoluteLayer.dialog_overlay/3`) to stamp its
  # whole subtree `:in_dialog`; `dim_behind_dialog/1` dims everything else
  # once the tree is flat (dialog scope is global, see that function).
  def process_element(%{type: :absolute_layer} = layer, space, acc) do
    flow_child = Map.get(layer, :flow_child)
    overlays = Map.get(layer, :overlays, [])

    flow_elements =
      case flow_child do
        nil -> []
        child -> process_element(child, space, [])
      end

    overlay_elements =
      Enum.reduce(overlays, [], fn overlay, current_acc ->
        # Computed against `[]` (not `current_acc`) so only this overlay's
        # own new elements get stamped, then recombined the same way
        # `process_overlay/3` would have -- every process_element/3 clause
        # in this module follows the `own_new(el, space) ++ acc` contract,
        # so this is equivalent to the un-stamped call when not a dialog.
        own_elements = process_overlay(overlay, space, [])

        own_elements =
          if Map.get(overlay, :dialog, false),
            do: stamp_in_dialog(own_elements),
            else: own_elements

        own_elements ++ current_acc
      end)

    flow_elements ++ overlay_elements ++ acc
  end

  def process_element(%{type: :table} = table_element, space, acc) do
    # Delegate table measurement and positioning to the dedicated module
    Table.measure_and_position(table_element, space, acc)
  end

  def process_element(%{type: :spacer} = spacer, space, acc) do
    size = Map.get(spacer, :size, 1)
    direction = Map.get(spacer, :direction, :vertical)

    {w, h} =
      case direction do
        :horizontal -> {size, space.height}
        _ -> {space.width, size}
      end

    [
      %{
        type: :spacer,
        x: space.x,
        y: space.y,
        width: w,
        height: h,
        style: Map.get(spacer, :style, %{})
      }
      | acc
    ]
  end

  def process_element(%{type: :image} = image_el, space, acc) do
    width = min(Map.get(image_el, :width, 20), space.width)
    height = min(Map.get(image_el, :height, 10), space.height)

    [
      %{
        type: :image,
        x: space.x,
        y: space.y,
        width: width,
        height: height,
        src: Map.get(image_el, :src),
        protocol: Map.get(image_el, :protocol),
        preserve_aspect: Map.get(image_el, :preserve_aspect, true),
        style: Map.get(image_el, :style, %{})
      }
      | acc
    ]
  end

  def process_element(%{type: :divider} = divider, space, acc) do
    # Box-drawing, matching a :single border's horizontal run. The DSL resolves
    # :char from :variant; this default only covers elements built by hand.
    char = Map.get(divider, :char, "─")

    [
      %{
        type: :divider,
        x: space.x,
        y: space.y,
        width: space.width,
        height: 1,
        char: char,
        style: Map.get(divider, :style, %{})
      }
      | acc
    ]
  end

  # Catch-all for unknown element types
  def process_element(%{type: type} = element, _space, acc) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "LayoutEngine: Unknown or unhandled element type: #{inspect(type)}. Element: #{inspect(element)}",
      %{}
    )

    acc
  end

  def process_element(other, _space, acc) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "LayoutEngine: Received non-element data: #{inspect(other)}",
      %{}
    )

    acc
  end

  defp build_button_elements(text, component_attrs, space, id) do
    [
      %{
        type: :box,
        id: id,
        x: space.x,
        y: space.y,
        width: min(Raxol.UI.TextMeasure.display_width(text) + 4, space.width),
        height: 3,
        # Buttons are visually bordered; declare it (the renderer no longer
        # paints a border by default). The label is inset accordingly below.
        style: %{border: :single},
        attrs: component_attrs
      },
      %{
        type: :text,
        x: space.x + 2,
        y: space.y + 1,
        text: text,
        fg: Map.get(component_attrs, :fg),
        bg: Map.get(component_attrs, :bg),
        style: Map.get(component_attrs, :style, %{}),
        attrs: component_attrs
      }
    ]
  end

  # Process children of a container element (Helper).
  # Each child is dispatched through process_element/3 which already handles
  # all element types (containers, primitives, catch-all).
  defp process_children(children, space, acc) when is_list(children) do
    Enum.reduce(children, acc, fn child, current_acc ->
      process_element(child, space, current_acc)
    end)
  end

  # Resolve an overlay descriptor into a positioned space inside `parent_space`
  # and dispatch the overlay's element through process_element/3. Coordinates
  # outside the parent space are clipped (the overlay is silently dropped).
  defp process_overlay(%{element: nil}, _parent_space, acc), do: acc

  defp process_overlay(%{element: element} = overlay, parent_space, acc) do
    raw_x = Map.get(overlay, :x, 0)
    raw_y = Map.get(overlay, :y, 0)

    x = resolve_axis(raw_x, parent_space.x, parent_space.width)
    y = resolve_axis(raw_y, parent_space.y, parent_space.height)

    if in_bounds?(x, y, parent_space) do
      overlay_space = %{
        x: x,
        y: y,
        width: max(parent_space.x + parent_space.width - x, 0),
        height: max(parent_space.y + parent_space.height - y, 0)
      }

      process_element(element, overlay_space, acc)
    else
      acc
    end
  end

  defp process_overlay(_, _, acc), do: acc

  # Marks a dialog overlay's elements `:in_dialog` so dim_behind_dialog/1 exempts them.
  defp stamp_in_dialog(elements) when is_list(elements) do
    Enum.map(elements, &stamp_in_dialog/1)
  end

  defp stamp_in_dialog(element) when is_map(element) do
    Map.put(element, :in_dialog, true)
  end

  defp stamp_in_dialog(other), do: other

  # Resolve a coordinate (integer, negative offset, or symbolic atom) against
  # the parent space's origin and length on a single axis.
  defp resolve_axis(:left, origin, _length), do: origin
  defp resolve_axis(:top, origin, _length), do: origin
  defp resolve_axis(:right, origin, length), do: origin + max(length - 1, 0)
  defp resolve_axis(:bottom, origin, length), do: origin + max(length - 1, 0)
  defp resolve_axis(:center, origin, length), do: origin + div(length, 2)

  # Centers an overlay of known `size` on this axis -- the origin plus half
  # the leftover space, rather than `:center`'s bare midpoint (which anchors
  # the overlay's own origin there, not its bounding box).
  defp resolve_axis({:center_of, size}, origin, length) when is_integer(size),
    do: origin + max(div(length - size, 2), 0)

  defp resolve_axis(value, origin, length) when is_integer(value) and value < 0,
    do: origin + max(length + value, 0)

  defp resolve_axis(value, origin, _length) when is_integer(value),
    do: origin + value

  defp resolve_axis(_other, origin, _length), do: origin

  defp in_bounds?(x, y, %{x: px, y: py, width: w, height: h}) do
    x >= px and x < px + w and y >= py and y < py + h
  end

  # --- End Element Processing ---

  # --- Element Measurement Logic ---
  # Function Header for multi-clause function with defaults
  @doc """
  Calculates the intrinsic dimensions (width, height) of an element.

  This function determines the natural size of an element before layout constraints
  are applied. For containers, it might recursively measure children.

  ## Parameters

  * `element` - The element map to measure.
  * `available_space` - Map providing context (e.g., max width).
  - Defaults to an empty map.

  ## Returns

  A map representing the dimensions: `%{width: integer(), height: integer()}`.
  """
  @spec measure_element(element() | any(), map()) :: measurement()
  def measure_element(element, available_space \\ %{})

  # The harness approval block's render root is stamped :approval_prompt for
  # MCP discovery + event routing; it measures as the column it is. This
  # MUST precede the generic `%{type:, attrs:}` clause below -- the stamped
  # node carries an :attrs map (for the TreeWalker), which would otherwise
  # route it to measure_element_by_type -> handle_unknown -> {0, 0} and
  # collapse the block's height (chart aliases dodge this only because
  # their nodes carry no :attrs). Mirror of the process-side rewrite.
  def measure_element(%{type: :approval_prompt} = element, available_space) do
    measure_element(%{element | type: :column}, available_space)
  end

  # Handles valid elements (maps with :type and :attrs)
  def measure_element(%{type: type, attrs: attrs} = element, available_space)
      when is_atom(type) do
    # Convert keyword list to map if needed
    attrs_map = convert_attrs_to_map(attrs)
    measure_element_by_type(type, element, attrs_map, available_space)
  end

  # Handles new widget format (flat maps with :content/:children, no :attrs)
  def measure_element(%{type: :text, content: content}, available_space)
      when is_binary(content) do
    case lookup_in_cache(available_space[:prepared_cache], :text, content) do
      {w, h} ->
        %{width: w, height: h}

      nil ->
        lines = String.split(content, "\n")

        width =
          lines
          |> Enum.map(&Raxol.UI.TextMeasure.display_width/1)
          |> Enum.max(fn -> 0 end)

        %{width: width, height: length(lines)}
    end
  end

  # Button with top-level :text key (new View DSL format)
  def measure_element(%{type: :button, text: text} = _element, available_space) do
    label = text || "Button"
    Inputs.measure(:button, %{label: label}, available_space)
  end

  # Checkbox with top-level :label key (new View DSL format)
  def measure_element(
        %{type: :checkbox, label: label} = _element,
        available_space
      ) do
    Elements.measure(
      :checkbox,
      %{label: label || ""},
      available_space[:prepared_cache]
    )
  end

  # TextInput with top-level :value/:placeholder keys (new View DSL format)
  def measure_element(%{type: :text_input} = element, available_space) do
    attrs_map = %{
      value: Map.get(element, :value, ""),
      placeholder: Map.get(element, :placeholder, "")
    }

    Inputs.measure(:text_input, attrs_map, available_space)
  end

  # charts are :box under a discovery type alias; measure must mirror the
  # layout-side rewrite or charts measure 0x0 and siblings paint over them
  def measure_element(%{type: type} = element, available_space)
      when type in [:line_chart, :bar_chart, :scatter_chart, :heatmap] do
    measure_element(Map.put(element, :type, :box), available_space)
  end

  # Box with single map child (View DSL produces map, not list, for single child)
  def measure_element(
        %{type: :box, children: %{} = child} = element,
        available_space
      ) do
    measure_element(%{element | children: [child]}, available_space)
  end

  # Box with top-level properties (new View DSL format from Box.new/1)
  def measure_element(
        %{type: :box, children: children} = element,
        available_space
      )
      when is_list(children) do
    style = resolve_style(element)
    overhead = box_overhead(element, style)
    {width, height} = resolve_box_dimensions(element, style, available_space)
    inner_space = shrink_space_by(available_space, overhead)

    resolve_box_size(width, height, children, inner_space, overhead)
  end

  # Flex with top-level properties (new View DSL format from Flex.row/1 etc.)
  def measure_element(
        %{type: :flex, children: children} = element,
        available_space
      )
      when is_list(children) do
    Flexbox.measure_flex(enrich_flex_attrs(element), available_space)
  end

  def measure_element(
        %{type: container_type, children: children} = element,
        available_space
      )
      when container_type in [:row, :column, :view] and is_list(children) do
    measure_element_by_type(container_type, element, %{}, available_space)
  end

  # normalize DSL top-level headers/rows for measure
  def measure_element(%{type: :table} = element, available_space) do
    measured =
      element
      |> Table.normalize_table_attrs()
      |> Table.measure(available_space)

    Map.take(measured, [:width, :height])
  end

  # Absolute layer measures as its flow child measures -- overlays are
  # non-flow (positioned independently in process_element/3) and
  # intentionally contribute nothing to intrinsic size.
  def measure_element(%{type: :absolute_layer} = element, available_space) do
    case Map.get(element, :flow_child) do
      nil -> %{width: 0, height: 0}
      flow_child -> measure_element(flow_child, available_space)
    end
  end

  def measure_element(%{type: :spacer} = spacer, available_space) do
    size = Map.get(spacer, :size, 1)

    case Map.get(spacer, :direction, :vertical) do
      :horizontal -> %{width: size, height: available_space.height}
      _ -> %{width: available_space.width, height: size}
    end
  end

  def measure_element(%{type: :image} = image_el, _available_space) do
    %{
      width: Map.get(image_el, :width, 20),
      height: Map.get(image_el, :height, 10)
    }
  end

  def measure_element(%{type: :divider}, available_space) do
    %{width: available_space.width, height: 1}
  end

  # Catch-all for unknown element types
  def measure_element(other, _available_space) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "LayoutEngine: Cannot measure unknown element type: #{inspect(other)}",
      %{}
    )

    %{width: 0, height: 0}
  end

  defp measure_element_by_type(type, element, attrs_map, available_space) do
    case type do
      type when type in [:text, :label, :box, :checkbox] ->
        Elements.measure(type, attrs_map, available_space[:prepared_cache])

      type when type in [:button, :text_input] ->
        Inputs.measure(type, attrs_map, available_space)

      type
      when type in [
             :row,
             :column,
             :panel,
             :grid,
             :view,
             :flex,
             :css_grid,
             :responsive,
             :responsive_grid,
             :split_pane
           ] ->
        measure_container_element(type, element, available_space)

      :table ->
        Table.measure(attrs_map, available_space)

      _ ->
        handle_unknown_element(type)
    end
  end

  # Measure-side gap default is 0 (the dialect disagreed with layout's
  # default of 1; both are preserved). Explicit attrs.gap is honored.
  defp measure_container_element(type, element, available_space)
       when type in [:row, :column] do
    # Measurement spaces arrive without coordinates from some callers
    # (Panels); flex padding math needs them.
    space =
      available_space
      |> Map.put_new(:x, 0)
      |> Map.put_new(:y, 0)

    Flexbox.measure_flex(containers_compat_to_flex(element, :measure), space)
  end

  defp measure_container_element(:panel, element, available_space),
    do: Panels.measure_panel(element, available_space)

  defp measure_container_element(:grid, element, available_space),
    do: Grid.measure_grid(element, available_space)

  defp measure_container_element(:view, element, available_space),
    do: measure_view(element, available_space)

  # Enrich here too: this path serves old-format elements that carry an
  # :attrs map, which may lack :flex_direction (e.g. only %{flex: ...}) —
  # raw measure_flex would silently default such containers to :row even
  # when the element declares direction: :column at the top level.
  defp measure_container_element(:flex, element, available_space),
    do: Flexbox.measure_flex(enrich_flex_attrs(element), available_space)

  defp measure_container_element(:css_grid, element, available_space),
    do: CSSGrid.measure_css_grid(element, available_space)

  defp measure_container_element(:responsive, element, available_space),
    do: Responsive.measure_responsive(element, available_space)

  defp measure_container_element(:responsive_grid, element, available_space),
    do: Responsive.measure_responsive(element, available_space)

  defp measure_container_element(:split_pane, element, available_space),
    do: SplitPane.measure_split_pane(element, available_space)

  defp measure_view(element, available_space) do
    %{type: :column, children: Map.get(element, :children, [])}
    |> __MODULE__.measure_element(available_space)
  end

  defp handle_unknown_element(type) do
    Raxol.Core.Runtime.Log.warning_with_context(
      "LayoutEngine: Cannot measure element type: #{inspect(type)}",
      %{}
    )

    %{width: 0, height: 0}
  end

  # --- Helper Functions ---

  @doc """
  Looks up cached measurements for an element from the prepare phase.

  The cache is built by `build_measurement_cache/1` and lives on
  `available_space.prepared_cache` for the duration of `apply_layout/3`.
  Returns `{width, height}` if the entry exists, otherwise `nil`.
  """
  @spec lookup_in_cache(map() | nil, atom(), term()) ::
          {non_neg_integer(), non_neg_integer()} | nil
  def lookup_in_cache(cache, type, content) when is_map(cache) do
    Map.get(cache, {type, :erlang.phash2(content)})
  end

  def lookup_in_cache(_cache, _type, _content), do: nil

  defp convert_attrs_to_map(attrs) when is_list(attrs), do: Map.new(attrs)
  defp convert_attrs_to_map(attrs), do: attrs

  defp style_to_map(styles) when is_list(styles) do
    Enum.reduce(styles, %{}, fn
      attr, acc when attr in @known_style_attrs -> Map.put(acc, attr, true)
      _other, acc -> acc
    end)
  end

  defp style_to_map(styles) when is_map(styles), do: styles
  defp style_to_map(_), do: %{}

  # Resolve style map from an element, defaulting to empty map.
  defp resolve_style(element) do
    case Map.get(element, :style) do
      s when is_map(s) -> s
      _ -> %{}
    end
  end

  # Per-side padding as {top, right, bottom, left}. Accepts a bare integer
  # or the tuples produced by Components.Box.normalize_spacing/1.
  defp padding_sides(padding) do
    case padding do
      p when is_integer(p) and p >= 0 -> {p, p, p, p}
      {t, r, b, l} -> {t, r, b, l}
      {h, v} -> {h, v, h, v}
      _ -> {0, 0, 0, 0}
    end
  end

  # Total border + padding overhead for a box as {horizontal, vertical}.
  defp box_overhead(element, style) do
    border = Map.get(element, :border) || Map.get(style, :border, :none)
    {top, right, bottom, left} = padding_sides(Map.get(element, :padding, 0))
    border_offset = if border in [:none, false], do: 0, else: 1
    {2 * border_offset + left + right, 2 * border_offset + top + bottom}
  end

  # Build inner space for a box by subtracting border and padding from outer space.
  defp box_inner_space(space, border, padding) do
    border_offset = if border in [:none, false], do: 0, else: 1
    {top, right, bottom, left} = padding_sides(padding)

    %{
      x: space.x + border_offset + left,
      y: space.y + border_offset + top,
      width: max(0, space.width - 2 * border_offset - left - right),
      height: max(0, space.height - 2 * border_offset - top - bottom)
    }
  end

  # Resolve explicit width/height for a box, handling :fill expansion.
  defp resolve_box_dimensions(element, style, available_space) do
    {size_w, size_h} =
      case Map.get(element, :size) do
        {w, h} -> {w, h}
        s when is_integer(s) -> {s, nil}
        _ -> {nil, nil}
      end

    raw_width =
      Map.get(element, :width) || Map.get(style, :width) || size_w

    raw_height =
      Map.get(element, :height) || Map.get(style, :height) || size_h

    width = if raw_width == :fill, do: available_space.width, else: raw_width

    height =
      if raw_height == :fill, do: available_space.height, else: raw_height

    {width, height}
  end

  # Shrink available space by {horizontal, vertical} overhead.
  defp shrink_space_by(available_space, {overhead_w, overhead_h}) do
    avail_w =
      Map.get(available_space, :width, Raxol.Core.Defaults.terminal_width())

    avail_h =
      Map.get(available_space, :height, Raxol.Core.Defaults.terminal_height())

    Map.merge(available_space, %{
      width: max(0, avail_w - overhead_w),
      height: max(0, avail_h - overhead_h)
    })
  end

  # Determine final box size from explicit dimensions or measured children.
  defp resolve_box_size(w, h, _children, _inner_space, _overhead)
       when is_integer(w) and is_integer(h) do
    %{width: w, height: h}
  end

  defp resolve_box_size(w, _h, children, inner_space, {_ow, oh})
       when is_integer(w) do
    child_dims = measure_children_as_column(children, inner_space)
    %{width: w, height: child_dims.height + oh}
  end

  defp resolve_box_size(_w, _h, children, inner_space, {ow, oh}) do
    child_dims = measure_children_as_column(children, inner_space)

    %{
      width: child_dims.width + ow,
      height: child_dims.height + oh
    }
  end

  defp measure_children_as_column(children, inner_space) do
    measure_container_element(
      :column,
      %{type: :column, children: children},
      inner_space
    )
  end

  # Build :attrs from top-level keys so Flexbox.parse_flex_properties works.
  # The View DSL (Flex.row/column) puts direction/gap/etc. at the top level,
  # but Flexbox reads from the :attrs map.
  # Preserves the old Containers dialect: gap defaults to 1 in layout / 0
  # in measurement (the dialect disagreed between the two), justify/align
  # default :start (never :stretch), children default to shrink 0 unless
  # they declare flex explicitly. Reads `attrs.gap` only — top-level/style
  # gap is not honored here (that compat is in `build_flex_attrs`).
  # Consumers: Viewport, box auto-sizing, Panels, Responsive.
  defp containers_compat_to_flex(el, mode) do
    attrs = Map.get(el, :attrs, %{})
    gap_default = if mode == :layout, do: 1, else: 0

    # gap/justify/align may be top-level or in attrs
    read = fn key, default ->
      case Map.get(attrs, key) do
        nil -> Map.get(el, key, default)
        v -> v
      end
    end

    %{
      type: :flex,
      # Carry the declaration id through so it isn't silently dropped when
      # the literal :row/:column dialect is rewritten into :flex.
      id: Map.get(el, :id),
      attrs: %{
        flex_direction: el.type,
        justify_content: containers_justify(read.(:justify, :start)),
        align_items: containers_align(read.(:align, :start)),
        align_content: :flex_start,
        flex_wrap: :nowrap,
        gap: read.(:gap, gap_default),
        padding: read.(:padding, 0)
      },
      style: Map.get(el, :style, %{}),
      children: el |> Map.get(:children, []) |> Enum.map(&compat_no_shrink/1)
    }
  end

  defp containers_justify(:start), do: :flex_start
  defp containers_justify(:end), do: :flex_end
  defp containers_justify(other), do: other

  defp containers_align(:start), do: :flex_start
  defp containers_align(:end), do: :flex_end
  defp containers_align(other), do: other

  # wrap may arrive as a boolean (Flex.container defaults wrap: false);
  # only :nowrap selects the single-line path, so booleans must normalize
  # or `wrap: false` silently enables wrapping.
  defp normalize_wrap(true), do: :wrap
  defp normalize_wrap(w) when w in [false, nil], do: :nowrap
  defp normalize_wrap(w), do: w

  # Default children to shrink 0 via style.flex_shrink (read by
  # FlexItem.resolve). Deliberately NOT via :attrs — several element
  # processors treat the presence of an :attrs key as "old element
  # format" and rebuild the child from attrs alone, dropping inherited
  # styles.
  defp compat_no_shrink(child) when is_map(child) do
    attrs =
      case Map.get(child, :attrs, %{}) do
        m when is_map(m) -> m
        kw when is_list(kw) -> Map.new(kw)
        _ -> %{}
      end

    style = resolve_style(child)

    has_flex? =
      Map.has_key?(attrs, :flex) or Map.has_key?(style, :flex) or
        Map.has_key?(style, :flex_shrink) or Map.has_key?(style, :flex_grow)

    if has_flex? do
      child
    else
      Map.put(child, :style, Map.put(style, :flex_shrink, 0))
    end
  end

  defp compat_no_shrink(child), do: child

  # Stamps clip_bounds on every descendant when overflow is not :visible;
  # nested clips intersect. :auto/:scroll clip identically — scrolling
  # itself is Viewport's job.
  @doc false
  # Overflow clipping for flex containers (called from Flexbox.process_flex,
  # hence public). The clip rect is the container's own space.
  def apply_container_overflow(elements, container, space) do
    apply_overflow_clip(elements, resolve_style(container), space, space)
  end

  defp apply_overflow_clip(elements, style, inner_space, outer_space) do
    case Map.get(style, :overflow, :visible) do
      :visible ->
        elements

      mode when mode in [:hidden, :clip, :auto, :scroll] ->
        bounds = {
          inner_space.x,
          inner_space.y,
          inner_space.x + max(0, inner_space.width - 1),
          inner_space.y + max(0, inner_space.height - 1)
        }

        Enum.map(elements, &stamp_clip_bounds(&1, bounds))

      other ->
        :telemetry.execute(
          [:raxol, :layout, :invalid_style],
          %{count: 1},
          %{
            key: :overflow,
            value: inspect(other),
            at: {outer_space.x, outer_space.y}
          }
        )

        elements
    end
  end

  defp stamp_clip_bounds(element, bounds) do
    merged =
      case Map.get(element, :clip_bounds) do
        nil -> bounds
        existing -> intersect_bounds(existing, bounds)
      end

    Map.put(element, :clip_bounds, merged)
  end

  defp intersect_bounds({ax1, ay1, ax2, ay2}, {bx1, by1, bx2, by2}) do
    {max(ax1, bx1), max(ay1, by1), min(ax2, bx2), min(ay2, by2)}
  end

  # Stamp `:text_paint_bound` for text inside a definite-boundary box
  # (visible border or explicit/fill width) so `ElementRenderer` can
  # ellipsize (or clip, via `text_overflow: :clip`) at paint time instead
  # of painting past the border. Unbounded boxes don't stamp -- text
  # stays unconstrained (existing behavior). A nested box's own stamp
  # wins for its own subtree.
  defp stamp_text_paint_bound(inner_space, style, border, explicit_w) do
    if definite_box_bound?(border, explicit_w) do
      Map.put(inner_space, :text_paint_bound, text_overflow_mode(style))
    else
      inner_space
    end
  end

  defp definite_box_bound?(border, explicit_w) do
    border not in [:none, false] or explicit_w == :fill or
      is_integer(explicit_w)
  end

  defp text_overflow_mode(style) do
    case Map.get(style, :text_overflow, :ellipsis) do
      :clip -> :clip
      _ellipsis_or_other -> :ellipsis
    end
  end

  defp stamp_paint_bound(text_element, %{text_paint_bound: mode, width: width})
       when mode in [:ellipsis, :clip] do
    text_element
    |> Map.put(:max_paint_width, max(width, 0))
    |> Map.put(:text_overflow, mode)
  end

  defp stamp_paint_bound(text_element, _space), do: text_element

  defp enrich_flex_attrs(%{type: :flex} = flex) do
    existing = Map.get(flex, :attrs, %{})

    if map_size(existing) > 0 and Map.has_key?(existing, :flex_direction) do
      flex
    else
      # Preserve caller-set attrs (e.g. %{flex: %{grow: 1}} on a child)
      # on top of the defaults derived from top-level keys/style.
      Map.put(flex, :attrs, Map.merge(build_flex_attrs(flex), existing))
    end
  end

  # Style values take priority over top-level defaults because
  # Flex.row/column always sets top-level gap/padding to 0 as defaults,
  # so `row style: %{gap: 1}` would otherwise be ignored.
  defp build_flex_attrs(flex) do
    style = resolve_style(flex)

    %{
      flex_direction:
        Map.get(style, :flex_direction) || Map.get(flex, :direction, :row),
      justify_content:
        containers_justify(
          Map.get(style, :justify_content) ||
            Map.get(flex, :justify, :flex_start)
        ),
      align_items:
        containers_align(
          Map.get(style, :align_items) || Map.get(flex, :align, :stretch)
        ),
      align_content:
        containers_align(
          Map.get(style, :align_content) ||
            Map.get(flex, :align_content, :stretch)
        ),
      flex_wrap:
        normalize_wrap(
          Map.get(style, :flex_wrap) || Map.get(flex, :wrap, :nowrap)
        ),
      gap: Map.get(style, :gap) || Map.get(flex, :gap, 0),
      padding: Map.get(style, :padding) || Map.get(flex, :padding, 0)
    }
  end

  defp get_display_text("", placeholder), do: placeholder
  defp get_display_text(value, _placeholder), do: value

  defp get_checkbox_text(true), do: "[[OK]]"
  defp get_checkbox_text(false), do: "[ ]"

  # --- End Measurement Logic ---
end
