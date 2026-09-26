defmodule Raxol.UI.Layout.ViewNodes do
  @moduledoc """
  Layout for the View DSL nodes that are declarations rather than
  primitives (#1129).

  `Raxol.View.Components` builds `input`, `list`, `progress`, `select`,
  `radio_group`, `textarea`, `tabs` and `modal` nodes, and
  `Raxol.Core.Renderer.View` builds `border`, `scroll` and `shadow` nodes,
  as plain data that MCP and the accessibility projection read field by
  field. The layout engine had no clause for any of them, so each drew a
  blank region.

  `lower/1` rewrites a declaration into the text, row, column and box
  primitives the engine lays out and measures, keeping its `:id`. `scroll`
  and `shadow` depend on the space they are given, so they are laid out
  here directly (`process_scroll/3`, `process_shadow/3`), each with a
  matching measure.
  """

  alias Raxol.Core.Defaults
  alias Raxol.UI.Layout.{Engine, StyleInheritance}

  @lowered_types [
    :border,
    :input,
    :list,
    :modal,
    :progress,
    :radio_group,
    :select,
    :tabs,
    :textarea
  ]

  @progress_filled "█"
  @progress_empty "░"
  @dim %{dim: true}

  @doc "Node types `lower/1` rewrites into layout primitives."
  @spec lowered_types() :: [atom()]
  def lowered_types, do: @lowered_types

  @doc """
  Rewrites a declaration node into the primitives that draw it.
  """
  @spec lower(map()) :: map()
  def lower(%{type: :border} = node) do
    border = Map.get(node, :border, :single)

    %{
      type: :box,
      id: Map.get(node, :id),
      title: Map.get(node, :title),
      padding: Map.get(node, :padding, 0),
      style: compact(%{border: border, fg: node[:fg], bg: node[:bg]}),
      children: Map.get(node, :children, [])
    }
  end

  def lower(%{type: :input} = node), do: Map.put(node, :type, :text_input)

  def lower(%{type: :list} = node) do
    style = style_of(node)
    selected = Map.get(node, :selected)

    items =
      node
      |> Map.get(:items, [])
      |> Enum.with_index()
      |> Enum.map(fn {item, index} ->
        item_node(item, item_style(style, index == selected))
      end)

    column(node, items)
  end

  def lower(%{type: :progress} = node) do
    max = Map.get(node, :max, 100)
    value = Map.get(node, :value, 0)
    width = max(Map.get(node, :width) || 20, 0)
    ratio = if is_number(max) and max > 0, do: clamp(value / max), else: 0.0
    filled = round(ratio * width)

    bar =
      String.duplicate(@progress_filled, filled) <>
        String.duplicate(@progress_empty, width - filled)

    text(node, "#{bar} #{round(ratio * 100)}%", style_of(node))
  end

  def lower(%{type: :select} = node) do
    selected = Map.get(node, :selected)

    {label, style} =
      case Enum.find(Map.get(node, :options, []), &option?(&1, selected)) do
        nil ->
          {Map.get(node, :placeholder) || "", Map.merge(style_of(node), @dim)}

        option ->
          {label_of(option), style_of(node)}
      end

    text(node, "[#{label} ▾]", style)
  end

  def lower(%{type: :radio_group} = node) do
    style = style_of(node)
    selected = Map.get(node, :selected)

    options =
      node
      |> Map.get(:options, [])
      |> Enum.map(fn option ->
        mark = if option?(option, selected), do: "(o)", else: "( )"
        text(%{}, "#{mark} #{label_of(option)}", style)
      end)

    column(node, options)
  end

  def lower(%{type: :textarea} = node) do
    rows = max(Map.get(node, :rows) || 5, 1)
    value = Map.get(node, :value) || ""

    {content, text_style} =
      if value == "",
        do: {Map.get(node, :placeholder) || "", @dim},
        else: {value, %{}}

    visible =
      content |> String.split("\n") |> Enum.take(rows) |> Enum.join("\n")

    %{
      type: :box,
      id: Map.get(node, :id),
      style: Map.merge(%{border: :single, height: rows + 2}, style_of(node)),
      children: [text(%{}, visible, text_style)]
    }
  end

  def lower(%{type: :tabs} = node) do
    style = style_of(node)
    active = Map.get(node, :active, 0)
    tabs = Map.get(node, :tabs, [])
    last = length(tabs) - 1

    segments =
      tabs
      |> Enum.with_index()
      |> Enum.flat_map(fn {tab, index} ->
        label = label_of(tab)
        active? = index == active or label == active
        tab_text = text(%{}, " #{label} ", item_style(style, active?))
        if index < last, do: [tab_text, text(%{}, "|", style)], else: [tab_text]
      end)

    %{type: :row, id: Map.get(node, :id), gap: 0, children: segments}
  end

  def lower(%{type: :modal, visible: true} = node) do
    %{
      type: :box,
      id: Map.get(node, :id),
      title: Map.get(node, :title),
      padding: 1,
      style: Map.merge(%{border: :single}, style_of(node)),
      children: content_children(Map.get(node, :content))
    }
  end

  # A hidden modal draws and occupies nothing.
  def lower(%{type: :modal} = node), do: column(node, [])

  @doc """
  Lays out a `scroll` node: its children in a `:viewport`-sized window
  (the given space when unset), shifted by `:offset` and clipped to the
  window, with a vertical scrollbar in the last column when `:scrollbars`
  is on and the content is taller than the window.
  """
  @spec process_scroll(map(), Engine.space(), [Engine.positioned_element()]) ::
          [Engine.positioned_element()]
  def process_scroll(node, space, acc) do
    {width, height} = viewport_size(node, space)
    {_offset_x, offset_y} = offset = offset(node)
    content = scroll_content(node)

    content_height =
      Engine.measure_element(content, %{space | width: width}).height

    scrollbar? = scrollbar?(node, width, height, content_height)

    window = %{
      space
      | width: width - if(scrollbar?, do: 1, else: 0),
        height: height
    }

    elements =
      content
      |> Engine.process_element(
        scrolled_space(window, offset, content_height),
        []
      )
      |> Engine.apply_container_overflow(%{style: %{overflow: :hidden}}, window)

    scrollbar =
      if scrollbar?,
        do: [scrollbar(space.x + width - 1, window, offset_y, content_height)],
        else: []

    elements ++ scrollbar ++ acc
  end

  # The content's space: the window moved up and left by the offset, and
  # tall enough for all of the content.
  defp scrolled_space(window, {offset_x, offset_y}, content_height) do
    %{
      window
      | x: window.x - offset_x,
        y: window.y - offset_y,
        width: window.width + offset_x,
        height: max(content_height, window.height + offset_y)
    }
  end

  @doc "Measures a `scroll` node: its viewport, or its content where unset."
  @spec measure_scroll(map(), map()) :: Engine.measurement()
  def measure_scroll(node, available_space) do
    content = Engine.measure_element(scroll_content(node), available_space)

    case Map.get(node, :viewport) do
      {width, height} ->
        %{width: width || content.width, height: height || content.height}

      _ ->
        content
    end
  end

  @doc """
  Lays out a `shadow` node: its children at their measured size, over a
  block of the shadow colour the same size, offset by `:offset`.
  """
  @spec process_shadow(map(), Engine.space(), [Engine.positioned_element()]) ::
          [Engine.positioned_element()]
  def process_shadow(node, space, acc) do
    {dx, dy} = shadow_offset(node)
    content = column(%{}, Map.get(node, :children, []))

    available = %{
      space
      | width: max(space.width - dx, 0),
        height: max(space.height - dy, 0)
    }

    size = Engine.measure_element(content, available)
    width = min(size.width, available.width)
    height = min(size.height, available.height)
    color = Map.get(node, :color, :black)

    shade =
      if width > 0 and height > 0 do
        [
          %{
            type: :box,
            x: space.x + dx,
            y: space.y + dy,
            width: width,
            height: height,
            style: %{bg: color},
            attrs: %{border: :none, padding: 0, style: %{bg: color}}
          }
        ]
      else
        []
      end

    shade ++
      Engine.process_element(
        content,
        %{available | width: width, height: height},
        []
      ) ++
      acc
  end

  @doc "Measures a `shadow` node: its children plus the shadow offset."
  @spec measure_shadow(map(), map()) :: Engine.measurement()
  def measure_shadow(node, available_space) do
    {dx, dy} = shadow_offset(node)

    size =
      Engine.measure_element(
        column(%{}, Map.get(node, :children, [])),
        available_space
      )

    %{width: size.width + dx, height: size.height + dy}
  end

  # --- scroll --------------------------------------------------------------

  defp scroll_content(node), do: column(%{}, Map.get(node, :children, []), node)

  defp viewport_size(node, space) do
    case Map.get(node, :viewport) do
      {width, height} ->
        {min(width || space.width, space.width),
         min(height || space.height, space.height)}

      _ ->
        {space.width, space.height}
    end
  end

  defp offset(node) do
    case Map.get(node, :offset) do
      {x, y} when is_integer(x) and is_integer(y) -> {max(x, 0), max(y, 0)}
      _ -> {0, 0}
    end
  end

  defp scrollbar?(node, width, height, content_height) do
    Map.get(node, :scrollbars, true) and content_height > height and width > 1
  end

  # A one-column track with a thumb sized and placed by how much of the
  # content the window shows.
  defp scrollbar(x, %{y: y, height: height}, offset_y, content_height) do
    thumb = max(div(height * height, content_height), 1)
    travel = max(content_height - height, 1)
    thumb_top = min(div(offset_y * (height - thumb), travel), height - thumb)

    track =
      Enum.map_join(0..(height - 1), "\n", fn row ->
        if row >= thumb_top and row < thumb_top + thumb, do: "█", else: "│"
      end)

    %{
      type: :text,
      x: x,
      y: y,
      width: 1,
      height: height,
      text: track,
      style: %{},
      attrs: %{component_type: :scrollbar}
    }
  end

  # --- shadow --------------------------------------------------------------

  defp shadow_offset(node) do
    case Map.get(node, :offset) do
      {x, y} when is_integer(x) and is_integer(y) -> {max(x, 0), max(y, 0)}
      _ -> {1, 1}
    end
  end

  # --- building blocks -----------------------------------------------------

  # A gapless column (the engine's literal :column defaults its gap to 1).
  defp column(node, children, style_source \\ %{}) do
    %{
      type: :column,
      id: Map.get(node, :id),
      gap: 0,
      style: style_of(style_source),
      children: children
    }
  end

  defp text(node, content, style) do
    %{type: :text, id: Map.get(node, :id), content: content, style: style}
  end

  defp item_node(%{type: _} = element, _style), do: element
  defp item_node(item, style), do: text(%{}, label_of(item), style)

  defp item_style(style, true), do: Map.merge(style, Defaults.selected_style())
  defp item_style(style, false), do: style

  defp content_children(nil), do: []

  defp content_children(content) when is_binary(content),
    do: [text(%{}, content, %{})]

  defp content_children(content) when is_list(content), do: content
  defp content_children(content), do: [content]

  defp option?(_option, nil), do: false

  defp option?(option, selected) do
    option == selected or option_value(option) == selected or
      label_of(option) == selected
  end

  defp option_value({_label, value}), do: value
  defp option_value(%{value: value}), do: value
  defp option_value(option), do: option

  defp label_of({label, _value}), do: label_of(label)
  defp label_of(%{label: label}), do: label_of(label)
  defp label_of(label) when is_binary(label), do: label

  defp label_of(label) do
    if String.Chars.impl_for(label), do: to_string(label), else: inspect(label)
  end

  # Top-level `:fg`/`:bg` are shorthands for the same style keys; an
  # explicit style entry wins.
  defp style_of(node) do
    node
    |> Map.take([:fg, :bg])
    |> compact()
    |> Map.merge(StyleInheritance.ensure_style_map(Map.get(node, :style)))
  end

  defp compact(map),
    do: map |> Enum.reject(fn {_key, value} -> is_nil(value) end) |> Map.new()

  defp clamp(ratio), do: ratio |> max(0.0) |> min(1.0)
end
