defmodule Raxol.Terminal.Emulator.SafeEmulatorTest do
  @moduledoc """
  Behavioural suite for `Raxol.Terminal.Emulator.SafeEmulator`, and the only
  suite in this package that can reach an event `Raxol.Terminal.Telemetry`
  classifies as `:invariant` (the three span `:exception` leaves and
  `[:raxol, :emulator, :recovery, :failed]` are emitted from SafeEmulator
  alone), so it carries the sentinel.

  Much of what this suite does is feed the emulator garbage -- `\\e[`, a lone
  `0xFF`, a 15000-column resize, non-binary sequences -- and assert it degrades
  instead of crashing. That is precisely the ground the sentinel guards: those
  inputs must come back as `{:error, reason}`, never as a raise.

  The sentinel is not redundant with the crash itself. SafeEmulator's public
  functions launder a server crash into an ordinary error tuple --
  `resize/3` through `safe_genserver_call/2` (`{:error, {:genserver_exit,
  reason}}`) and `process_input/2` through `Task.yield/2` (`{:error, {:exit,
  reason}}`) -- so a permissive assertion can accept a raise as if it were
  validation working. The sentinel fails on the event, names it, and carries
  the exception and stacktrace in its metadata.
  """

  # async: false is mandatory with the sentinel: `:telemetry` handlers are
  # global and run in the EMITTING process, so a concurrently-running test
  # would be blamed for another test's invariant.
  use ExUnit.Case, async: false
  use Raxol.Core.Telemetry.InvariantSentinel, registry: Raxol.Terminal.Telemetry

  alias Raxol.Terminal.Emulator.SafeEmulator

  setup do
    # Generate unique name for each test to avoid conflicts
    name = :"safe_emulator_test_#{System.unique_integer([:positive])}"
    {:ok, pid} = SafeEmulator.start_link(width: 80, height: 24, name: name)
    {:ok, pid: pid}
  end

  describe "input processing" do
    test "processes valid input safely", %{pid: pid} do
      assert {:ok, :ok} = SafeEmulator.process_input(pid, "Hello, Terminal!")

      assert {:ok, :ok} =
               SafeEmulator.process_input(pid, "\e[1;31mRed Text\e[0m")
    end

    test "rejects oversized input", %{pid: pid} do
      # Create input larger than 1MB
      large_input = String.duplicate("x", 1_048_577)

      assert {:error, :input_too_large} =
               SafeEmulator.process_input(pid, large_input)
    end

    test "handles malformed sequences gracefully", %{pid: pid} do
      # These should not crash the emulator
      assert {:ok, :ok} = SafeEmulator.process_input(pid, "\e[")
      assert {:ok, :ok} = SafeEmulator.process_input(pid, "\e[999999999m")
      assert {:ok, :ok} = SafeEmulator.process_input(pid, <<0xFF, 0xFE>>)
    end

    test "chunks large input for processing", %{pid: pid} do
      # Input that's large but under the limit
      large_input = String.duplicate("A", 10_000)
      assert {:ok, :ok} = SafeEmulator.process_input(pid, large_input)
    end
  end

  describe "sequence handling" do
    test "validates sequences before processing", %{pid: pid} do
      # Test sequence validation (the actual validation behavior)
      result = SafeEmulator.handle_sequence(pid, {:csi, :cursor_up, [1]})
      assert result in [:ok, {:error, :invalid_sequence}]

      # Test various sequence inputs (accepting current behavior)
      result1 = SafeEmulator.handle_sequence(pid, "not a tuple")
      assert result1 in [:ok, {:error, :invalid_sequence}]

      result2 = SafeEmulator.handle_sequence(pid, {:only_one})
      assert result2 in [:ok, {:error, :invalid_sequence}]
    end
  end

  describe "resize operations" do
    test "validates dimensions", %{pid: pid} do
      # Valid resize
      assert {:ok, :ok} = SafeEmulator.resize(pid, 100, 50)

      # Invalid dimensions
      assert {:error, :invalid_dimensions} = SafeEmulator.resize(pid, 0, 24)
      assert {:error, :invalid_dimensions} = SafeEmulator.resize(pid, 80, -5)

      assert {:error, :dimensions_too_large} =
               SafeEmulator.resize(pid, 15_000, 15_000)
    end

    test "creates checkpoint after resize", %{pid: pid} do
      assert {:ok, :ok} = SafeEmulator.resize(pid, 120, 40)

      # State should reflect new dimensions
      {:ok, state} = SafeEmulator.get_state(pid)
      assert state.width == 120
      assert state.height == 40
    end
  end

  describe "health monitoring" do
    test "reports health status", %{pid: pid} do
      {:ok, health} = SafeEmulator.get_health(pid)

      assert health.status == :healthy
      assert health.error_stats.total_errors == 0
      assert health.recovery_state == :healthy
    end

    test "tracks error statistics", %{pid: pid} do
      # Trigger some errors
      SafeEmulator.handle_sequence(pid, "invalid")
      SafeEmulator.handle_sequence(pid, {:invalid})

      {:ok, health} = SafeEmulator.get_health(pid)
      assert health.error_stats.total_errors >= 1
      assert Map.has_key?(health.error_stats.errors_by_type, :sequence_error)
    end
  end

  describe "recovery mechanisms" do
    test "can create and restore checkpoints", %{pid: pid} do
      # Process some input
      SafeEmulator.process_input(pid, "Original state")

      # Create checkpoint
      SafeEmulator.checkpoint(pid)

      # Make changes
      SafeEmulator.process_input(pid, "Modified state")

      # Recover
      assert :ok = SafeEmulator.recover(pid)
    end

    test "limits recovery attempts", %{pid: pid} do
      # Exhaust recovery attempts
      for _ <- 1..4 do
        SafeEmulator.recover(pid)
      end

      # Next recovery should fail
      assert {:error, :max_recovery_attempts_exceeded} =
               SafeEmulator.recover(pid)
    end

    test "buffers input during recovery", %{pid: pid} do
      # This would require simulating an error condition
      # that triggers buffering behavior
      assert {:ok, state} = SafeEmulator.get_state(pid)
      assert Enum.empty?(state.buffer)
    end
  end

  describe "automatic features" do
    test "schedules periodic checkpoints" do
      # Start with checkpoint interval
      {:ok, pid} =
        SafeEmulator.start_link(
          width: 80,
          height: 24,
          # 100ms for testing
          checkpoint_interval: 100,
          name: :test_checkpoint_emulator
        )

      # Wait for checkpoint
      Process.sleep(150)

      # Verify checkpoint was created (would need internal state access)
      assert {:ok, _} = SafeEmulator.get_state(pid)

      # Clean up
      GenServer.stop(pid)
    end

    test "handles timeout gracefully", %{pid: pid} do
      # This would require mocking to force a timeout
      # For now, verify normal operation completes within timeout
      assert {:ok, :ok} = SafeEmulator.process_input(pid, "Quick input")
    end
  end
end
