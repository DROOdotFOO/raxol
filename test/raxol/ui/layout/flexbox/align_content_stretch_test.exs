defmodule Raxol.UI.Layout.Flexbox.AlignContentStretchTest do
  @moduledoc """
  align-content: :stretch for wrapped flex lines (flex rework N12 residual).
  Lines share the container's free cross space (largest remainder) and
  stretch-aligned items grow with their line.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.Layout.Engine

  defp wrap_tree(align_content) do
    %{
      type: :flex,
      attrs: %{
        flex_direction: :row,
        flex_wrap: :wrap,
        align_content: align_content,
        gap: 0
      },
      children: [
        %{type: :box, width: 4, height: 2, children: []},
        %{type: :box, width: 4, height: 2, children: []},
        # third box forces a second line in a 10-wide container (4+4+4 > 10)
        %{type: :box, width: 4, height: 2, children: []}
      ]
    }
  end

  defp boxes(tree, dims) do
    Engine.apply_layout(tree, dims)
    |> Enum.filter(&(&1.type == :box))
    |> Enum.sort_by(&{&1.y, &1.x})
  end

  test "stretch distributes free cross space into the lines" do
    result = boxes(wrap_tree(:stretch), %{width: 10, height: 10})

    # two lines, natural heights 2+2, free 6 -> each line becomes 5;
    # boxes have explicit height 2 so they keep it (stretch guard), but
    # the second line STARTS at y=5, proving the line itself stretched.
    assert [%{y: 0}, %{y: 0}, %{y: 5}] = result
  end

  test "flex-start keeps natural line heights (control)" do
    result = boxes(wrap_tree(:flex_start), %{width: 10, height: 10})
    assert [%{y: 0}, %{y: 0}, %{y: 2}] = result
  end

  test "stretch with no free space behaves like flex-start" do
    result = boxes(wrap_tree(:stretch), %{width: 10, height: 4})
    assert [%{y: 0}, %{y: 0}, %{y: 2}] = result
  end

  test "auto-height items grow with the stretched line" do
    tree = %{
      type: :flex,
      attrs: %{
        flex_direction: :row,
        flex_wrap: :wrap,
        align_content: :stretch,
        align_items: :stretch,
        gap: 0
      },
      children: [
        %{type: :box, width: 4, children: []},
        %{type: :box, width: 4, children: []},
        %{type: :box, width: 4, children: []}
      ]
    }

    result = boxes(tree, %{width: 10, height: 10})
    # lines stretch 5+5; auto-height boxes stretch to fill their line
    assert [%{y: 0, height: 5}, %{y: 0, height: 5}, %{y: 5, height: 5}] = result
  end
end
