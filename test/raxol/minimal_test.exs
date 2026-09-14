defmodule Raxol.MinimalTest do
  use ExUnit.Case, async: false
  doctest Raxol.Minimal

  describe "minimal terminal startup" do
    test "starts with default options" do
      {:ok, pid} = Raxol.Minimal.start_terminal()
      state = Raxol.Minimal.get_state(pid)

      assert state.width == 80
      assert state.height == 24
      assert state.mode == :raw
      assert state.cursor == {0, 0}
      assert state.main_buffer != nil

      GenServer.stop(pid)
    end

    test "starts with custom options" do
      {:ok, pid} = Raxol.Minimal.start_terminal(
        width: 120,
        height: 30,
        mode: :cooked,
        features: [:colors, :alternate_screen]
      )
      state = Raxol.Minimal.get_state(pid)

      assert state.width == 120
      assert state.height == 30
      assert state.mode == :cooked
      assert MapSet.member?(state.features, :colors)
      assert MapSet.member?(state.features, :alternate_screen)
      assert state.alternate_buffer != nil

      GenServer.stop(pid)
    end

    # Wall-clock perf bound; tight enough to flake on loaded CI runners.
    @tag :skip_on_ci
    test "measures startup time" do
      start_time = System.monotonic_time(:microsecond)
      {:ok, pid} = Raxol.Minimal.start_terminal()
      end_time = System.monotonic_time(:microsecond)

      startup_time_ms = (end_time - start_time) / 1000
      # Use larger timeout on Windows CI for timing variability
      timeout_ms = if :os.type() == {:win32, :nt}, do: 150, else: 50
      assert startup_time_ms < timeout_ms, "Startup time should be under #{timeout_ms}ms, got #{startup_time_ms}ms"

      GenServer.stop(pid)
    end

    test "supports telemetry" do
      {:ok, pid} = Raxol.Minimal.start_terminal(telemetry: true)
      state = Raxol.Minimal.get_state(pid)

      assert state.telemetry_enabled == true
      assert state.metrics != nil
      assert state.metrics.input_count == 0

      GenServer.stop(pid)
    end
  end

  describe "input handling" do
    setup do
      {:ok, pid} = Raxol.Minimal.start_terminal()
      %{terminal: pid}
    end

    test "processes cursor movement", %{terminal: pid} do
      # Move cursor right
      Raxol.Minimal.send_input(pid, "\e[C")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {1, 0}

      # Move cursor down
      Raxol.Minimal.send_input(pid, "\e[B")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {1, 1}

      # Move cursor with parameters
      Raxol.Minimal.send_input(pid, "\e[5C")  # Move 5 right
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {6, 1}

      GenServer.stop(pid)
    end

    test "processes CSI sequences" do
      {:ok, pid} = Raxol.Minimal.start_terminal()

      # Set cursor position
      Raxol.Minimal.send_input(pid, "\e[10;20H")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {19, 9}  # 1-indexed to 0-indexed

      # Clear screen
      Raxol.Minimal.send_input(pid, "\e[2J")
      Process.sleep(1)

      # Save and restore cursor
      Raxol.Minimal.send_input(pid, "\e[s")  # Save
      Raxol.Minimal.send_input(pid, "\e[5;5H")  # Move
      Raxol.Minimal.send_input(pid, "\e[u")  # Restore
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {19, 9}  # Back to saved position

      GenServer.stop(pid)
    end

    test "handles SGR (graphics) sequences" do
      {:ok, pid} = Raxol.Minimal.start_terminal()

      # Set bold
      Raxol.Minimal.send_input(pid, "\e[1m")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.char_attrs.bold == true

      # Set foreground color
      Raxol.Minimal.send_input(pid, "\e[31m")  # Red
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.char_attrs.fg_color == :red

      # Reset
      Raxol.Minimal.send_input(pid, "\e[0m")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.char_attrs.bold == false
      assert state.char_attrs.fg_color == :default

      GenServer.stop(pid)
    end

    test "processes printable characters", %{terminal: pid} do
      Raxol.Minimal.send_input(pid, "Hello")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)

      # Cursor should have moved 5 positions
      assert elem(state.cursor, 0) == 5

      GenServer.stop(pid)
    end

    test "respects terminal boundaries", %{terminal: pid} do
      # Try to move cursor beyond left boundary
      Raxol.Minimal.send_input(pid, "\e[D")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {0, 0}

      # Try to move beyond bottom
      Raxol.Minimal.send_input(pid, "\e[100B")
      Process.sleep(1)
      state = Raxol.Minimal.get_state(pid)
      {_x, y} = state.cursor
      assert y == 23  # Height is 24, so max y is 23

      GenServer.stop(pid)
    end
  end

  describe "terminal operations" do
    test "clear operation" do
      {:ok, pid} = Raxol.Minimal.start_terminal()

      # Add some content
      Raxol.Minimal.send_input(pid, "Test content")
      Process.sleep(1)

      # Clear
      :ok = Raxol.Minimal.clear(pid)
      Process.sleep(1)

      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {0, 0}

      GenServer.stop(pid)
    end

    test "reset operation" do
      {:ok, pid} = Raxol.Minimal.start_terminal()

      # Modify state
      Raxol.Minimal.send_input(pid, "\e[31mColored\e[5;10H")
      Process.sleep(1)

      # Reset
      :ok = Raxol.Minimal.reset(pid)
      Process.sleep(1)

      state = Raxol.Minimal.get_state(pid)
      assert state.cursor == {0, 0}
      assert state.char_attrs.fg_color == :default

      GenServer.stop(pid)
    end

    test "resize operation" do
      {:ok, pid} = Raxol.Minimal.start_terminal(width: 80, height: 24)

      :ok = Raxol.Minimal.resize(pid, 100, 30)

      {width, height} = Raxol.Minimal.get_dimensions(pid)
      assert width == 100
      assert height == 30

      state = Raxol.Minimal.get_state(pid)
      assert state.width == 100
      assert state.height == 30

      GenServer.stop(pid)
    end
  end

  describe "performance metrics" do
    test "tracks input metrics" do
      {:ok, pid} = Raxol.Minimal.start_terminal(telemetry: true)

      # Generate more input to ensure measurable timing on fast systems
      # Use longer strings to increase processing time
      for i <- 1..20 do
        Raxol.Minimal.send_input(pid, "Test input string #{i} with some content")
        Process.sleep(1)
      end

      metrics = Raxol.Minimal.get_metrics(pid)
      assert metrics.input_count == 20

      # On very fast systems (Windows CI), timing may be 0
      # Assert that timing metrics exist and are non-negative
      assert metrics.avg_input_time >= 0
      assert metrics.max_input_time >= 0

      GenServer.stop(pid)
    end
  end
end
