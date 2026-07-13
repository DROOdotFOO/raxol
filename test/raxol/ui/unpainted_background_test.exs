defmodule Raxol.UI.UnpaintedBackgroundTest do
  @moduledoc """
  An unpainted background must emit no background SGR at all.

  There is no alpha in the terminal protocol: a cell is transparent precisely
  when the application never set a background for it. Defaulting an unpainted
  background to `:black` emits `\\e[40m` -- an opaque black cell that merely
  *looks* correct on an opaque black terminal, and punches an opaque rectangle
  through a transparent one.
  """
  use ExUnit.Case, async: true

  alias Raxol.Terminal.Renderer
  alias Raxol.UI.CellDim

  describe "unpainted background stays unpainted" do
    test "a style with only a foreground resolves its background to nil" do
      cells = render_cells(%{fg: :red})

      assert Enum.all?(cells, fn {_x, _y, _ch, _fg, bg, _attrs} ->
               is_nil(bg)
             end),
             "an unpainted background must be nil, not :black"
    end

    test "a painted background is preserved" do
      cells = render_cells(%{fg: :red, bg: :blue})

      assert Enum.all?(cells, fn {_x, _y, _ch, _fg, bg, _attrs} ->
               bg == :blue
             end)
    end
  end

  describe "CellDim" do
    test "dim_bg passes an unpainted background through -- dimming it would paint it" do
      assert CellDim.dim_bg(nil, 0.5) == nil
    end

    test "dim_bg still dims a painted background" do
      refute CellDim.dim_bg({200, 100, 50}, 0.5) == {200, 100, 50}
    end
  end

  describe "renderer" do
    test "a nil background emits no background SGR" do
      refute emitted_sgr(%{foreground: :red}) =~ "48;"
      refute emitted_sgr(%{foreground: :red}) =~ "\e[40m"
    end

    test "a painted background does emit one" do
      assert emitted_sgr(%{foreground: :red, background: {10, 20, 30}}) =~
               "48;2;10;20;30"
    end
  end

  defp render_cells(style) do
    Raxol.UI.ElementRenderer.render_text(0, 0, "hi", style, %{})
  end

  defp emitted_sgr(style_map) do
    buffer = Raxol.Terminal.ScreenBuffer.new(4, 1)

    buffer
    |> Raxol.Terminal.ScreenBuffer.write_string(0, 0, "x", style_map)
    |> Renderer.new()
    |> Renderer.render()
  end
end
