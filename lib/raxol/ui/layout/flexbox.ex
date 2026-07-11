defmodule Raxol.UI.Layout.Flexbox do
  @moduledoc """
  Modern Flexbox layout system for Raxol UI components.

  This module provides CSS Flexbox-compatible layout calculations with support for:
  - Flex direction (row, column — reverse directions are intentionally unsupported)
  - Justify content (flex-start, flex-end, center, space-between, space-around, space-evenly)
  - Align items (flex-start, flex-end, center, stretch — baseline is intentionally unsupported)
  - Align content (flex-start, flex-end, center, space-between, space-around)
  - Flex wrapping (nowrap, wrap; wrap-reverse behaves as wrap)
  - Flex grow, shrink, and basis via the section-9.7 solver (`Flexbox.Solver`)
  - Gap properties
  - Order property for reordering items

  See `docs/core/LAYOUT.md` for the property reference and the list of
  intentional CSS divergences.

  ## Example Usage

      # Flexbox container
      %{
        type: :flex,
        attrs: %{
          flex_direction: :row,
          justify_content: :space_between,
          align_items: :center,
          gap: 10,
          padding: %{top: 5, right: 10, bottom: 5, left: 10}
        },
        children: [
          %{type: :text, attrs: %{content: "Item 1", flex: %{grow: 1}}},
          %{type: :text, attrs: %{content: "Item 2", flex: %{shrink: 0, basis: 100}}},
          %{type: :text, attrs: %{content: "Item 3", order: -1}}
        ]
      }
  """

  @default_gap 0
  @default_padding 0
  @default_order 0

  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.Layout.FlexItem
  alias Raxol.UI.Layout.Flexbox.{Calculator, Positioner, Solver, Wrapper}
  alias Raxol.UI.Layout.LayoutUtils
  alias Raxol.UI.Layout.MinContent


  @doc """
  Processes a flex container, calculating layout for it and its children.
  """
  def process_flex(%{type: :flex, children: children} = flex, space, acc)
      when is_list(children) do
    attrs = Map.get(flex, :attrs, %{})
    flex_props = parse_flex_properties(attrs)
    content_space = apply_padding(space, flex_props.padding)
    children = inherit_styles(flex, children)
    sorted_children = sort_children_by_order(children)

    positioned_children =
      calculate_flex_layout(sorted_children, content_space, flex_props)

    elements =
      Enum.flat_map(positioned_children, fn {child, child_space} ->
        Engine.process_element(child, child_space, [])
      end)

    elements ++ acc
  end

  def process_flex(_, _space, acc), do: acc

  @doc """
  Measures the space needed by a flex container.
  """
  def measure_flex(%{type: :flex, children: children} = flex, available_space)
      when is_list(children) do
    attrs = Map.get(flex, :attrs, %{})
    flex_props = parse_flex_properties(attrs)
    content_space = apply_padding(available_space, flex_props.padding)

    child_dimensions =
      Enum.map(children, fn child ->
        measure_flex_child(child, content_space, flex_props)
      end)

    container_size =
      Calculator.calculate_container_size(
        child_dimensions,
        flex_props,
        content_space
      )

    %{
      width:
        container_size.width + flex_props.padding.left +
          flex_props.padding.right,
      height:
        container_size.height + flex_props.padding.top +
          flex_props.padding.bottom
    }
  end

  def measure_flex(_, _available_space), do: %{width: 0, height: 0}

  # NOTE (flex rework N11 / proposal Phase D pre-work): the legacy
  # `new/1` + `render/1` + `calculate_layout/1` API (struct type :flexbox,
  # never dispatched by the engine) was deleted here — verified zero
  # production callers (longcat recon 2026-07-11).

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_flex_properties(attrs) do
    %{
      flex_direction: Map.get(attrs, :flex_direction, :row),
      justify_content: Map.get(attrs, :justify_content, :flex_start),
      align_items: Map.get(attrs, :align_items, :stretch),
      align_content: Map.get(attrs, :align_content, :stretch),
      flex_wrap: Map.get(attrs, :flex_wrap, :nowrap),
      gap: parse_gap(Map.get(attrs, :gap, @default_gap)),
      padding: parse_padding(Map.get(attrs, :padding, @default_padding))
    }
  end

  defp parse_gap(gap) when is_integer(gap), do: %{row: gap, column: gap}
  defp parse_gap(%{row: row, column: column}), do: %{row: row, column: column}
  defp parse_gap(_), do: %{row: @default_gap, column: @default_gap}

  defp parse_padding(padding), do: LayoutUtils.parse_padding(padding)

  defp apply_padding(space, padding),
    do: LayoutUtils.apply_padding(space, padding)

  defp sort_children_by_order(children) do
    Enum.sort_by(children, fn child ->
      # attrs may be a keyword list on legacy elements (e.g. labels)
      case Map.get(child, :attrs, %{}) do
        m when is_map(m) -> Map.get(m, :order, @default_order)
        kw when is_list(kw) -> Keyword.get(kw, :order, @default_order)
        _ -> @default_order
      end
    end)
  end

  defp calculate_flex_layout(children, space, flex_props) do
    children_with_dims =
      Enum.map(children, fn child ->
        dims = measure_flex_child(child, space, flex_props)
        flex_attrs = get_flex_attributes(child)
        {child, dims, flex_attrs}
      end)

    {main_axis, cross_axis} = get_axes(flex_props.flex_direction)

    case flex_props.flex_wrap do
      :nowrap ->
        calculate_single_line_layout(
          children_with_dims,
          space,
          flex_props,
          main_axis,
          cross_axis
        )

      _ ->
        Wrapper.calculate_multi_line_layout(
          children_with_dims,
          space,
          flex_props,
          main_axis,
          cross_axis
        )
    end
  end

  @doc false
  # Section 9.7-correct single-line layout on FlexItem + Solver. Public
  # (doc: false) so Wrapper's per-line layout shares the same code path.
  #
  # Pipeline: resolve items -> solve main sizes -> distribute main-axis
  # auto margins -> position OUTER boxes (margins included) via Positioner
  # -> derive each child's inner space (margins subtracted, cross auto
  # margins and the stretch guard applied).
  def calculate_single_line_layout(
        children_with_dims,
        space,
        flex_props,
        main_axis,
        cross_axis
      ) do
    container_main = Positioner.get_dimension(space, main_axis)
    container_cross = Positioner.get_dimension(space, cross_axis)
    gap_size = Positioner.get_gap_size(flex_props.gap, main_axis)
    total_gaps = gap_size * max(0, length(children_with_dims) - 1)

    container_dims = %{
      width: Map.get(space, :width),
      height: Map.get(space, :height)
    }

    resolved =
      Enum.map(children_with_dims, fn {child, dims, _legacy_flex} ->
        # Automatic minimum size (spec min-width:auto = min-content, B3):
        # inline axis uses MinContent; block axis uses the measured content
        # size (min-content block size of unscrollable content). Items never
        # shrink below it — overflow clips instead of content vanishing.
        auto_min = fn ->
          case main_axis do
            :horizontal -> MinContent.width(child)
            :vertical -> Positioner.get_dimension(dims, :vertical)
          end
        end

        item =
          FlexItem.resolve(
            child,
            main_axis,
            container_dims,
            fn -> Positioner.get_dimension(dims, main_axis) end,
            auto_min
          )

        {item, Positioner.get_dimension(dims, cross_axis)}
      end)

    solved =
      resolved
      |> Enum.map(fn {item, _mc} -> item end)
      |> Solver.resolve_flexible_lengths(container_main - total_gaps, main_axis)

    free =
      container_main - total_gaps -
        Enum.reduce(solved, 0, fn item, acc ->
          acc + FlexItem.outer_main(item, item.main_size, main_axis)
        end)

    solved = distribute_auto_main_margins(solved, free, main_axis)

    entries =
      solved
      |> Enum.zip(Enum.map(resolved, fn {_i, mc} -> mc end))
      |> Enum.map(&build_line_entry(&1, flex_props, main_axis, container_cross))

    positioned =
      entries
      |> Positioner.position_main_axis(space, flex_props, main_axis)
      |> Positioner.position_cross_axis(space, flex_props, cross_axis)

    Enum.map(positioned, fn {entry, outer_space} ->
      inner_space(entry, outer_space, main_axis, cross_axis)
    end)
  end

  # Build the {pseudo_child, outer_dims, pseudo_flex} tuple Positioner
  # expects; the pseudo child carries everything inner_space/2 needs.
  defp build_line_entry({item, measured_cross}, flex_props, main_axis, container_cross) do
    cross = FlexItem.clamp_main(cross_clamp_item(item), item.cross_size || measured_cross)
    {cs, ce} = FlexItem.cross_margins(item, main_axis)
    {ms, me} = FlexItem.main_margins(item, main_axis)

    cross_autos = Enum.count([cs, ce], &(&1 == :auto))
    container_align = flex_props.align_items
    requested_align = item.align_self || container_align

    effective_align =
      cond do
        # auto cross margins absorb free space; align-self is ignored (spec)
        cross_autos > 0 -> :flex_start
        # definite cross size under stretch positions like flex-start (guard)
        requested_align == :stretch and item.cross_size != nil -> :flex_start
        true -> requested_align
      end

    outer_cross =
      if cross_autos > 0 or effective_align == :stretch do
        # consume the whole line so inner resolution decides placement
        max(container_cross, cross + FlexItem.margin_int(cs) + FlexItem.margin_int(ce))
      else
        cross + FlexItem.margin_int(cs) + FlexItem.margin_int(ce)
      end

    outer_main = FlexItem.margin_int(ms) + item.main_size + FlexItem.margin_int(me)

    entry = %{
      __flex_entry__: true,
      child: item.element,
      item: item,
      cross: cross,
      effective_align: effective_align
    }

    dims =
      case main_axis do
        :horizontal -> %{width: outer_main, height: outer_cross}
        :vertical -> %{width: outer_cross, height: outer_main}
      end

    {entry, dims, %{align_self: effective_align}}
  end

  # Cross clamping reuses FlexItem.clamp_main by lending it the cross bounds.
  defp cross_clamp_item(item) do
    %{item | min_main: item.min_cross, max_main: item.max_cross}
  end

  # Turn the positioned OUTER box into the child's inner space.
  defp inner_space(entry, outer_space, main_axis, cross_axis) do
    item = entry.item
    {ms, _me} = FlexItem.main_margins(item, main_axis)
    {cs, ce} = FlexItem.cross_margins(item, main_axis)

    outer_cross = Positioner.get_dimension(outer_space, cross_axis)

    inner_cross =
      if entry.effective_align == :stretch do
        FlexItem.clamp_main(
          cross_clamp_item(item),
          max(0, outer_cross - FlexItem.margin_int(cs) - FlexItem.margin_int(ce))
        )
      else
        entry.cross
      end

    cross_free =
      max(0, outer_cross - inner_cross - FlexItem.margin_int(cs) - FlexItem.margin_int(ce))

    cross_start_offset =
      case {cs, ce} do
        {:auto, :auto} -> div(cross_free, 2)
        {:auto, _} -> cross_free
        {_, _} -> FlexItem.margin_int(cs)
      end

    geometry =
      case main_axis do
        :horizontal ->
          %{
            x: outer_space.x + FlexItem.margin_int(ms),
            y: outer_space.y + cross_start_offset,
            width: item.main_size,
            height: inner_cross
          }

        :vertical ->
          %{
            x: outer_space.x + cross_start_offset,
            y: outer_space.y + FlexItem.margin_int(ms),
            width: inner_cross,
            height: item.main_size
          }
      end

    {entry.child, Map.merge(outer_space, geometry)}
  end

  # Main-axis auto margins absorb positive free space before justify-content.
  defp distribute_auto_main_margins(items, free, main_axis) when free > 0 do
    auto_count =
      Enum.reduce(items, 0, fn item, acc ->
        {ms, me} = FlexItem.main_margins(item, main_axis)
        acc + Enum.count([ms, me], &(&1 == :auto))
      end)

    if auto_count == 0 do
      items
    else
      share = div(free, auto_count)
      remainder = rem(free, auto_count)

      {out, _} =
        Enum.map_reduce(items, {0, remainder}, fn item, {seen, rem_left} ->
          {new_margin, seen, rem_left} =
            resolve_main_autos(item.margin, main_axis, share, seen, rem_left)

          {%{item | margin: new_margin}, {seen, rem_left}}
        end)

      out
    end
  end

  defp distribute_auto_main_margins(items, _free, main_axis) do
    # No positive free space: auto main margins resolve to 0 (spec).
    Enum.map(items, fn item ->
      {t, r, b, l} = item.margin

      margin =
        case main_axis do
          :horizontal -> {t, zero_auto(r), b, zero_auto(l)}
          :vertical -> {zero_auto(t), r, zero_auto(b), l}
        end

      %{item | margin: margin}
    end)
  end

  defp resolve_main_autos({t, r, b, l}, :horizontal, share, seen, rem_left) do
    {l, seen, rem_left} = take_auto(l, share, seen, rem_left)
    {r, seen, rem_left} = take_auto(r, share, seen, rem_left)
    {{t, r, b, l}, seen, rem_left}
  end

  defp resolve_main_autos({t, r, b, l}, :vertical, share, seen, rem_left) do
    {t, seen, rem_left} = take_auto(t, share, seen, rem_left)
    {b, seen, rem_left} = take_auto(b, share, seen, rem_left)
    {{t, r, b, l}, seen, rem_left}
  end

  defp take_auto(:auto, share, seen, rem_left) do
    extra = if rem_left > 0, do: 1, else: 0
    {share + extra, seen + 1, rem_left - extra}
  end

  defp take_auto(v, _share, seen, rem_left), do: {v, seen, rem_left}

  defp zero_auto(:auto), do: 0
  defp zero_auto(v), do: v

  defp measure_flex_child(child, available_space, flex_props) do
    child_attrs = attrs_map(child)
    flex_attrs = Map.get(child_attrs, :flex, %{})
    flex_basis = Map.get(flex_attrs, :basis, :auto)

    child_space =
      get_child_space(flex_basis, available_space, flex_props.flex_direction)

    Engine.measure_element(child, child_space)
  end

  # attrs may be a keyword list on legacy elements
  defp attrs_map(child) do
    case Map.get(child, :attrs, %{}) do
      m when is_map(m) -> m
      kw when is_list(kw) -> Map.new(kw)
      _ -> %{}
    end
  end

  defp get_child_space(:auto, available_space, _flex_direction),
    do: available_space

  defp get_child_space(flex_basis, available_space, flex_direction) do
    case get_main_axis(flex_direction) do
      :horizontal -> %{available_space | width: flex_basis}
      :vertical -> %{available_space | height: flex_basis}
    end
  end

  defp get_flex_attributes(child) do
    child_attrs = attrs_map(child)
    flex = Map.get(child_attrs, :flex, %{})

    %{
      grow: Map.get(flex, :grow, 0),
      shrink: Map.get(flex, :shrink, 1),
      basis: Map.get(flex, :basis, :auto),
      align_self: Map.get(child_attrs, :align_self, nil)
    }
  end

  defp get_axes(:row), do: {:horizontal, :vertical}
  defp get_axes(:row_reverse), do: {:horizontal, :vertical}
  defp get_axes(:column), do: {:vertical, :horizontal}
  defp get_axes(:column_reverse), do: {:vertical, :horizontal}

  defp get_main_axis(direction) when direction in [:row, :row_reverse],
    do: :horizontal

  defp get_main_axis(direction) when direction in [:column, :column_reverse],
    do: :vertical

  defp inherit_styles(parent, children) do
    Raxol.UI.Layout.StyleInheritance.inherit_styles(parent, children)
  end
end
