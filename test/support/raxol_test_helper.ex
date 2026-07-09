defmodule Raxol.Test.TestHelper do
  @moduledoc """
  Provides common test utilities and setup functions for Raxol tests.

  This module includes:
  - Test environment setup
  - Mock data generation
  - Common test scenarios
  - Cleanup utilities
  """

  use ExUnit.CaseTemplate

  @doc """
  Sets up a test environment with all necessary dependencies.

  Returns a context map with initialized services.
  """
  def setup_test_env do
    # Start event system
    Raxol.Core.Events.EventManager.init()
    # Create test terminal
    terminal = setup_test_terminal()

    {:ok,
     %{
       terminal: terminal
     }}
  end

  @doc """
  Creates a mock terminal for testing.
  """
  def setup_test_terminal do
    %{
      width: 80,
      height: 24,
      output: [],
      cursor: {0, 0}
    }
  end

  @doc """
  Generates test events for common scenarios.
  """
  def test_events do
    # Delegate to the main test helper
    Raxol.Test.TestHelper.test_events()
  end

  @doc """
  Creates a test component with the given module and initial state.
  """
  def test_layouts do
    %{
      full_screen: %{
        x: 0,
        y: 0,
        width: 80,
        height: 24
      },
      centered: %{
        x: 20,
        y: 5,
        width: 40,
        height: 14
      },
      sidebar: %{
        x: 0,
        y: 0,
        width: 20,
        height: 24
      }
    }
  end

  @doc """
  Cleans up test resources and resets the environment.
  """
  @dialyzer {:nowarn_function, cleanup_test_env: 1}
  def cleanup_test_env(_context) do
    :ok
  end

  @doc """
  Captures all terminal output during a test.
  """
  def capture_terminal_output(fun) when is_function(fun, 0) do
    # Delegate to the main test helper
    Raxol.Test.TestHelper.capture_terminal_output(fun)
  end

  # Private Helpers

  @doc """
  Waits for a condition to be true, with a timeout.
  Uses event-based synchronization instead of Process.sleep.
  """
  def wait_for_state(condition_fun, timeout_ms \\ 100) do
    start = System.monotonic_time(:millisecond)
    ref = System.unique_integer([:positive])
    do_wait_for_state(condition_fun, start, timeout_ms, ref)
  end

  defp do_wait_for_state(condition_fun, start, timeout_ms, ref) do
    case condition_fun.() do
      true ->
        :ok

      false ->
        handle_wait_timeout(
          System.monotonic_time(:millisecond) - start < timeout_ms,
          condition_fun,
          start,
          timeout_ms,
          ref
        )
    end
  end

  defp handle_wait_timeout(true, condition_fun, start, timeout_ms, ref) do
    Process.send_after(self(), {:check_condition, ref}, 100)

    receive do
      {:check_condition, received_ref} when received_ref == ref ->
        do_wait_for_state(condition_fun, start, timeout_ms, ref)
    after
      timeout_ms ->
        flunk("Condition not met within \\#{timeout_ms}ms")
    end
  end

  defp handle_wait_timeout(false, _condition_fun, _start, timeout_ms, _ref) do
    flunk("Condition not met within \\#{timeout_ms}ms")
  end

  @doc """
  Cleans up a process and waits for it to be down.
  """
  def cleanup_process(pid, timeout \\ 5000) do
    case Process.alive?(pid) do
      true ->
        ref = Process.monitor(pid)
        Process.exit(pid, :normal)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          timeout -> :timeout
        end

      false ->
        :ok
    end
  end

  defdelegate cleanup_ets_table(table), to: Raxol.Test.TestUtils

  @doc """
  Cleans up a registry.
  """
  def cleanup_registry(registry) do
    case Process.whereis(registry) do
      nil -> :ok
      _ -> Registry.unregister(registry, self())
    end
  end

  @doc """
  Creates a temporary directory for test files.
  """
  def create_temp_dir do
    dir = Path.join(System.tmp_dir!(), "raxol_test_#{:rand.uniform(1_000_000)}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Cleans up a temporary directory.
  """
  def cleanup_temp_dir(dir) do
    File.rm_rf!(dir)
  end
end
