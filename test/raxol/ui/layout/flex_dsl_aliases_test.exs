defmodule Raxol.UI.Layout.FlexDslAliasesTest do
  @moduledoc """
  The View DSL flex path must accept the same convenience aliases the
  row/column dialect does: `justify:`/`align:` `:start`/`:end` atoms and
  boolean `wrap:` values. Unmapped aliases silently behave as flex-start /
  wrapping-enabled — layouts look plausibly wrong instead of failing.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.UI.Layout.Engine
  alias Raxol.UI.Layout.FlexItem
  alias Raxol.UI.Layout.Flexbox.Solver
  require Raxol.Core.Renderer.View
  alias Raxol.Core.Renderer.View, as: V

  defp texts_of(tree, dims) do
    tree
    |> Engine.apply_layout(dims)
    |> Enum.filter(&(&1.type == :text))
    |> Enum.sort_by(&{&1.y, &1.x})
  end

  test "justify: :end positions at the main-axis end (alias of :flex_end)" do
    tree = V.row(justify: :end, children: [V.text("aa"), V.text("bb")])
    aliased = texts_of(tree, %{width: 20, height: 3})

    canonical =
      texts_of(
        V.row(style: %{justify_content: :flex_end}, children: [V.text("aa"), V.text("bb")]),
        %{width: 20, height: 3}
      )

    assert Enum.map(aliased, & &1.x) == Enum.map(canonical, & &1.x)
    assert List.last(aliased).x == 18
  end

  test "align: :end positions at the cross-axis end" do
    tree = V.row(align: :end, children: [V.text("aa")])
    [t] = texts_of(tree, %{width: 20, height: 5})
    assert t.y == 4
  end

  test "wrap: false means no wrapping (boolean normalizes to :nowrap)" do
    children = for _ <- 1..4, do: V.text("xx")
    tree =
      Raxol.Core.Renderer.View.Layout.Flex.container(
        direction: :row,
        wrap: false,
        gap: 0,
        children: children
      )
    positioned = texts_of(tree, %{width: 6, height: 5})

    # nowrap: all on one row (overflowing), never a second line
    assert Enum.uniq(Enum.map(positioned, & &1.y)) == [0]
  end

  test "wrap: true wraps (boolean normalizes to :wrap)" do
    children = for _ <- 1..4, do: V.text("xx")
    tree =
      Raxol.Core.Renderer.View.Layout.Flex.container(
        direction: :row,
        wrap: true,
        gap: 0,
        children: children
      )
    positioned = texts_of(tree, %{width: 6, height: 5})

    assert length(Enum.uniq(Enum.map(positioned, & &1.y))) > 1
  end

  test "measure honors style-declared flex basis like layout does" do
    child = %{type: :text, content: "ab", style: %{flex: {0, 1, 30}}}

    flex =
      Raxol.Core.Renderer.View.Layout.Flex.container(
        direction: :row,
        gap: 0,
        children: [child]
      )
    measured = Engine.measure_element(flex, %{x: 0, y: 0, width: 80, height: 5})
    assert measured.width == 30
  end

  property "shrink mode: solved outer sizes exactly fill the container" do
    check all(
            bases <- StreamData.list_of(StreamData.integer(5..30), min_length: 2, max_length: 6),
            deficit <- StreamData.integer(1..15)
          ) do
      items =
        for b <- bases do
          struct!(FlexItem, %{element: %{}, base_size: b, shrink: 1, min_main: 0})
        end

      container = max(Enum.sum(bases) - deficit, length(bases))
      solved = Solver.resolve_flexible_lengths(items, container, :horizontal)
      sizes = Enum.map(solved, & &1.main_size)

      assert Enum.sum(sizes) == container
      assert Enum.all?(sizes, &(&1 >= 0))
    end
  end
end
