defmodule Raxol.Terminal.Driver.InputBufferingTest do
  use ExUnit.Case
  import Mox

  alias Raxol.Terminal.DriverTestHelper, as: Helper

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    Process.flag(:trap_exit, true)
    Helper.setup_terminal()
  end

  # Decode coverage exercising the driver's input buffering: bytes fed via the
  # real {:trace,...} path accumulate in the driver's buffer until a complete
  # ANSI sequence is present, then dispatch as one decoded event.
  describe "Input Buffering" do
    test ~c"dispatches a single complete key byte" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      Helper.feed_input(driver_pid, "x")
      Helper.assert_char_key("x")

      Process.exit(driver_pid, :shutdown)
    end

    test ~c"buffers a partial escape sequence split across reads" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      # "\e[A" arrives one byte per read. The driver buffers the incomplete
      # ESC and ESC[ prefixes, and only once the final byte "A" completes the
      # CSI sequence does it decode+dispatch a single :up key event.
      Helper.feed_input(driver_pid, "\e")
      Helper.feed_input(driver_pid, "[")
      Helper.feed_input(driver_pid, "A")

      Helper.assert_special_key(:up)

      Process.exit(driver_pid, :shutdown)
    end

    test ~c"decodes intermingled printable and escape input in order" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      # Printable char, then an arrow escape sequence, then another char --
      # each decoded and dispatched in arrival order.
      Helper.feed_input(driver_pid, "x")
      Helper.assert_char_key("x")

      Helper.feed_input(driver_pid, "\e[A")
      Helper.assert_special_key(:up)

      Helper.feed_input(driver_pid, "y")
      Helper.assert_char_key("y")

      Process.exit(driver_pid, :shutdown)
    end

    test ~c"decodes rapid input in order" do
      test_pid = self()
      driver_pid = Helper.start_driver(test_pid)

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      Helper.feed_input(driver_pid, "a")
      Helper.feed_input(driver_pid, "b")
      Helper.feed_input(driver_pid, "c")

      Helper.assert_char_key("a")
      Helper.assert_char_key("b")
      Helper.assert_char_key("c")

      Process.exit(driver_pid, :shutdown)
    end
  end
end
