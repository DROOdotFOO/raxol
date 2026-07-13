defmodule Raxol.UI.BoxInteriorFillTest do
  @moduledoc """
  A box's background fills its interior, not its border ring.

  The border ring is painted only when asked for explicitly, via `:border_bg`.
  That makes `box(border: :single, bg: :blue)` mean what it reads like -- a blue
  box with a border -- rather than a blue outline around a hollow middle. It
  also lets a border float on a transparent terminal with only its content
  backed.
  """
  use ExUnit.Case, async: true

  alias Raxol.UI.ElementRenderer

  defp box(style), do: ElementRenderer.render_box(0, 0, 5, 4, style, %{})

  defp ring(cells),
    do:
      Enum.filter(cells, fn {x, y, _c, _f, _b, _a} ->
        x in [0, 4] or y in [0, 3]
      end)

  defp interior(cells),
    do:
      Enum.filter(cells, fn {x, y, _c, _f, _b, _a} ->
        x not in [0, 4] and y not in [0, 3]
      end)

  defp bgs(cells),
    do: cells |> Enum.map(fn {_, _, _, _, bg, _} -> bg end) |> Enum.uniq()

  test "a background fills the interior, leaving the border ring unpainted" do
    cells = box(%{border: :single, bg: :blue})

    assert bgs(interior(cells)) == [:blue]

    assert bgs(ring(cells)) == [nil],
           "the border ring must not inherit the box background"

    # 5x4 box -> a 3x2 interior
    assert length(interior(cells)) == 6
  end

  test "no background paints nothing -- a bordered box stays fully transparent" do
    cells = box(%{border: :single})

    assert interior(cells) == []
    assert bgs(ring(cells)) == [nil]
  end

  test "border_bg paints the ring, independently of the interior" do
    cells = box(%{border: :single, bg: :blue, border_bg: :red})

    assert bgs(interior(cells)) == [:blue]
    assert bgs(ring(cells)) == [:red]
  end

  test "a border_bg with no background paints only the ring" do
    cells = box(%{border: :single, border_bg: :red})

    assert interior(cells) == []
    assert bgs(ring(cells)) == [:red]
  end

  test "a box too small to have an interior still renders its border" do
    # 2x2 is all ring, no interior: there is nowhere to put the fill.
    cells =
      ElementRenderer.render_box(0, 0, 2, 2, %{border: :single, bg: :blue}, %{})

    refute cells == []

    refute Enum.any?(cells, fn {_x, _y, char, _fg, bg, _a} ->
             char == " " and bg == :blue
           end),
           "a box with no interior must not emit fill cells"
  end
end
