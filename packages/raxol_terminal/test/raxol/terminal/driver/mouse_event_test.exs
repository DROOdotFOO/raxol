# Driver test helper is loaded via test_helper.exs

defmodule Raxol.Terminal.Driver.MouseEventTest do
  use ExUnit.Case
  import Mox

  alias Raxol.Terminal.DriverTestHelper, as: Helper

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    Process.flag(:trap_exit, true)
    Helper.setup_terminal()
  end

  # Decode coverage: SGR mouse sequences ("\e[<b;x;yM") fed via the real
  # {:trace,...} input path, asserting the parser's real decoded mouse shape
  # (button is an atom like :left/:middle/:right).
  describe "ANSI input decode for mouse events" do
    test ~c"decodes and dispatches mouse button events" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      # SGR button codes: 0 = left, 1 = middle, 2 = right.
      Helper.feed_input(driver_pid, "\e[<0;10;5M")
      Helper.assert_mouse_event(10, 5, :left)

      Helper.feed_input(driver_pid, "\e[<2;15;8M")
      Helper.assert_mouse_event(15, 8, :right)

      Helper.feed_input(driver_pid, "\e[<1;20;12M")
      Helper.assert_mouse_event(20, 12, :middle)

      Process.exit(driver_pid, :shutdown)
    end

    test ~c"decodes mouse events at screen boundaries" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      Helper.feed_input(driver_pid, "\e[<0;0;0M")
      Helper.assert_mouse_event(0, 0, :left)

      Helper.feed_input(driver_pid, "\e[<0;79;23M")
      Helper.assert_mouse_event(79, 23, :left)

      Process.exit(driver_pid, :shutdown)
    end

    test ~c"decodes rapid mouse events in order" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      Helper.feed_input(driver_pid, "\e[<0;10;5M")
      Helper.feed_input(driver_pid, "\e[<0;11;5M")
      Helper.feed_input(driver_pid, "\e[<0;12;5M")

      Helper.assert_mouse_event(10, 5, :left)
      Helper.assert_mouse_event(11, 5, :left)
      Helper.assert_mouse_event(12, 5, :left)

      Process.exit(driver_pid, :shutdown)
    end
  end
end
