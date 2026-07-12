defmodule Raxol.Terminal.Driver.TerminalReportTest do
  use ExUnit.Case
  import Mox

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.DriverTestHelper, as: Helper

  @moduledoc """
  Regression test for the playground render storm: terminals volunteer
  well-formed CSI reports the input parser has no event mapping for
  (secondary DA replies, cursor position reports, DECRQM responses, ...).
  These used to leak through `dispatch_raw_input/2` as one printable char
  key event PER BYTE -- a single `\\e[>0;282;0c` report became 10 dispatched
  key events, and since every app update triggers a full-frame repaint,
  10 back-to-back clear+redraw frames (plus the leaked "c" toggling app
  state). A terminal report chunk must produce ZERO dispatched events.
  """

  setup :verify_on_exit!
  setup :set_mox_global

  setup do
    Process.flag(:trap_exit, true)
    Helper.setup_terminal()
  end

  describe "raw terminal reports through dispatch_raw_input" do
    test "secondary DA reply chunk produces zero key events" do
      driver_pid = Helper.start_driver(self())
      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      send(driver_pid, {:raw_input, "\e[>0;282;0c"})

      refute_receive {:"$gen_cast", {:dispatch, %Event{type: :key}}}, 200

      Process.exit(driver_pid, :shutdown)
    end

    test "CPR and DECRQM reply chunks produce zero key events" do
      driver_pid = Helper.start_driver(self())
      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      send(driver_pid, {:raw_input, "\e[42;120R"})
      send(driver_pid, {:raw_input, "\e[?2026;2$y"})

      refute_receive {:"$gen_cast", {:dispatch, %Event{type: :key}}}, 200

      Process.exit(driver_pid, :shutdown)
    end

    test "report followed by a real key dispatches exactly that key" do
      driver_pid = Helper.start_driver(self())
      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      send(driver_pid, {:raw_input, "\e[>0;282;0c\e[B"})

      assert_receive {:"$gen_cast",
                      {:dispatch, %Event{type: :key, data: %{key: :down}}}},
                     500

      refute_receive {:"$gen_cast", {:dispatch, %Event{type: :key}}}, 200

      Process.exit(driver_pid, :shutdown)
    end
  end
end
