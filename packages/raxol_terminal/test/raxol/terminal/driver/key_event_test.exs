defmodule Raxol.Terminal.Driver.KeyEventTest do
  use ExUnit.Case
  import Mox

  alias Raxol.Terminal.DriverTestHelper, as: Helper

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    Process.flag(:trap_exit, true)
    Helper.setup_terminal()
  end

  # Decode coverage: raw ANSI bytes fed via the real {:trace,...} input path
  # (Driver -> ANSI.InputParser -> dispatch), asserting the parser's real
  # decoded event shapes. NOT prim_tty trace-protocol coverage.
  describe "ANSI input decode for key events" do
    test ~c"decodes and dispatches regular key events" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      Helper.feed_input(driver_pid, "a")
      Helper.assert_char_key("a")

      Helper.feed_input(driver_pid, "b")
      Helper.assert_char_key("b")

      Process.exit(driver_pid, :shutdown)
    end

    test ~c"decodes and dispatches arrow key events" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      # ANSI CSI arrow sequences decode to bare special keys (no :char).
      Helper.feed_input(driver_pid, "\e[A")
      Helper.assert_special_key(:up)

      Helper.feed_input(driver_pid, "\e[B")
      Helper.assert_special_key(:down)

      Helper.feed_input(driver_pid, "\e[C")
      Helper.assert_special_key(:right)

      Helper.feed_input(driver_pid, "\e[D")
      Helper.assert_special_key(:left)

      Process.exit(driver_pid, :shutdown)
    end
  end
end
