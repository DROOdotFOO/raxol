defmodule Raxol.UI.BasicRenderingTest do
  use ExUnit.Case
  alias Raxol.Test.RendererTestHelper, as: Helper
  alias Raxol.UI.Renderer

  setup do
    # Ensure UserPreferences is started for all tests
    case Raxol.Core.UserPreferences.start_link(test_mode?: true) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  test "handles empty elements" do
    element = Helper.create_test_element(:box, 0, 0, %{width: 0, height: 0})
    cells = Renderer.render_to_cells(element)
    assert cells == []
  end

  test "handles nil elements" do
    cells = Renderer.render_to_cells(nil)
    assert cells == []
  end

  test "handles missing required attributes" do
    element = Helper.create_test_element(:box, 0, 0, %{width: 1, height: 1})
    cells = Renderer.render_to_cells(element)

    assert [
             {0, 0, " ", fg, bg, attrs}
           ] = cells

    # Accept :default, named atom colors, Color structs, or nil -- an
    # attr-less box with no painted bg resolves fg to nil, not a forced
    # default (region-prominence-propagation.md §9 Phase 3, case a): the
    # terminal's own default fg shows through.
    assert is_nil(fg) or fg == :default or fg == :white or fg == :black or
             is_struct(fg, Raxol.Style.Colors.Color)

    assert is_nil(bg) or bg == :default or bg == :black or bg == :white or
             is_struct(bg, Raxol.Style.Colors.Color)

    # Attributes can be empty or contain border style
    assert attrs == [] or attrs == [:single]
  end

  test "handles overlapping elements" do
    element1 = Helper.create_test_box(0, 0, 5, 5)
    element2 = Helper.create_test_box(2, 2, 5, 5)
    cells = Renderer.render_to_cells([element1, element2])

    # Element2 should be rendered on top of element1
    cell = Helper.get_cell_at(cells, 2, 2)
    assert cell != nil
  end

  test "handles nested elements" do
    child = Helper.create_test_text(1, 1, "test")
    parent = Helper.create_test_panel(0, 0, 10, 10, [child])
    cells = Renderer.render_to_cells(parent)

    text_cell = Helper.get_cells_with_char(cells, "t")
    assert [_ | _] = text_cell
  end

  test "handles non-ASCII characters in text" do
    element = Helper.create_test_text(0, 0, "Hello 世界")
    cells = Renderer.render_to_cells(element)

    non_ascii_cells =
      Enum.filter(cells, fn {_, _, char, _, _, _} ->
        String.match?(char, ~r/[^\x00-\x7F]/u)
      end)

    assert [_ | _] = non_ascii_cells
  end

  test "handles very large elements" do
    element = Helper.create_test_box(0, 0, 1000, 1000)
    cells = Renderer.render_to_cells(element)

    # Should handle large elements without crashing
    assert [_ | _] = cells
  end

  test "handles elements with zero dimensions" do
    element = Helper.create_test_box(0, 0, 0, 0)
    cells = Renderer.render_to_cells(element)
    assert cells == []
  end

  test "handles elements with negative dimensions" do
    element = Helper.create_test_box(0, 0, -5, -5)
    cells = Renderer.render_to_cells(element)
    assert cells == []
  end

  test "handles elements with negative coordinates" do
    element = Helper.create_test_box(-5, -5, 10, 10)
    cells = Renderer.render_to_cells(element)
    assert [_ | _] = cells
  end
end
