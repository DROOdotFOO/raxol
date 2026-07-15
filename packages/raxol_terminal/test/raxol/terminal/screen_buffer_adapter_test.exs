defmodule Raxol.Terminal.ScreenBufferAdapterTest do
  use ExUnit.Case, async: true

  alias Raxol.Terminal.ScreenBufferAdapter

  test "scroll_region_up/4 keeps its buffer-only contract (ScrollOps.scroll_up/4 returns {buffer, evictions} since TE)" do
    buffer = ScreenBufferAdapter.new(10, 5)
    result = ScreenBufferAdapter.scroll_region_up(buffer, 0, 4, 1)

    refute is_tuple(result)
    assert result.height == 5
  end
end
