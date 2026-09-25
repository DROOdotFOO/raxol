defmodule Raxol.Terminal.Integration.IOIntegrationTest do
  use ExUnit.Case
  @moduletag :integration

  alias Raxol.Terminal.Integration.Main

  setup do
    # Start the Manager process
    {:ok, _unified_window_pid} =
      Raxol.Terminal.Window.Manager.start_link()

    # Start the main integration module
    {:ok, pid} = Main.start_link(%{})
    %{pid: pid}
  end

  describe "input/output integration" do
    test "handles keyboard input and written output", %{pid: pid} do
      assert :ok = Main.handle_input(pid, {:key, ?a})
      assert :ok = Main.write(pid, "test output")
    end

    test "handles special keys", %{pid: pid} do
      # Test enter key
      assert :ok = Main.handle_input(pid, {:key, :enter})

      # Test arrow keys
      assert :ok = Main.handle_input(pid, {:key, :up})
      assert :ok = Main.handle_input(pid, {:key, :down})
      assert :ok = Main.handle_input(pid, {:key, :left})
      assert :ok = Main.handle_input(pid, {:key, :right})
    end

    test "handles mouse events", %{pid: pid} do
      # Test mouse click
      assert :ok = Main.handle_input(pid, {:mouse, {1, 1, :left}})

      # Test mouse movement
      assert :ok = Main.handle_input(pid, {:mouse, {2, 2, :move}})
    end

    test "handles terminal resize", %{pid: pid} do
      # Resize terminal
      assert :ok = Main.resize(pid, 100, 30)

      # Verify state is updated
      state = Main.get_state(pid)
      assert state.width == 100
      assert state.height == 30
    end

    test "handles configuration updates", %{pid: pid} do
      # Update config
      config = %{
        behavior: %{
          scrollback_limit: 2000,
          enable_command_history: true
        }
      }

      assert :ok = Main.update_config(pid, config)

      # Verify config is updated
      state = Main.get_state(pid)
      assert state.config.behavior.scrollback_limit == 2000
      assert state.config.behavior.enable_command_history == true
    end

    test "handles clear screen", %{pid: pid} do
      # Write some content
      assert :ok = Main.write(pid, "test content")

      # Clear screen
      assert :ok = Main.clear(pid)

      # Verify clear operation succeeded (just check state is still valid)
      state = Main.get_state(pid)
      assert is_map(state)
      assert is_struct(state.buffer_manager, Raxol.Terminal.ScreenBuffer.Manager)
    end
  end

  describe "error handling" do
    test "handles invalid input gracefully", %{pid: pid} do
      # Send invalid input
      assert :ok = Main.handle_input(pid, {:invalid, :input})

      # Verify system remains stable
      state = Main.get_state(pid)
      assert is_map(state)
    end

    test "handles invalid resize dimensions", %{pid: pid} do
      # Try invalid dimensions
      assert :ok = Main.resize(pid, -1, -1)

      # Verify system uses minimum dimensions
      state = Main.get_state(pid)
      assert state.width > 0
      assert state.height > 0
    end
  end

  describe "performance" do
    test "handles rapid input events", %{pid: pid} do
      # Send multiple input events rapidly
      for i <- 1..100 do
        assert :ok = Main.handle_input(pid, {:key, ?a + rem(i, 26)})
      end

      # Verify system remains responsive
      state = Main.get_state(pid)
      assert is_map(state)
    end

    test "handles large output data", %{pid: pid} do
      # Generate large output
      large_output = String.duplicate("test ", 1000)
      assert :ok = Main.write(pid, large_output)

      # Verify system handles it
      state = Main.get_state(pid)
      assert is_map(state)
    end
  end
end
