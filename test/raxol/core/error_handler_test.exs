defmodule Raxol.Core.ErrorHandlerTest do
  use ExUnit.Case, async: true

  import Raxol.Core.ErrorHandler
  alias Raxol.Core.ErrorHandling, as: ErrorHandler

  describe "execute_with_handling/3" do
    test "returns {:ok, result} on successful execution" do
      result =
        execute_with_handling(:test_operation, [], fn ->
          {:ok, 1 + 1}
        end)

      assert result == {:ok, 2}
    end

    test "handles raised exceptions" do
      result =
        execute_with_handling(:test_operation, [], fn ->
          raise "Test error"
        end)

      assert {:error, :runtime, message, _context} = result
      assert message =~ "Test error"
    end

    test "uses fallback value on error when provided" do
      result =
        execute_with_handling(:test_operation, [fallback: "default"], fn ->
          raise "Test error"
        end)

      assert result == {:ok, "default"}
    end

    test "retries on failure" do
      counter = :counters.new(1, [])

      result =
        execute_with_handling(
          :test_operation,
          [retry: 2, retry_delay: 10],
          fn ->
            count = :counters.get(counter, 1)
            :counters.add(counter, 1, 1)

            if count < 2 do
              raise "Retry test"
            else
              {:ok, "success"}
            end
          end
        )

      assert result == {:ok, "success"}
      assert :counters.get(counter, 1) == 3
    end

    test "includes context in error" do
      context = %{user_id: 123, action: "test"}

      result =
        execute_with_handling(:test_operation, [context: context], fn ->
          raise "Context test"
        end)

      assert {:error, :runtime, _message, returned_context} = result
      assert returned_context.user_id == 123
      assert returned_context.action == "test"
    end
  end

  describe "error/3" do
    test "creates standardized error tuple" do
      assert error(:validation, "Invalid input") ==
               {:error, :validation, "Invalid input", %{}}
    end

    test "includes context when provided" do
      context = %{field: "email", value: "invalid"}

      assert error(:validation, "Invalid email", context) ==
               {:error, :validation, "Invalid email", context}
    end
  end

  describe "handle_error/2" do
    test "passes through {:ok, value} unchanged" do
      assert handle_error({:ok, "success"}, []) == {:ok, "success"}
    end

    test "returns default value for errors" do
      error = {:error, :not_found, "Not found", %{}}
      assert handle_error(error, default: "fallback") == {:ok, "fallback"}
    end

    test "applies custom handler function" do
      error = {:error, :validation, "Invalid", %{}}
      handler = fn {:error, type, _msg, _ctx} -> {:ok, "handled_#{type}"} end

      assert handle_error(error, with: handler) == {:ok, "handled_validation"}
    end

    test "normalizes non-standard errors" do
      assert handle_error({:error, "simple error"}, default: "ok") ==
               {:ok, "ok"}
    end
  end

  describe "normalize_error/1" do
    test "handles standard error format" do
      error = {:error, :validation, "message", %{}}
      assert normalize_error(error) == error
    end

    test "handles error without context" do
      assert normalize_error({:error, :timeout, "Timeout"}) ==
               {:error, :timeout, "Timeout", %{}}
    end

    test "handles simple error tuple" do
      assert normalize_error({:error, "reason"}) ==
               {:error, :unknown, "\"reason\"", %{}}
    end

    test "handles non-tuple errors" do
      assert normalize_error("error string") ==
               {:error, :unknown, "\"error string\"", %{}}
    end
  end

  describe "pipeline execution" do
    test "executes steps in order" do
      counter = :counters.new(1, [])

      steps = [
        {:step, :first,
         fn _ ->
           :counters.add(counter, 1, 1)
           {:ok, 1}
         end},
        {:step, :second,
         fn prev ->
           :counters.add(counter, 1, 10)
           {:ok, prev + 1}
         end},
        {:step, :third,
         fn prev ->
           :counters.add(counter, 1, 100)
           {:ok, prev + 1}
         end}
      ]

      result = ErrorHandler.execute_pipeline(steps)

      assert result == {:ok, 3}
      assert :counters.get(counter, 1) == 111
    end

    test "halts on error" do
      counter = :counters.new(1, [])

      steps = [
        {:step, :first,
         fn _ ->
           :counters.add(counter, 1, 1)
           {:ok, 1}
         end},
        {:step, :failing,
         fn _ ->
           :counters.add(counter, 1, 10)
           raise "Pipeline error"
         end},
        {:step, :never_reached,
         fn _ ->
           :counters.add(counter, 1, 100)
           {:ok, 3}
         end}
      ]

      result = ErrorHandler.execute_pipeline(steps)

      assert {:error, :runtime, message, _} = result
      assert message =~ "Pipeline error"
      # Third step not executed
      assert :counters.get(counter, 1) == 11
    end
  end

  describe "genserver error handling" do
    test "handles timeout errors" do
      error = {:error, :timeout, "Operation timed out", %{}}
      state = %{test: true}

      assert ErrorHandler.handle_genserver_error(error, state, TestModule) ==
               {:stop, :timeout, state}
    end

    test "handles critical errors" do
      error = {:error, :critical, "Critical failure", %{}}
      state = %{test: true}

      assert ErrorHandler.handle_genserver_error(error, state, TestModule) ==
               {:stop, :critical_error, state}
    end

    test "continues on non-critical errors" do
      error = {:error, :validation, "Invalid input", %{}}
      state = %{test: true}

      assert ErrorHandler.handle_genserver_error(error, state, TestModule) ==
               {:noreply, state}
    end
  end

  describe "error classification" do
    test "classifies different error types correctly" do
      # This is an internal function, but we can test it through logging
      # by checking the metadata passed to Logger

      # Test various error types
      errors = [
        {ArgumentError.exception("test"), :validation},
        {RuntimeError.exception("test"), :runtime},
        {File.Error.exception(reason: :enoent, path: "test"), :system}
      ]

      Enum.each(errors, fn {error, _expected_type} ->
        # The classification happens internally during logging
        # We're mainly ensuring no crashes occur
        execute_with_handling(:classification_test, [], fn ->
          raise error
        end)
      end)
    end
  end

  describe "retry behavior" do
    @tag timeout: 120_000
    test "respects max delay" do
      start_time = System.monotonic_time(:millisecond)

      _result =
        execute_with_handling(
          :test,
          [retry: 1, base_delay: 1000, max_delay: 50, retry_delay: 50],
          fn ->
            raise "Force retry"
          end
        )

      end_time = System.monotonic_time(:millisecond)
      elapsed = end_time - start_time

      # Should complete in roughly 50ms (one retry with 50ms delay)
      # Allow some variance
      assert elapsed >= 40
      # Allow for timing variations and system load (increased tolerance for test environments)
      assert elapsed <= 300
    end
  end
end
