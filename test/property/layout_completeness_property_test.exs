defmodule Raxol.Property.LayoutCompletenessTest do
  @moduledoc """
  Property: every text leaf survives the layout pass.

  For any well-formed view tree, every string passed to a `:text` element
  must appear (with at least the same multiplicity) in the positioned
  elements that `Raxol.UI.Layout.Engine.apply_layout/3` returns.

  This was the shape of three real bugs that lived in the playground for
  weeks before our regression test caught them:

    * Dynamic-children dropped when the `column(opts, do: var)` form
      matched `def column/1` instead of `defmacro column/2`. Children
      went in, an empty container came out.
    * Chart widget types (`:line_chart`, `:bar_chart`, `:scatter_chart`,
      `:heatmap`) had no clause in `LayoutEngine.process_element/3` and
      hit the catch-all, which logs a warning and returns the accumulator
      unchanged. The chart's text children disappeared.
    * `:text_input` had a clause that required `:attrs` but the new-DSL
      constructor emitted top-level `:value` / `:placeholder`. Mismatch,
      catch-all, dropped.

  All three bugs share the same observable shape: a tree containing N
  text strings produced fewer than N positioned text elements. This
  property locks that shape down going forward.

  The chart-shaped generator branch is deliberate: without it the property
  would not catch a regression that re-introduced the chart bug.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  @moduletag :property

  alias Raxol.UI.Layout.Engine

  @max_depth 3
  @max_children 4
  @screen %{width: 80, height: 24}

  # Chart-style widget types that wrap a box with positioned text children.
  # The layout engine must treat these as box-shaped or the children get
  # dropped. See `LayoutEngine.process_element/3`.
  @chart_types [:line_chart, :bar_chart, :scatter_chart, :heatmap]

  # =========================================================================
  # The property
  # =========================================================================

  describe "every text content survives layout" do
    property "all input text strings appear in positioned-elements output" do
      check all(view <- view_tree(), max_runs: 200) do
        input_texts = collect_text_content(view)

        positioned =
          Engine.apply_layout(view, @screen)

        output_texts =
          positioned
          |> Enum.filter(&(Map.get(&1, :type) == :text))
          |> Enum.map(&Map.get(&1, :text))

        assert multiset_subset?(input_texts, output_texts),
               """
               Layout dropped text content.

               Input texts (#{length(input_texts)}): #{inspect(input_texts)}
               Output texts (#{length(output_texts)}): #{inspect(output_texts)}
               Missing: #{inspect(multiset_difference(input_texts, output_texts))}

               View tree:
               #{inspect(view, pretty: true, limit: :infinity)}
               """
      end
    end

    property "chart-shaped widgets preserve their positioned text children" do
      check all(chart <- chart_widget(), max_runs: 100) do
        positioned = Engine.apply_layout(chart, @screen)

        input_texts =
          chart.children |> Enum.map(& &1.content) |> Enum.reject(&(&1 == ""))

        output_texts =
          positioned
          |> Enum.filter(&(Map.get(&1, :type) == :text))
          |> Enum.map(&Map.get(&1, :text))

        assert multiset_subset?(input_texts, output_texts),
               """
               Chart-shaped widget (#{chart.type}) dropped text children.

               Input: #{inspect(input_texts)}
               Output: #{inspect(output_texts)}

               Chart:
               #{inspect(chart, pretty: true, limit: :infinity)}
               """
      end
    end

    property "position offsets on text are applied additively" do
      check all(
              %{x: ox, y: oy} = base_space <- space_gen(),
              dx <- integer(0..20),
              dy <- integer(0..10),
              content <- printable_content()
            ) do
        element = %{
          type: :text,
          content: content,
          style: %{position: {dx, dy}}
        }

        [positioned] = Engine.process_element(element, base_space, [])

        assert positioned.x == ox + dx
        assert positioned.y == oy + dy
        assert positioned.text == content
      end
    end
  end

  # =========================================================================
  # Generators
  # =========================================================================

  # Recursive view-tree generator: text leaves, flex containers, boxes,
  # and chart-shaped wrappers. Depth-bounded so generation is finite.
  defp view_tree, do: view_tree(@max_depth)

  defp view_tree(0), do: text_leaf()

  defp view_tree(depth) do
    one_of([
      text_leaf(),
      flex_container(depth),
      box_container(depth),
      chart_widget()
    ])
  end

  # A text leaf with a non-empty printable string. The minimum-length-2
  # constraint avoids the empty-string trivial case (the property holds
  # for "" but says nothing useful).
  defp text_leaf do
    gen all(content <- printable_content()) do
      %{type: :text, content: content, style: []}
    end
  end

  defp printable_content do
    # Restrict to alphanumeric + space so the visible-cells check in the
    # render test would actually count these as content. Avoids empty
    # strings and pathological all-whitespace cases.
    gen all(
          s <-
            string([?a..?z, ?A..?Z, ?0..?9, ?\s], min_length: 2, max_length: 10),
          String.trim(s) != ""
        ) do
      s
    end
  end

  defp flex_container(depth) do
    gen all(
          direction <- member_of([:column, :row]),
          children <- list_of(view_tree(depth - 1), min_length: 1, max_length: @max_children),
          gap <- integer(0..2)
        ) do
      %{
        type: :flex,
        direction: direction,
        children: children,
        gap: gap,
        style: %{},
        align: :stretch,
        justify: :start
      }
    end
  end

  defp box_container(depth) do
    gen all(
          children <- list_of(view_tree(depth - 1), min_length: 1, max_length: @max_children),
          padding <- integer(0..1),
          border <- member_of([:none, :single])
        ) do
      %{
        type: :box,
        children: children,
        style: %{},
        padding: padding,
        border: border
      }
    end
  end

  # The chart-shaped widget: a parent with one of the chart types, holding
  # text children that carry their own `position: {x, y}` style. This is
  # the exact shape `Raxol.UI.Charts.ViewBridge.cells_to_view/2` emits.
  defp chart_widget do
    gen all(
          type <- member_of(@chart_types),
          children <-
            list_of(positioned_text(), min_length: 1, max_length: 6)
        ) do
      %{type: type, children: children}
    end
  end

  defp positioned_text do
    gen all(
          content <- printable_content(),
          x <- integer(0..40),
          y <- integer(0..15)
        ) do
      %{type: :text, content: content, style: %{position: {x, y}}}
    end
  end

  defp space_gen do
    gen all(
          x <- integer(0..40),
          y <- integer(0..15),
          width <- integer(20..60),
          height <- integer(10..20)
        ) do
      %{x: x, y: y, width: width, height: height}
    end
  end

  # =========================================================================
  # Helpers
  # =========================================================================

  # Walks the tree and collects the `:content` field of every `:text`
  # element. Order is not preserved; multiplicity is.
  defp collect_text_content(%{type: :text, content: content}) when is_binary(content),
    do: [content]

  defp collect_text_content(%{children: children}) when is_list(children),
    do: Enum.flat_map(children, &collect_text_content/1)

  defp collect_text_content(%{children: %{} = single_child}),
    do: collect_text_content(single_child)

  defp collect_text_content(_), do: []

  # `a` is a multiset subset of `b` iff every element of `a` appears at
  # least as many times in `b` as in `a`.
  defp multiset_subset?(a, b) do
    counts_a = Enum.frequencies(a)
    counts_b = Enum.frequencies(b)

    Enum.all?(counts_a, fn {value, count_a} ->
      Map.get(counts_b, value, 0) >= count_a
    end)
  end

  # Returns the list of values in `a` (with multiplicity) that are missing
  # from `b`. Used only for failure messages.
  defp multiset_difference(a, b) do
    counts_a = Enum.frequencies(a)
    counts_b = Enum.frequencies(b)

    Enum.flat_map(counts_a, fn {value, count_a} ->
      missing = count_a - Map.get(counts_b, value, 0)
      if missing > 0, do: List.duplicate(value, missing), else: []
    end)
  end
end
