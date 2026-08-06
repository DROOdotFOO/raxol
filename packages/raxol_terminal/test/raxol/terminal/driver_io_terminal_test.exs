defmodule Raxol.Terminal.DriverIOTerminalTest do
  use ExUnit.Case, async: false

  alias Raxol.Terminal.Driver
  alias Raxol.Terminal.IOTerminal

  @moduletag :driver_io_terminal
  @moduletag :skip_on_ci

  # These tests exercise the IOTerminal fallback, which only runs where the
  # termbox2 NIF is absent. With the NIF loaded they must SKIP visibly in
  # ExUnit's report -- not run zero assertions and count as passed.
  @termbox_available Code.ensure_loaded?(:termbox2_nif) and
                       function_exported?(:termbox2_nif, :tb_init, 0)

  describe "Driver with IOTerminal backend" do
    if @termbox_available do
      @tag skip:
             "termbox2 NIF loaded; Driver only falls back to IOTerminal without it"
    end

    test "initializes with IOTerminal when termbox2_nif not available" do
      # This test verifies the Driver can initialize using IOTerminal.
      # Start a test dispatcher
      {:ok, dispatcher} =
        GenServer.start_link(
          fn -> %{} end,
          fn
            {:dispatch, _event}, state -> {:noreply, state}
            {:driver_ready, _pid}, state -> {:noreply, state}
            _msg, state -> {:noreply, state}
          end
        )

      # Start driver with dispatcher
      {:ok, driver_pid} = Driver.start_link(dispatcher)

      # Driver should initialize successfully
      assert Process.alive?(driver_pid)

      # Cleanup
      GenServer.stop(driver_pid)
      GenServer.stop(dispatcher)
    end

    if @termbox_available do
      @tag skip:
             "termbox2 NIF loaded; IOTerminal size fallback not reachable here"
    end

    test "Driver uses IOTerminal for size detection when termbox unavailable" do
      # IOTerminal should be used for size detection
      {:ok, {width, height}} = IOTerminal.get_terminal_size()
      assert is_integer(width)
      assert is_integer(height)
      assert width > 0
      assert height > 0
    end
  end

  describe "IOTerminal fallback behavior" do
    if @termbox_available do
      @describetag skip:
                     "termbox2 NIF loaded; IOTerminal-only fallback not reachable here"
    end

    test "get_termbox_width uses IOTerminal when NIF unavailable" do
      # When termbox2_nif is not available, should use IOTerminal
      {:ok, {width, _}} = IOTerminal.get_terminal_size()
      assert width >= 80
    end

    test "get_termbox_height uses IOTerminal when NIF unavailable" do
      {:ok, {_, height}} = IOTerminal.get_terminal_size()
      assert height >= 24
    end
  end

  describe "Driver initialization states" do
    test "Driver state includes io_terminal_state field" do
      # This is a compile-time check that the State struct has the field
      state = %Driver.State{}
      assert Map.has_key?(state, :io_terminal_state)
    end
  end

  describe "cross-platform terminal detection" do
    test "detects terminal backend availability" do
      termbox_available = Code.ensure_loaded?(:termbox2_nif)
      io_terminal_available = Code.ensure_loaded?(IOTerminal)

      # At least one backend should be available
      assert termbox_available or io_terminal_available

      # IOTerminal should always be available as fallback
      assert io_terminal_available
    end

    test "IOTerminal works on current platform" do
      # Test that IOTerminal can initialize on any platform
      assert {:ok, state} = IOTerminal.init()
      assert state.initialized
      IOTerminal.shutdown()
    end
  end

  describe "terminal operations without termbox2_nif" do
    if @termbox_available do
      @describetag skip:
                     "termbox2 NIF loaded; IOTerminal-only path not reachable here"
    end

    setup do
      {:ok, _state} = IOTerminal.init()
      on_exit(fn -> IOTerminal.shutdown() end)
      :ok
    end

    test "can perform basic terminal operations" do
      # These should work via IOTerminal
      assert :ok = IOTerminal.clear_screen()
      assert :ok = IOTerminal.hide_cursor()
      assert :ok = IOTerminal.set_cell(0, 0, "A", 15, 0)
      assert :ok = IOTerminal.present()
      assert :ok = IOTerminal.show_cursor()
    end

    test "can get terminal size" do
      assert {:ok, {width, height}} = IOTerminal.get_terminal_size()
      assert width > 0
      assert height > 0
    end

    test "can set terminal title" do
      assert :ok = IOTerminal.set_title("Test Title")
    end
  end
end
