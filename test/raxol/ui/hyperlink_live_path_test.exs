defmodule Raxol.UI.HyperlinkLivePathTest do
  @moduledoc """
  End-to-end threading of a `link:` through the live render pipeline:

      ElementRenderer.render_text  ->  {:hyperlink, url} in the cell attrs
      Backends.apply_cells_to_buffer  ->  cell.style.hyperlink on the ScreenBuffer
      Terminal.Renderer.render  ->  OSC 8 escape around the run

  This is the path a live TUI (cockpit / SSH / LiveView bridge) takes, distinct
  from the `Raxol.Core.Renderer.apply_diff/1` compat path.
  """
  use ExUnit.Case, async: true

  alias Raxol.Core.Renderer.View.Components.Text
  alias Raxol.Core.Runtime.Rendering.Backends
  alias Raxol.Terminal.Renderer
  alias Raxol.UI.ElementRenderer
  alias Raxol.UI.Layout.Engine, as: LayoutEngine
  alias Raxol.UI.Renderer, as: UIRenderer

  @url "https://basescan.org/tx/0xabc"

  defp osc8_open(url), do: "\e]8;;" <> url <> "\e\\"
  @osc8_close "\e]8;;\e\\"

  test "render_text tags cells with the hyperlink when style carries :link" do
    cells = ElementRenderer.render_text(0, 0, "go", %{link: @url}, %{})

    assert Enum.all?(cells, fn {_x, _y, _char, _fg, _bg, attrs} ->
             {:hyperlink, @url} in attrs
           end)
  end

  test "render_text adds no hyperlink tag when no link is present" do
    cells = ElementRenderer.render_text(0, 0, "go", %{fg: :red}, %{})

    refute Enum.any?(cells, fn {_x, _y, _char, _fg, _bg, attrs} ->
             Enum.any?(attrs, &match?({:hyperlink, _}, &1))
           end)
  end

  test "tagged cells thread through the buffer bridge into an OSC 8 render" do
    cells = ElementRenderer.render_text(0, 0, "go", %{link: @url}, %{})
    buffer = Backends.apply_cells_to_buffer(cells, %{width: 8, height: 1})

    output = Renderer.render(Renderer.new(buffer))

    assert String.contains?(output, osc8_open(@url))
    assert String.contains?(output, @osc8_close)
  end

  test "untagged cells produce no OSC 8 through the same path" do
    cells = ElementRenderer.render_text(0, 0, "go", %{fg: :red}, %{})
    buffer = Backends.apply_cells_to_buffer(cells, %{width: 8, height: 1})

    output = Renderer.render(Renderer.new(buffer))

    refute String.contains?(output, "\e]8")
  end

  describe "View DSL text(link:) through the real layout engine" do
    test "LayoutEngine preserves :link on the positioned text element" do
      el = Text.new("raxol.io", link: @url, fg: :cyan)
      positioned = LayoutEngine.apply_layout(el, %{width: 20, height: 1})

      assert Enum.any?(positioned, &(Map.get(&1, :link) == @url))
    end

    test "text(link:) renders its glyphs wrapped in OSC 8 end-to-end" do
      el = Text.new("raxol.io", link: @url, fg: :cyan, style: [:underline])

      output =
        el
        |> LayoutEngine.apply_layout(%{width: 20, height: 1})
        |> UIRenderer.render_to_cells(nil)
        |> Backends.apply_cells_to_buffer(%{width: 20, height: 1})
        |> Renderer.new()
        |> Renderer.render()

      # real glyphs present (not just blank hyperlinked cells)
      assert output =~ "r"
      assert output =~ "x"
      assert String.contains?(output, osc8_open(@url))
      assert String.contains?(output, @osc8_close)
    end
  end
end
