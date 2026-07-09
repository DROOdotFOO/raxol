defmodule Raxol.Effects.BorderBeamTest do
  use ExUnit.Case, async: true

  alias Raxol.Effects.BorderBeam
  alias Raxol.Effects.BorderBeam.Colors

  # Create a minimal buffer struct matching Buffer API expectations
  defp make_buffer(width, height) do
    lines =
      for _y <- 0..(height - 1) do
        cells =
          for _x <- 0..(width - 1) do
            %{char: " ", style: %{fg_color: nil, bg_color: nil, bold: false}}
          end

        %{cells: cells}
      end

    %{width: width, height: height, lines: lines}
  end

  defp make_bordered_buffer(x, y, w, h, buf_w \\ 40, buf_h \\ 20) do
    buffer = make_buffer(buf_w, buf_h)

    # Draw a border
    Enum.reduce(0..(w - 1), buffer, fn i, buf ->
      buf
      |> put_cell(x + i, y, "─")
      |> put_cell(x + i, y + h - 1, "─")
    end)
    |> put_cell(x, y, "┌")
    |> put_cell(x + w - 1, y, "┐")
    |> put_cell(x, y + h - 1, "└")
    |> put_cell(x + w - 1, y + h - 1, "┘")
    |> then(fn buf ->
      Enum.reduce(1..(h - 2), buf, fn j, b ->
        b
        |> put_cell(x, y + j, "│")
        |> put_cell(x + w - 1, y + j, "│")
      end)
    end)
  end

  defp put_cell(buffer, x, y, char) do
    Raxol.Core.Buffer.set_cell(buffer, x, y, char, %{
      fg_color: :white,
      bg_color: nil,
      bold: false
    })
  end

  defp get_cell(buffer, x, y) do
    Raxol.Core.Buffer.get_cell(buffer, x, y)
  end

  describe "new/1" do
    test "creates with default config" do
      beam = BorderBeam.new()
      assert beam.config.size == :full
      assert beam.config.color_variant == :colorful
      assert beam.config.strength == 0.8
      assert beam.config.duration_ms == 2000
      assert beam.active == true
      assert beam.started_at != nil
    end

    test "merges custom config" do
      beam =
        BorderBeam.new(color_variant: :ocean, duration_ms: 3000, strength: 0.5)

      assert beam.config.color_variant == :ocean
      assert beam.config.duration_ms == 3000
      assert beam.config.strength == 0.5
      # defaults preserved
      assert beam.config.size == :full
    end

    test "accepts active: false" do
      beam = BorderBeam.new(active: false)
      refute beam.active
    end
  end

  describe "compute_perimeter/2" do
    test "computes correct path length for rectangle" do
      bounds = %{x: 0, y: 0, width: 10, height: 5}
      path = BorderBeam.compute_perimeter(bounds, :full)
      # 2*(10-1) + 2*(5-1) = 18 + 8 = 26
      assert length(path) == 26
    end

    test "starts at top-left and goes clockwise" do
      bounds = %{x: 2, y: 3, width: 5, height: 4}
      path = BorderBeam.compute_perimeter(bounds, :full)

      assert hd(path) == {2, 3}
      # Top edge ends at top-right
      assert Enum.at(path, 4) == {6, 3}
      # Then moves down right side
      assert Enum.at(path, 5) == {6, 4}
    end

    test "contains all four corners" do
      bounds = %{x: 0, y: 0, width: 4, height: 3}
      path = BorderBeam.compute_perimeter(bounds, :full)

      assert {0, 0} in path
      assert {3, 0} in path
      assert {3, 2} in path
      assert {0, 2} in path
    end

    test "line variant produces bottom edge only" do
      bounds = %{x: 5, y: 2, width: 10, height: 4}
      path = BorderBeam.compute_perimeter(bounds, :line)

      assert length(path) == 10
      assert hd(path) == {5, 5}
      assert List.last(path) == {14, 5}
      # All cells on the same y
      assert Enum.all?(path, fn {_x, y} -> y == 5 end)
    end

    test "returns empty for too-small bounds" do
      assert BorderBeam.compute_perimeter(
               %{x: 0, y: 0, width: 2, height: 2},
               :full
             ) == []

      assert BorderBeam.compute_perimeter(
               %{x: 0, y: 0, width: 2, height: 1},
               :line
             ) == []
    end
  end

  describe "set_bounds/2" do
    test "sets bounds and caches perimeter" do
      beam =
        BorderBeam.new()
        |> BorderBeam.set_bounds(%{x: 0, y: 0, width: 10, height: 5})

      assert beam.bounds == %{x: 0, y: 0, width: 10, height: 5}
      assert length(beam.perimeter) == 26
    end
  end

  describe "set_active/2" do
    test "deactivating sets fade_start" do
      beam = BorderBeam.new()
      beam = BorderBeam.set_active(beam, false)
      refute beam.active
      assert beam.fade_start != nil
    end

    test "reactivating clears fade and resets started_at" do
      beam = BorderBeam.new() |> BorderBeam.set_active(false)
      beam = BorderBeam.set_active(beam, true)
      assert beam.active
      assert beam.fade_start == nil
    end

    test "setting same state is no-op" do
      beam = BorderBeam.new()
      beam2 = BorderBeam.set_active(beam, true)
      assert beam.started_at == beam2.started_at
    end
  end

  describe "visible?/1" do
    test "true when active" do
      beam = BorderBeam.new()
      assert BorderBeam.visible?(beam)
    end

    test "false when disabled" do
      beam = BorderBeam.new(enabled: false)
      refute BorderBeam.visible?(beam)
    end

    test "true during fade-out" do
      beam =
        BorderBeam.new()
        |> BorderBeam.set_active(false)
        |> BorderBeam.update(System.monotonic_time(:millisecond))

      assert BorderBeam.visible?(beam)
    end

    test "false after fade completes" do
      beam = BorderBeam.new(fade_ms: 10) |> BorderBeam.set_active(false)
      Process.sleep(15)
      beam = BorderBeam.update(beam)
      refute BorderBeam.visible?(beam)
    end

    test "false when inactive without fade" do
      beam = %{BorderBeam.new() | active: false, fade_start: nil}
      refute BorderBeam.visible?(beam)
    end
  end

  describe "apply/2" do
    test "returns buffer unchanged when disabled" do
      buffer = make_buffer(20, 10)

      beam =
        BorderBeam.new(enabled: false)
        |> BorderBeam.set_bounds(%{x: 0, y: 0, width: 10, height: 5})
        |> BorderBeam.update()

      assert BorderBeam.apply(beam, buffer) == buffer
    end

    test "returns buffer unchanged when no bounds" do
      buffer = make_buffer(20, 10)
      beam = BorderBeam.new() |> BorderBeam.update()
      assert BorderBeam.apply(beam, buffer) == buffer
    end

    test "modifies border cells with beam styling" do
      buffer = make_bordered_buffer(2, 1, 10, 5)

      beam =
        BorderBeam.new(duration_ms: 100)
        |> BorderBeam.set_bounds(%{x: 2, y: 1, width: 10, height: 5})
        |> BorderBeam.update()

      result = BorderBeam.apply(beam, buffer)

      # At least some border cells should have modified styles
      perimeter =
        BorderBeam.compute_perimeter(%{x: 2, y: 1, width: 10, height: 5}, :full)

      styled_cells =
        Enum.count(perimeter, fn {x, y} ->
          cell = get_cell(result, x, y)
          style = Map.get(cell, :style, %{})

          Map.get(style, :fg_color) != nil and
            Map.get(style, :fg_color) != :white
        end)

      assert styled_cells > 0
    end

    test "preserves existing characters" do
      buffer = make_bordered_buffer(0, 0, 10, 5)

      beam =
        BorderBeam.new()
        |> BorderBeam.set_bounds(%{x: 0, y: 0, width: 10, height: 5})
        |> BorderBeam.update()

      result = BorderBeam.apply(beam, buffer)

      # Check multiple border cells retain their characters
      perimeter =
        BorderBeam.compute_perimeter(%{x: 0, y: 0, width: 10, height: 5}, :full)

      # Every border cell should still have a non-space character
      border_chars_preserved =
        Enum.all?(perimeter, fn {x, y} ->
          cell = get_cell(result, x, y)
          cell.char != " "
        end)

      assert border_chars_preserved
    end

    test "beam head has bright intensity" do
      buffer = make_bordered_buffer(0, 0, 20, 10)

      # Use a very short duration so beam is at a known position
      beam =
        BorderBeam.new(duration_ms: 1_000_000, strength: 1.0)
        |> BorderBeam.set_bounds(%{x: 0, y: 0, width: 20, height: 10})

      # Set started_at to now so progress is ~0 -> head at index 0 -> (0,0)
      now = System.monotonic_time(:millisecond)
      beam = %{beam | started_at: now, last_update: now}

      result = BorderBeam.apply(beam, buffer)
      cell = get_cell(result, 0, 0)
      style = Map.get(cell, :style, %{})
      assert Map.get(style, :bold) == true
    end

    test "compact size skips inner glow and bloom" do
      buffer = make_bordered_buffer(0, 0, 10, 5)

      beam =
        BorderBeam.new(size: :compact, strength: 1.0)
        |> BorderBeam.set_bounds(%{x: 0, y: 0, width: 10, height: 5})
        |> BorderBeam.update()

      result = BorderBeam.apply(beam, buffer)

      # Interior cells should NOT have bg_color set
      interior_cell = get_cell(result, 5, 2)
      style = Map.get(interior_cell, :style, %{})
      assert Map.get(style, :bg_color) == nil
    end

    test "line size only modifies bottom border" do
      buffer = make_bordered_buffer(0, 0, 10, 5)

      beam =
        BorderBeam.new(size: :line, strength: 1.0)
        |> BorderBeam.set_bounds(%{x: 0, y: 0, width: 10, height: 5})
        |> BorderBeam.update()

      result = BorderBeam.apply(beam, buffer)

      # Top border should be unchanged
      top_cell = get_cell(result, 5, 0)
      top_style = Map.get(top_cell, :style, %{})

      assert Map.get(top_style, :fg_color) == :white or
               Map.get(top_style, :fg_color) == nil
    end
  end

  describe "update_config/2" do
    test "updates config fields" do
      beam =
        BorderBeam.new()
        |> BorderBeam.update_config(color_variant: :sunset, strength: 0.3)

      assert beam.config.color_variant == :sunset
      assert beam.config.strength == 0.3
    end

    test "recomputes perimeter when size changes" do
      beam =
        BorderBeam.new(size: :full)
        |> BorderBeam.set_bounds(%{x: 0, y: 0, width: 10, height: 5})

      full_len = length(beam.perimeter)

      beam = BorderBeam.update_config(beam, size: :line)
      assert length(beam.perimeter) != full_len
      assert length(beam.perimeter) == 10
    end
  end

  describe "Colors" do
    test "palette returns valid colors for each variant" do
      for variant <- [:colorful, :mono, :ocean, :sunset] do
        pal = Colors.palette(variant)
        assert is_list(pal)
        assert [_ | _] = pal
        assert Enum.all?(pal, &is_atom/1)
      end
    end

    test "beam_color cycles through palette" do
      c1 = Colors.beam_color(:colorful, 0.0, false)
      c2 = Colors.beam_color(:colorful, 0.5, false)
      assert is_atom(c1)
      assert is_atom(c2)
    end

    test "beam_color with static returns first color" do
      assert Colors.beam_color(:colorful, 0.5, true) == :bright_red
      assert Colors.beam_color(:ocean, 0.9, true) == :bright_cyan
    end

    test "glow_color returns atom" do
      for variant <- [:colorful, :mono, :ocean, :sunset] do
        assert is_atom(Colors.glow_color(variant))
      end
    end

    test "css_palette returns hex strings" do
      pal = Colors.css_palette(:ocean)
      assert Enum.all?(pal, &String.starts_with?(&1, "#"))
    end
  end
end
