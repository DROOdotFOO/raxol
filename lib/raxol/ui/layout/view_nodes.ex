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

  `lower/2` rewrites a declaration into the text, row, column and box
  primitives the engine lays out and measures, keeping its `:id`. `scroll`
  and `shadow` depend on the space they are given, so they are laid out
  here directly (`process_scroll/3`, `process_shadow/3`), each with a
  matching measure.
  """

  alias Raxol.Core.Defaults
  alias Raxol.Core.Runtime.Log
  alias Raxol.UI.Layout.{Engine, StyleInheritance}
  alias Raxol.UI.TextMeasure

  @type lowered_type ::
          :border
          | :input
          | :list
          | :modal
          | :progress
          | :radio_group
          | :select
          | :tabs
          | :textarea

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
  @progress_default_width 20
  @dim %{dim: true}

  @doc "Node types `lower/2` rewrites into layout primitives."
  @spec lowered_types() :: [lowered_type(), ...]
  def lowered_types, do: @lowered_types

  @doc """
  Rewrites a declaration node into the primitives that draw it, in the
  space it is laid out in.
  """
  @spec lower(%{:type => lowered_type(), optional(atom()) => term()}, map()) ::
          %{
            :type => :box | :column | :row | :text | :text_input,
            optional(atom()) => term()
          }
  def lower(%{type: :border} = node, _space) do
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

  def lower(%{type: :input} = node, _space),
    do: Map.put(node, :type, :text_input)

  def lower(%{type: :list} = node, _space) do
    style = style_of(node)
    selected = Map.get(node, :selected)

    items = collection(node, :items)

    rows =
      items
      |> Enum.with_index()
      |> Enum.flat_map(fn {item, index} ->
        item_node(item, item_style(style, index == selected))
      end)

    log_unlabelled(node, length(items) - length(rows))
    column(node, rows)
  end

  # A `value` or `max` that is not a number counts as 0 (a `max` of 0 or
  # less draws an empty bar). The bar is `width` cells (a non-negative
  # integer; a float is truncated, anything else is the default), clamped
  # so the bar and its label fit the space's width.
  def lower(%{type: :progress} = node, space) do
    max = number_or_zero(Map.get(node, :max, 100))
    value = number_or_zero(Map.get(node, :value, 0))
    ratio = if max > 0, do: clamp(value / max), else: 0.0
    label = " #{round(ratio * 100)}%"
    width = progress_width(Map.get(node, :width), space, label)
    filled = round(ratio * width)

    bar =
      String.duplicate(@progress_filled, filled) <>
        String.duplicate(@progress_empty, width - filled)

    text(node, bar <> label, style_of(node))
  end

  def lower(%{type: :select} = node, _space) do
    selected = Map.get(node, :selected)

    {label, style} =
      case Enum.find(collection(node, :options), &option?(&1, selected)) do
        nil ->
          placeholder(node)

        option ->
          case label_of(option) do
            nil ->
              log_unlabelled(node, 1)
              placeholder(node)

            label ->
              {label, style_of(node)}
          end
      end

    text(node, "[#{label} ▾]", style)
  end

  def lower(%{type: :radio_group} = node, _space) do
    style = style_of(node)
    selected = Map.get(node, :selected)
    options = collection(node, :options)

    rows =
      Enum.flat_map(options, fn option ->
        case label_of(option) do
          nil ->
            []

          label ->
            mark = if option?(option, selected), do: "(o)", else: "( )"
            [text(%{}, "#{mark} #{label}", style)]
        end
      end)

    log_unlabelled(node, length(options) - length(rows))
    column(node, rows)
  end

  def lower(%{type: :textarea} = node, _space) do
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

  def lower(%{type: :tabs} = node, _space) do
    style = style_of(node)
    active = Map.get(node, :active, 0)
    tabs = collection(node, :tabs)

    labelled =
      tabs
      |> Enum.with_index()
      |> Enum.flat_map(fn {tab, index} ->
        case label_of(tab) do
          nil -> []
          label -> [{label, index}]
        end
      end)

    log_unlabelled(node, length(tabs) - length(labelled))
    last = length(labelled) - 1

    segments =
      labelled
      |> Enum.with_index()
      |> Enum.flat_map(fn {{label, index}, position} ->
        active? = index == active or label == active
        tab_text = text(%{}, " #{label} ", item_style(style, active?))

        if position < last,
          do: [tab_text, text(%{}, "|", style)],
          else: [tab_text]
      end)

    %{type: :row, id: Map.get(node, :id), gap: 0, children: segments}
  end

  def lower(%{type: :modal, visible: true} = node, _space) do
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
  def lower(%{type: :modal} = node, _space), do: column(node, [])

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
  Lays out a `shadow` node: its children at their measured size, and the
  part of a same-sized block of the shadow colour, offset by `:offset`,
  that they do not cover (a strip to their right and one below them).
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

    # The block at {dx, dy} less the content's rectangle: the columns past
    # the content's right edge, then the rows below it under the content.
    right_x = max(width, dx)
    bottom_y = max(height, dy)

    shade =
      [
        {right_x, dy, dx + width - right_x, height},
        {dx, bottom_y, right_x - dx, dy + height - bottom_y}
      ]
      |> Enum.filter(fn {_x, _y, w, h} -> w > 0 and h > 0 end)
      |> Enum.map(fn {x, y, w, h} ->
        %{
          type: :box,
          x: space.x + x,
          y: space.y + y,
          width: w,
          height: h,
          style: %{bg: color},
          attrs: %{border: :none, padding: 0, style: %{bg: color}}
        }
      end)

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

  defp item_node(%{type: _} = element, _style), do: [element]

  defp item_node(item, style) do
    case label_of(item) do
      nil -> []
      label -> [text(%{}, label, style)]
    end
  end

  defp item_style(style, true), do: Map.merge(style, Defaults.selected_style())
  defp item_style(style, false), do: style

  # The builders store what they are given, so an unset collection is nil.
  defp collection(node, key), do: Map.get(node, key) || []

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

  defp option_value(option) when is_list(option) do
    if Keyword.keyword?(option), do: Keyword.get(option, :value), else: option
  end

  defp option_value(option), do: option

  # An item's text: a string, the label of a `{label, value}` pair, a
  # `%{label: ...}` map or a `[label: ...]` keyword list, or anything else
  # with a `String.Chars` implementation. Anything else (a record, any other
  # list) has no label and is not drawn: its `inspect/1` form would put
  # every field, private ones included, on the screen, and `to_string/1` of
  # a list raises with the list in its message.
  defp label_of({label, _value}), do: label_of(label)
  defp label_of(%{label: label}), do: label_of(label)
  defp label_of(label) when is_binary(label), do: label

  defp label_of(item) when is_list(item) do
    with true <- Keyword.keyword?(item),
         {:ok, label} <- Keyword.fetch(item, :label) do
      label_of(label)
    else
      _no_label -> nil
    end
  end

  defp label_of(label) do
    if String.Chars.impl_for(label), do: to_string(label)
  end

  # One debug line per node, naming neither the items nor their contents.
  defp log_unlabelled(_node, 0), do: :ok

  defp log_unlabelled(node, count) do
    Log.debug(
      "ViewNodes: #{node.type} skipped #{count} item(s) with no label " <>
        "(not a string, {label, value}, %{label: ...}, [label: ...] " <>
        "or String.Chars)"
    )
  end

  defp placeholder(node),
    do: {Map.get(node, :placeholder) || "", Map.merge(style_of(node), @dim)}

  defp number_or_zero(number) when is_number(number), do: number
  defp number_or_zero(_other), do: 0

  defp progress_width(width, space, label) do
    requested =
      case width do
        width when is_integer(width) and width >= 0 -> width
        width when is_float(width) and width >= 0 -> trunc(width)
        _other -> @progress_default_width
      end

    case Map.get(space, :width) do
      available when is_integer(available) ->
        min(requested, max(available - TextMeasure.display_width(label), 0))

      _unknown ->
        requested
    end
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
