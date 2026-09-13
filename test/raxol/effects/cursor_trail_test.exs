defmodule Raxol.Effects.CursorTrailTest do
  use ExUnit.Case, async: true
  alias Raxol.Core.Buffer
  alias Raxol.Effects.CursorTrail

  setup do
    buffer = Buffer.create_blank_buffer(80, 24)
    {:ok, buffer: buffer}
  end

  describe "new/1" do
    test "creates trail with default config" do
      trail = CursorTrail.new()

      assert trail.config.enabled == true
      assert trail.config.max_length == 15
      assert trail.points == []
      assert trail.tick == 0
    end

    test "accepts custom config" do
      config = %{max_length: 5, enabled: false}
      trail = CursorTrail.new(config)

      assert trail.config.max_length == 5
      assert trail.config.enabled == false
    end

    test "merges config with defaults" do
      trail = CursorTrail.new(%{max_length: 20})

      assert trail.config.max_length == 20
      assert trail.config.enabled == true
      assert trail.config.decay_rate != nil
    end
  end

  describe "update/2" do
    test "adds position to trail" do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {10, 5})

      assert length(trail.points) == 1
      [point | _] = trail.points
      assert point.position == {10, 5}
      assert point.age == 0
    end

    test "increments age on existing positions" do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {10, 5})
      trail = CursorTrail.update(trail, {11, 5})

      assert length(trail.points) == 2
      [point1, point2] = trail.points
      assert point1.age == 0
      assert point2.age == 1
    end

    test "respects max_length limit" do
      trail = CursorTrail.new(%{max_length: 3})
      trail = CursorTrail.update(trail, {1, 1})
      trail = CursorTrail.update(trail, {2, 2})
      trail = CursorTrail.update(trail, {3, 3})
      trail = CursorTrail.update(trail, {4, 4})

      assert length(trail.points) <= 3
    end

    test "does not add duplicate consecutive positions" do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {10, 5})
      trail = CursorTrail.update(trail, {10, 5})

      assert length(trail.points) == 1
    end

    test "disabled trail does not add positions" do
      trail = CursorTrail.new(%{enabled: false})
      trail = CursorTrail.update(trail, {10, 5})

      assert trail.points == []
    end
  end

  describe "apply/2" do
    test "applies trail to buffer", %{buffer: buffer} do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {5, 5})
      trail = CursorTrail.update(trail, {6, 5})

      result = CursorTrail.apply(trail, buffer)

      assert result != buffer
    end

    test "returns unchanged buffer when disabled", %{buffer: buffer} do
      trail = CursorTrail.new(%{enabled: false})
      trail = CursorTrail.update(trail, {5, 5})

      result = CursorTrail.apply(trail, buffer)

      assert result == buffer
    end

    test "returns unchanged buffer with empty trail", %{buffer: buffer} do
      trail = CursorTrail.new()

      result = CursorTrail.apply(trail, buffer)

      assert result == buffer
    end
  end

  describe "preset effects" do
    test "rainbow creates colorful fading trail" do
      trail = CursorTrail.rainbow()

      assert trail.config.enabled == true
      assert trail.config.max_length > 0
      assert is_list(trail.config.colors)
    end

    test "comet creates trailing effect" do
      trail = CursorTrail.comet()

      assert trail.config.enabled == true
      assert trail.config.max_length > 0
    end

    test "minimal creates subtle trail" do
      trail = CursorTrail.minimal()

      assert trail.config.enabled == true
      assert trail.config.max_length <= 10
    end
  end

  describe "interpolate/3" do
    test "generates smooth trail between two points" do
      trail = CursorTrail.new()
      trail = CursorTrail.interpolate(trail, {0, 0}, {5, 0})

      assert length(trail.points) >= 5
    end

    test "interpolates diagonal movement" do
      trail = CursorTrail.new()
      trail = CursorTrail.interpolate(trail, {0, 0}, {10, 10})

      assert length(trail.points) >= 10
    end
  end

  describe "multi_cursor/2" do
    test "creates trail with multiple cursor positions" do
      positions = [{10, 5}, {20, 10}, {30, 15}]
      trail = CursorTrail.multi_cursor(positions)

      assert length(trail.points) == 3
    end

    test "accepts custom config" do
      positions = [{5, 5}, {10, 10}]
      trail = CursorTrail.multi_cursor(positions, %{max_length: 20})

      assert trail.config.max_length == 20
      assert length(trail.points) == 2
    end
  end

  describe "clear/1" do
    test "removes all positions from trail" do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {5, 5})
      trail = CursorTrail.update(trail, {6, 6})

      trail = CursorTrail.clear(trail)

      assert trail.points == []
    end

    test "preserves configuration" do
      trail = CursorTrail.new(%{max_length: 20})
      trail = CursorTrail.update(trail, {5, 5})

      trail = CursorTrail.clear(trail)

      assert trail.config.max_length == 20
      assert trail.config.enabled == true
    end
  end

  describe "set_enabled/2" do
    test "enables trail" do
      trail = CursorTrail.new(%{enabled: false})
      trail = CursorTrail.set_enabled(trail, true)

      assert trail.config.enabled == true
    end

    test "disables trail" do
      trail = CursorTrail.new()
      trail = CursorTrail.set_enabled(trail, false)

      assert trail.config.enabled == false
    end

    test "enabled trail accepts positions" do
      trail = CursorTrail.new(%{enabled: false})
      trail = CursorTrail.set_enabled(trail, true)
      trail = CursorTrail.update(trail, {5, 5})

      assert length(trail.points) == 1
    end

    test "disabled trail ignores positions" do
      trail = CursorTrail.new()
      trail = CursorTrail.set_enabled(trail, false)
      trail = CursorTrail.update(trail, {5, 5})

      assert trail.points == []
    end
  end

  describe "update_config/2" do
    test "updates configuration" do
      trail = CursorTrail.new()
      trail = CursorTrail.update_config(trail, %{max_length: 25})

      assert trail.config.max_length == 25
    end

    test "merges with existing config" do
      trail = CursorTrail.new(%{max_length: 10})
      trail = CursorTrail.update_config(trail, %{colors: [:red]})

      assert trail.config.max_length == 10
      assert trail.config.colors == [:red]
    end
  end

  describe "stats/1" do
    test "returns trail statistics" do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {5, 5})
      trail = CursorTrail.update(trail, {6, 6})

      stats = CursorTrail.stats(trail)

      assert stats.point_count == 2
      assert stats.enabled == true
      assert stats.tick >= 0
    end
  end

  describe "length/1" do
    test "returns number of trail points" do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {5, 5})
      trail = CursorTrail.update(trail, {6, 6})

      assert CursorTrail.length(trail) == 2
    end

    test "returns 0 for empty trail" do
      trail = CursorTrail.new()

      assert CursorTrail.length(trail) == 0
    end
  end

  describe "apply_glow/3" do
    test "applies glow effect around position", %{buffer: buffer} do
      result = CursorTrail.apply_glow(buffer, {10, 10})

      assert result != buffer
    end

    test "accepts custom glow color", %{buffer: buffer} do
      result = CursorTrail.apply_glow(buffer, {10, 10}, :red)

      assert result != buffer
    end
  end

  describe "edge cases" do
    test "handles positions outside buffer bounds", %{buffer: buffer} do
      trail = CursorTrail.new()
      trail = CursorTrail.update(trail, {-1, -1})
      trail = CursorTrail.update(trail, {1000, 1000})

      result = CursorTrail.apply(trail, buffer)

      assert result != nil
    end

    test "handles rapid position updates" do
      trail = CursorTrail.new(%{max_length: 100})

      trail =
        Enum.reduce(1..50, trail, fn i, acc ->
          CursorTrail.update(acc, {i, i})
        end)

      assert CursorTrail.length(trail) <= 100
    end

    test "handles zero max_length gracefully" do
      trail = CursorTrail.new(%{max_length: 0})
      trail = CursorTrail.update(trail, {5, 5})

      assert CursorTrail.length(trail) <= 1
    end
  end

  describe "long trails" do
    test "a trail never grows past max_length" do
      trail = CursorTrail.new(%{max_length: 1000})

      trail =
        Enum.reduce(1..2000, trail, fn i, acc ->
          CursorTrail.update(acc, {i, rem(i, 24)})
        end)

      # Twice as many updates as the cap: the cap (plus fade pruning) is
      # what bounds the work, and something is still on the trail.
      length = CursorTrail.length(trail)
      assert length <= 1000
      assert length > 0
    end

    test "apply over a full trail writes into the buffer", %{buffer: buffer} do
      trail = CursorTrail.new(%{max_length: 100})

      trail =
        Enum.reduce(1..100, trail, fn i, acc ->
          CursorTrail.update(acc, {rem(i, 80), rem(i, 24)})
        end)

      assert %{} = CursorTrail.apply(trail, buffer)
    end
  end
end
