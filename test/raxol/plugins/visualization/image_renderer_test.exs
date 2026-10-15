defmodule Raxol.Plugins.Visualization.ImageRendererTest do
  use ExUnit.Case, async: true
  @moduletag :capture_log
  alias Raxol.Plugins.Visualization.ImageRenderer
  alias Raxol.Terminal.Cell

  # Test helpers
  defp render_sixel(data, width \\ 5, height \\ 5) do
    ImageRenderer.render_image_content(
      data,
      %{protocol: :sixel},
      %{width: width, height: height},
      %{}
    )
  end

  defp cell_at(grid, x, y), do: grid |> Enum.at(y) |> Enum.at(x)

  defp assert_grid_dimensions(cells, expected_height, expected_width) do
    assert length(cells) == expected_height
    assert Enum.all?(cells, &(length(&1) == expected_width))
  end

  describe "render_image_content/4 with Sixel protocol" do
    test "renders Sixel sequence correctly" do
      # Color 1 (default palette), pattern 'A' (bit 1 set)
      cells = render_sixel("\ePq#1A\e\\", 10, 10)

      assert_grid_dimensions(cells, 10, 10)

      # Pattern 'A' (ASCII 65) is 2 (0b000010), so bit 1 is set at y=1
      cell = cell_at(cells, 0, 1)
      assert %Cell{sixel: true} = cell
      assert cell.style.background != nil
    end

    test "handles complex Sixel with multiple colors" do
      # Define color 1 as red (HLS 0,50,100 -> Red), draw pattern '~' (all 6 bits set)
      cells = render_sixel("\ePq#1;1;0;50;100~\e\\", 5, 8)

      assert_grid_dimensions(cells, 8, 5)

      # Pattern '~' sets bits 0-5, pixel at (0, 0) should have red background
      cell = cell_at(cells, 0, 0)
      assert %Cell{sixel: true} = cell
      assert {:rgb, r, _g, _b} = cell.style.background
      assert r > 200
    end

    test "handles empty bounds gracefully" do
      cells = render_sixel("\ePq#1A\e\\", 0, 0)
      assert cells == []
    end

    test "handles invalid Sixel data gracefully" do
      cells = render_sixel("not a sixel sequence")
      assert_grid_dimensions(cells, 5, 5)
    end

    test "creates cells with proper Sixel flag" do
      cells = render_sixel("\ePq#0A\e\\", 3, 3)

      assert cell_at(cells, 0, 1).sixel == true
      assert cell_at(cells, 2, 2).sixel in [false, nil]
    end
  end

  describe "protocol detection" do
    test "detects Sixel sequence from DCS start" do
      cells = render_sixel("\ePq#0?\e\\")
      assert_grid_dimensions(cells, 5, 5)
    end

    test "falls back to placeholder for unsupported protocol" do
      cells =
        ImageRenderer.render_image_content(
          "some_data",
          %{protocol: :placeholder, title: "Test Image"},
          %{width: 5, height: 5},
          %{}
        )

      assert_grid_dimensions(cells, 5, 5)
    end
  end

  describe "pixel buffer to cells conversion" do
    test "converts pixel buffer with palette correctly" do
      # Process a Sixel sequence with multiple color selections
      cells = render_sixel("\ePq#1A#2A\e\\", 3, 3)
      assert_grid_dimensions(cells, 3, 3)
    end
  end
end
