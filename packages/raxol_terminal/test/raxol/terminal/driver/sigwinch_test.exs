defmodule Raxol.Terminal.Driver.SigwinchTest do
  @moduledoc """
  SIGWINCH -> `:erl_signal_server` -> SigwinchHandler -> Driver `:sigwinch` -> resize `Event`.
  """
  use ExUnit.Case

  alias Raxol.Core.Events.Event
  alias Raxol.Terminal.Driver
  alias Raxol.Terminal.Driver.SigwinchHandler
  alias Raxol.Terminal.DriverTestHelper, as: Helper

  describe "SigwinchHandler (gen_event)" do
    test "forwards :sigwinch signal as a message to the driver pid" do
      {:ok, manager} = :gen_event.start_link()

      :ok =
        :gen_event.add_handler(manager, SigwinchHandler, %{driver: self()})

      :ok = :gen_event.notify(manager, :sigwinch)
      assert_receive :sigwinch, 500

      # Other signals are ignored
      :ok = :gen_event.notify(manager, :sigcont)
      refute_receive :sigcont, 50

      :ok = :gen_event.stop(manager)
    end
  end

  describe "Driver handling of :sigwinch" do
    setup do
      Process.flag(:trap_exit, true)
      Helper.setup_terminal()
    end

    test "dispatches a fresh resize event to the dispatcher" do
      driver_pid = Helper.start_driver(self())

      Helper.wait_for_driver_ready(driver_pid)
      Helper.consume_initial_resize()

      send(driver_pid, :sigwinch)

      # TerminalSize reports 80x24 in the test env
      Helper.assert_resize_event(80, 24)

      Process.exit(driver_pid, :shutdown)
    end

    test "sigwinch without a dispatcher is a no-op (driver stays alive)" do
      {:ok, driver_pid} = Driver.start_link([])

      send(driver_pid, :sigwinch)

      refute_receive {:"$gen_cast", {:dispatch, %Event{type: :resize}}}, 100
      assert Process.alive?(driver_pid)

      Process.exit(driver_pid, :shutdown)
    end
  end
end
