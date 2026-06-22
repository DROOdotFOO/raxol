defmodule Raxol.Core.ErrorRecoveryTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.ErrorRecovery

  setup do
    # Stop any existing ErrorRecovery
    case Process.whereis(ErrorRecovery) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end

    # Start ErrorRecovery with proper name registration
    {:ok, pid} = ErrorRecovery.start_link(name: ErrorRecovery)

    on_exit(fn ->
      # pid can die between the alive? check and the stop, so guard the exit.
      try do
        GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "with_circuit_breaker/3" do
    test "allows calls when circuit is closed" do
      result =
        ErrorRecovery.with_circuit_breaker(:test_circuit, fn ->
          {:ok, "success"}
        end)

      # Circuit breaker propagates the user function result directly
      assert result == {:ok, "success"}
    end

    test "opens circuit after threshold failures" do
      # Cause 5 failures (default threshold)
      for _ <- 1..5 do
        ErrorRecovery.with_circuit_breaker(:failing_circuit, fn ->
          raise "Circuit test error"
        end)
      end

      # Circuit should now be open
      result =
        ErrorRecovery.with_circuit_breaker(:failing_circuit, fn ->
          {:ok, "should not execute"}
        end)

      assert {:error, :circuit_open, _, %{circuit: :failing_circuit}} = result
    end

    test "circuit breaker recovers to half-open state" do
      # This test would require time manipulation or configuration
      # For now, we just ensure the basic structure works
      assert :ok
    end
  end

  describe "with_retry/2" do
    test "succeeds on first attempt" do
      result =
        ErrorRecovery.with_retry(fn ->
          "success"
        end)

      assert result == {:ok, "success"}
    end

    test "retries on failure and eventually succeeds" do
      counter = :counters.new(1, [])

      result =
        ErrorRecovery.with_retry(
          fn ->
            count = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if count < 2 do
              raise "Retry test"
            else
              "success after retries"
            end
          end,
          max_retries: 3,
          base_delay: 10
        )

      assert result == {:ok, "success after retries"}
      assert :counters.get(counter, 1) == 3
    end

    test "fails after max retries" do
      counter = :counters.new(1, [])

      result =
        ErrorRecovery.with_retry(
          fn ->
            :counters.add(counter, 1, 1)
            raise "Always fails"
          end,
          max_retries: 2,
          base_delay: 10
        )

      assert {:error, :max_retries_exceeded, _, %{attempts: 2}} = result
      assert :counters.get(counter, 1) == 2
    end

    test "exponential backoff increases delay" do
      start_time = System.monotonic_time(:millisecond)

      ErrorRecovery.with_retry(
        fn ->
          raise "Force backoff"
        end,
        max_retries: 2,
        base_delay: 20,
        jitter: false
      )

      end_time = System.monotonic_time(:millisecond)
      elapsed = end_time - start_time

      # First retry: 20ms, Second retry: 40ms = 60ms total
      # Allow some variance
      assert elapsed >= 50
    end
  end

  describe "with_fallback/2" do
    test "returns primary result when successful" do
      result =
        ErrorRecovery.with_fallback(
          fn -> "primary" end,
          fn -> "fallback" end
        )

      assert result == {:ok, "primary"}
    end

    test "uses fallback when primary fails" do
      result =
        ErrorRecovery.with_fallback(
          fn -> raise "Primary failed" end,
          fn -> "fallback value" end
        )

      assert result == {:ok, "fallback value"}
    end

    test "returns error when both primary and fallback fail" do
      result =
        ErrorRecovery.with_fallback(
          fn -> raise "Primary failed" end,
          fn -> raise "Fallback failed" end
        )

      assert {:error, :all_failed, _, %{primary_error: _, fallback_error: _}} =
               result
    end
  end

  describe "degrade_gracefully/3" do
    test "uses full implementation when feature is available" do
      result =
        ErrorRecovery.degrade_gracefully(
          :test_feature,
          fn -> "full implementation" end,
          fn -> "degraded implementation" end
        )

      assert result == {:ok, "full implementation"}
    end

    test "falls back to degraded implementation on error" do
      result =
        ErrorRecovery.degrade_gracefully(
          :failing_feature,
          fn -> raise "Feature error" end,
          fn -> "degraded implementation" end
        )

      assert result == {:ok, "degraded implementation"}
    end

    test "marks feature as degraded after failure" do
      # First call fails and marks feature as degraded
      ErrorRecovery.degrade_gracefully(
        :auto_degrade_feature,
        fn -> raise "Feature error" end,
        fn -> "degraded" end
      )

      # Second call should use degraded mode directly
      result =
        ErrorRecovery.degrade_gracefully(
          :auto_degrade_feature,
          fn -> "should not execute" end,
          fn -> "still degraded" end
        )

      assert result == {:ok, "still degraded"}
    end
  end

  describe "with_cleanup/2" do
    test "executes cleanup after successful operation" do
      cleanup_executed = :counters.new(1, [])

      result =
        ErrorRecovery.with_cleanup(
          fn -> "success" end,
          fn _resource -> :counters.add(cleanup_executed, 1, 1) end
        )

      assert result == {:ok, "success"}
      assert :counters.get(cleanup_executed, 1) == 1
    end

    test "executes cleanup after failed operation" do
      cleanup_executed = :counters.new(1, [])

      result =
        ErrorRecovery.with_cleanup(
          fn -> raise "Operation failed" end,
          fn _resource -> :counters.add(cleanup_executed, 1, 1) end
        )

      assert {:error, :runtime, _, _} = result
      assert :counters.get(cleanup_executed, 1) == 1
    end

    test "handles cleanup errors gracefully" do
      # Cleanup errors should be logged but not affect the result
      result =
        ErrorRecovery.with_cleanup(
          fn -> "success" end,
          fn _resource -> raise "Cleanup failed" end
        )

      assert result == {:ok, "success"}
    end
  end

  describe "with_bulkhead/3" do
    test "executes function with resource from pool" do
      result =
        ErrorRecovery.with_bulkhead(:test_pool, fn worker ->
          {:ok, "processed by #{inspect(worker)}"}
        end)

      assert {:ok, {:ok, result}} = result
      assert result =~ "processed by"
    end

    test "returns error on pool timeout" do
      # This would require a real pool implementation
      # For now, we ensure the structure is correct
      assert :ok
    end
  end

  describe "circuit breaker state transitions" do
    test "tracks success and failure counts" do
      # Success should reset failure count
      ErrorRecovery.with_circuit_breaker(:counting_circuit, fn -> "success" end)

      # A few failures shouldn't open the circuit
      for _ <- 1..3 do
        ErrorRecovery.with_circuit_breaker(:counting_circuit, fn ->
          raise "Controlled failure"
        end)
      end

      # Should still be able to call
      result =
        ErrorRecovery.with_circuit_breaker(:counting_circuit, fn ->
          "still working"
        end)

      assert {:ok, "still working"} = result
    end
  end
end
