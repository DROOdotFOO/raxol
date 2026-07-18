defmodule Raxol.Symphony.SurfaceFormatTest do
  use ExUnit.Case, async: true

  alias Raxol.Symphony.SurfaceFormat

  describe "format_ms/1" do
    test "sub-second durations render as milliseconds" do
      assert SurfaceFormat.format_ms(0) == "0ms"
      assert SurfaceFormat.format_ms(999) == "999ms"
    end

    test "sub-minute durations render as whole (truncated) seconds" do
      assert SurfaceFormat.format_ms(1_000) == "1s"
      assert SurfaceFormat.format_ms(1_234) == "1s"
      assert SurfaceFormat.format_ms(59_999) == "59s"
    end

    test "minute-or-longer durations render as minutes and seconds" do
      assert SurfaceFormat.format_ms(60_000) == "1m0s"
      assert SurfaceFormat.format_ms(90_000) == "1m30s"
      assert SurfaceFormat.format_ms(3_661_000) == "61m1s"
    end

    test "non-integer input renders the unknown marker" do
      assert SurfaceFormat.format_ms(nil) == "?"
      assert SurfaceFormat.format_ms("12") == "?"
      assert SurfaceFormat.format_ms(1.5) == "?"
    end
  end
end
