defmodule Raxol.UI.Renderer do
  @moduledoc """
  UI Renderer for Raxol terminal applications.

  This module provides rendering capabilities for various UI elements
  including panels, boxes, text, and tables with theme support.
  """

  alias Raxol.UI.{CellManager, ElementRenderer, StyleProcessor, ThemeResolver}

  @doc """
  Renders a single element or list of elements to cells using the default theme.

  ## Parameters
    * `element_or_elements` - Single element map, list of elements, or nil

  ## Returns
    * List of cells in the format {x, y, char, fg, bg, attrs}
  """
  def render_to_cells(element_or_elements) do
    render_to_cells(element_or_elements, nil)
  end

  @doc """
  Renders a single element or list of elements to cells.
  This is the main public API for the renderer.

  ## Parameters
    * `element_or_elements` - Single element map, list of elements, or nil
    * `theme` - Optional theme (defaults to default theme)

  ## Returns
    * List of cells in the format {x, y, char, fg, bg, attrs}
  """
  def render_to_cells(nil, _theme), do: []

  def render_to_cells(element_or_elements, theme) do
    # Ensure we have a list of elements
    elements = CellManager.ensure_list(element_or_elements)

    # Get default theme if none provided
    default_theme = theme || ThemeResolver.get_default_theme()

    # Render each element and flatten results
    elements
    |> Enum.flat_map(fn element ->
      # Use element's theme if available, otherwise use default theme
      element_theme =
        ThemeResolver.resolve_element_theme_with_inheritance(
          element,
          default_theme
        )

      render_element(element, element_theme, %{})
    end)
    |> CellManager.filter_valid_cells()
  end

  @doc """
  Renders a UI element to a list of cells.

  ## Parameters
    * `element` - The element to render
    * `theme` - The theme to use for rendering
    * `parent_style` - Parent style to inherit from (optional)

  ## Returns
    * List of cells in the format {x, y, char, fg, bg, attrs}
  """
  def render_element(element, theme, parent_style \\ %{}) do
    case validate_element(element) do
      {:ok, valid_element} ->
        render_validated_element(valid_element, theme, parent_style)

      {:error, _reason} ->
        []
    end
  end

  defp render_validated_element(%{visible: false}, _theme, _parent_style),
    do: []

  defp render_validated_element(valid_element, theme, parent_style) do
    # Calculate dimensions if missing, especially for text elements
    element_with_dims = calculate_element_dimensions(valid_element)
    width = Map.get(element_with_dims, :width, 0)
    height = Map.get(element_with_dims, :height, 0)

    case {width, height} do
      {0, _} ->
        []

      {_, 0} ->
        []

      _ ->
        # Layout-stamped overflow clipping applies to every element type
        # generically; type-specific render paths that clip themselves are
        # unaffected (intersection is idempotent). Same choke point for
        # modal-backdrop dimming: `:dim_behind_modal` is global, stamped on
        # every non-`:in_dialog` element while a dialog overlay is active,
        # not just the hosting `:absolute_layer`'s flow content.
        element_with_dims
        |> render_visible_element(theme, parent_style)
        |> CellManager.clip_cells_to_bounds(
          Map.get(element_with_dims, :clip_bounds)
        )
        |> maybe_dim(element_with_dims)
    end
  end

  defp maybe_dim(cells, %{dim_behind_modal: true}),
    do: Raxol.UI.CellDim.dim_cells(cells)

  defp maybe_dim(cells, _element), do: cells

  # --- Element Dimension Calculation ---

  defp calculate_element_dimensions(%{type: :text} = element) do
    # Calculate text dimensions if missing
    text = Map.get(element, :text, "")

    width = get_text_width(element, text)
    height = get_text_height(element)

    Map.merge(element, %{width: width, height: height})
  end

  defp calculate_element_dimensions(element) do
    # For other element types, return as-is
    element
  end

  defp get_text_width(%{width: width}, _text), do: width

  defp get_text_width(_element, text),
    do: Raxol.UI.TextMeasure.display_width(text)

  defp get_text_height(%{height: height}), do: height
  defp get_text_height(_element), do: 1

  # --- Element Validation ---

  defp validate_element(nil), do: {:error, :nil_element}

  defp validate_element(element) when not is_map(element),
    do: {:error, :invalid_element}

  defp validate_element(element) do
    case {Map.has_key?(element, :type), Map.get(element, :width, 0) >= 0,
          Map.get(element, :height, 0) >= 0} do
      {false, _, _} -> {:error, :missing_type}
      {true, false, _} -> {:error, :negative_width}
      {true, true, false} -> {:error, :negative_height}
      {true, true, true} -> {:ok, element}
    end
  end

  # --- Element Type Rendering ---

  defp render_visible_element(
         %{type: :panel, x: x, y: y, width: w, height: h} = panel_element,
         theme,
         parent_style
       ) do
    ElementRenderer.render_panel(x, y, w, h, panel_element, theme, parent_style)
  end

  defp render_visible_element(
         %{type: :box, x: x, y: y, width: w, height: h} = box_element,
         theme,
         parent_style
       ) do
    merged_style =
      StyleProcessor.flatten_merged_style(parent_style, box_element, theme)

    box_cells = ElementRenderer.render_box(x, y, w, h, merged_style, theme)
    clip_bounds = Map.get(box_element, :clip_bounds)

    children_cells =
      render_box_children(box_element, clip_bounds, theme, merged_style)

    title_cells = render_box_title(box_element, x, y, w, merged_style)
    all_cells = CellManager.merge_cells(box_cells, children_cells)
    all_cells = CellManager.merge_cells(all_cells, title_cells)
    CellManager.clip_cells_to_bounds(all_cells, clip_bounds)
  end

  defp render_visible_element(
         %{type: :text, text: text_content, x: x, y: y} = text_element,
         theme,
         parent_style
       ) do
    merged_style =
      parent_style
      |> StyleProcessor.flatten_merged_style(text_element, theme)
      |> put_paint_bound(text_element)

    cells = ElementRenderer.render_text(x, y, text_content, merged_style, theme)
    CellManager.clip_cells_to_bounds(cells, Map.get(text_element, :clip_bounds))
  end

  defp render_visible_element(
         %{type: :table, x: x, y: y} = table_element,
         theme,
         parent_style
       ) do
    _merged_style =
      StyleProcessor.flatten_merged_style(parent_style, table_element, theme)

    # Extract table data from the element or attrs
    attrs = Map.get(table_element, :attrs, %{})
    headers = Map.get(table_element, :headers) || Map.get(attrs, :_headers, [])
    data = Map.get(table_element, :data) || Map.get(attrs, :_data, [])

    column_widths =
      Map.get(table_element, :column_widths) || Map.get(attrs, :_col_widths, [])

    # Calculate table width if not provided
    width = ElementRenderer.calculate_table_width(headers, data, column_widths)

    # Build attrs with table data and custom styles
    merged_attrs =
      ElementRenderer.build_table_attrs(
        table_element,
        headers,
        data,
        column_widths
      )

    cells = ElementRenderer.render_table(x, y, width, 0, merged_attrs, theme)

    CellManager.clip_cells_to_bounds(
      cells,
      Map.get(table_element, :clip_bounds)
    )
  end

  defp render_visible_element(%{type: :spacer}, _theme, _parent_style) do
    []
  end

  defp render_visible_element(
         %{type: :image, x: x, y: y, width: w, height: _h} = image_el,
         _theme,
         _parent_style
       ) do
    src = Map.get(image_el, :src)
    opts = build_image_opts(image_el)

    case Raxol.Terminal.Image.display(src, opts) do
      {:ok, escape_seq} ->
        [{x, y, escape_seq, :default, :default, [image: true]}]

      {:error, _reason} ->
        render_image_placeholder(x, y, w)
    end
  end

  defp render_visible_element(
         %{type: :divider, x: x, y: y, width: w, char: char} = element,
         _theme,
         _parent_style
       ) do
    style = Map.get(element, :style, %{})
    fg = Map.get(style, :fg, :white)
    bg = Map.get(style, :bg)
    ch = String.at(char || "-", 0) || "-"

    for col <- 0..(w - 1), do: {x + col, y, ch, fg, bg, []}
  end

  # Catch-all clause for unhandled element types
  defp render_visible_element(_element, _theme, _parent_style) do
    []
  end

  defp build_image_opts(image_el) do
    [
      width: Map.get(image_el, :width),
      height: Map.get(image_el, :height),
      protocol: Map.get(image_el, :protocol),
      preserve_aspect: Map.get(image_el, :preserve_aspect, true)
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp render_image_placeholder(x, y, w) do
    truncated = String.slice("[image]", 0, w)

    for {ch, i} <- Enum.with_index(String.graphemes(truncated)) do
      {x + i, y, ch, :white, :black, []}
    end
  end

  defp render_box_children(box_element, clip_bounds, theme, merged_style) do
    case Map.get(box_element, :children) do
      nil ->
        []

      children when is_list(children) ->
        Enum.flat_map(children, fn child ->
          child_with_clip = add_clip_bounds(child, clip_bounds)
          render_element(child_with_clip, theme, merged_style)
        end)

      child when is_map(child) ->
        child_with_clip = add_clip_bounds(child, clip_bounds)
        render_element(child_with_clip, theme, merged_style)
    end
  end

  defp render_box_title(%{title: title}, x, y, w, style)
       when is_binary(title) and title != "" do
    has_border = Map.get(style, :border, :none) != :none
    border_offset = if(has_border, do: 2, else: 0)

    title_x = x + border_offset
    max_len = w - border_offset * 2
    truncated = String.slice(title, 0, max(0, max_len))

    {fg, bg, attrs} = resolve_title_style(style)

    truncated
    |> String.graphemes()
    |> Enum.with_index()
    |> Enum.map(fn {char, i} ->
      {title_x + i, y, char, fg, bg, attrs}
    end)
  end

  defp render_box_title(_box_element, _x, _y, _w, _style), do: []

  defp resolve_title_style(style) do
    fg = Map.get(style, :fg, Map.get(style, :fg_color, :white))
    bg = Map.get(style, :bg, Map.get(style, :bg_color, :black))
    attrs = if Map.get(style, :bold, false), do: [:bold], else: []
    {fg, bg, attrs}
  end

  defp add_clip_bounds(child, nil), do: child

  defp add_clip_bounds(child, clip_bounds),
    do: Map.put(child, :clip_bounds, clip_bounds)

  # Copy layout's paint bounds onto style so ElementRenderer (style-only) sees them.
  defp put_paint_bound(style, %{max_paint_width: w} = text_element)
       when is_integer(w) do
    style
    |> Map.put(:max_paint_width, w)
    |> Map.put(:text_overflow, Map.get(text_element, :text_overflow, :ellipsis))
  end

  defp put_paint_bound(style, _text_element), do: style
end
