defmodule Raxol.Terminal.TerminalUtilsTest do
  # Run tests serially now
  use ExUnit.Case, async: false

  alias Raxol.Terminal.TerminalUtils

  # Define a mock IO facade
  defmodule MockIO do
    def columns, do: {:ok, 120}
    def rows, do: {:ok, 40}
  end

  defmodule ErrorIO do
    def columns, do: {:error, :enoent}
    def rows, do: {:error, :enoent}
  end

  describe "get_dimensions_map/0" do
    # This test might be flaky as it relies on the real detect_dimensions
    # which uses multiple fallbacks (IO, termbox, stty).
    # It's better to test the internal components like detect_with_io.
    @tag :flaky
    test "returns map with width and height (using real detection)" do
      dimensions = TerminalUtils.get_dimensions_map()

      assert is_map(dimensions)
      assert Map.has_key?(dimensions, :width)
      assert Map.has_key?(dimensions, :height)
      assert is_integer(dimensions.width)
      assert is_integer(dimensions.height)
      assert dimensions.width > 0
      assert dimensions.height > 0
    end
  end

  describe "get_bounds_map/0" do
    # Similar to above, this relies on real detection.
    @tag :flaky
    test "returns map with x, y, width, and height (using real detection)" do
      bounds = TerminalUtils.get_bounds_map()

      assert is_map(bounds)
      assert Map.has_key?(bounds, :x)
      assert Map.has_key?(bounds, :y)
      assert Map.has_key?(bounds, :width)
      assert Map.has_key?(bounds, :height)

      assert bounds.x == 0
      assert bounds.y == 0
      assert is_integer(bounds.width)
      assert is_integer(bounds.height)
      assert bounds.width > 0
      assert bounds.height > 0
    end
  end

  describe "has_terminal_device?/0" do
    test "a terminal on either stdout or the controlling terminal counts" do
      # Burrito's launcher puts the BEAM's stdout on a pipe, so asking stdout
      # alone reported "no terminal" on every packaged run and the driver
      # skipped raw mode and the alternate screen. The driver reaches the
      # terminal through /dev/tty regardless, so either answer is sufficient.
      stdout? = :prim_tty.isatty(:stdout) == true

      assert TerminalUtils.has_terminal_device?() ==
               (stdout? or TerminalUtils.controlling_terminal?())
    end

    test "the controlling-terminal answer is stable across calls" do
      # It is cached in :persistent_term because has_terminal_device?/0 runs
      # per cursor move and this branch opens a file. Reading it twice must
      # not depend on which call populated the cache.
      first = TerminalUtils.controlling_terminal?()

      assert is_boolean(first)
      assert TerminalUtils.controlling_terminal?() == first
    end
  end
end
