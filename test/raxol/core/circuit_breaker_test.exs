defmodule Raxol.Core.CircuitBreakerTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.CircuitBreaker

  defp start_breaker(opts \\ []) do
    defaults = [
      name: :"breaker_#{:erlang.unique_integer([:positive])}",
      failure_threshold: 3,
      success_threshold: 2,
      open_timeout: 100,
      half_open_open_timeout: 50,
      on_state_change: fn _, _ -> :ok end
    ]

    merged = Keyword.merge(defaults, opts)
    {:ok, pid} = CircuitBreaker.start_link(merged)
    name = Keyword.fetch!(merged, :name)
    {pid, name}
  end

  describe "closed state" do
    test "starts in closed state" do
      {_pid, name} = start_breaker()
      assert CircuitBreaker.state(name) == :closed
    end

    test "successful calls pass through" do
      {_pid, name} = start_breaker()
      assert {:ok, 42} = CircuitBreaker.call(name, fn -> 42 end)
    end

    test "failed calls increment failure count" do
      {_pid, name} = start_breaker()

      {:error, _} =
        CircuitBreaker.call(name, fn -> raise "boom" end)

      stats = CircuitBreaker.stats(name)
      assert stats.failure_count == 1
      assert stats.state == :closed
    end

    test "opens after reaching failure threshold" do
      {_pid, name} = start_breaker(failure_threshold: 3)

      for _ <- 1..3 do
        CircuitBreaker.call(name, fn -> raise "boom" end)
      end

      assert CircuitBreaker.state(name) == :open
    end

    test "resets failure count on success" do
      {_pid, name} = start_breaker(failure_threshold: 3)

      # Two failures
      CircuitBreaker.call(name, fn -> raise "boom" end)
      CircuitBreaker.call(name, fn -> raise "boom" end)

      # One success resets
      CircuitBreaker.call(name, fn -> :ok end)

      stats = CircuitBreaker.stats(name)
      assert stats.failure_count == 0
    end
  end

  describe "open state" do
    test "rejects calls when open" do
      {_pid, name} = start_breaker(failure_threshold: 1)

      CircuitBreaker.call(name, fn -> raise "boom" end)
      assert CircuitBreaker.state(name) == :open

      assert {:error, :circuit_open} = CircuitBreaker.call(name, fn -> :ok end)
    end

    test "tracks rejected calls in metrics" do
      {_pid, name} = start_breaker(failure_threshold: 1)

      CircuitBreaker.call(name, fn -> raise "boom" end)
      CircuitBreaker.call(name, fn -> :ok end)

      stats = CircuitBreaker.stats(name)
      assert stats.metrics.rejected_calls >= 1
    end

    test "transitions to half-open after timeout" do
      {_pid, name} = start_breaker(failure_threshold: 1, timeout: 50)

      CircuitBreaker.call(name, fn -> raise "boom" end)
      assert CircuitBreaker.state(name) == :open

      # Wait for timeout to trigger half-open transition
      Process.sleep(200)
      assert CircuitBreaker.state(name) == :half_open
    end
  end

  describe "half-open state" do
    setup do
      {_pid, name} = start_breaker(failure_threshold: 1, open_timeout: 50, success_threshold: 2)
      CircuitBreaker.call(name, fn -> raise "boom" end)
      Process.sleep(200)
      assert CircuitBreaker.state(name) == :half_open
      %{name: name}
    end

    test "closes after enough successes", %{name: name} do
      CircuitBreaker.call(name, fn -> :ok end)
      CircuitBreaker.call(name, fn -> :ok end)

      assert CircuitBreaker.state(name) == :closed
    end

    test "reopens on single failure", %{name: name} do
      CircuitBreaker.call(name, fn -> raise "fail again" end)
      assert CircuitBreaker.state(name) == :open
    end
  end

  describe "call_with_fallback/4" do
    test "returns result on success" do
      {_pid, name} = start_breaker()

      result = CircuitBreaker.call_with_fallback(name, fn -> 42 end, fn -> :fallback end)
      assert result == 42
    end

    test "calls fallback when circuit is open" do
      {_pid, name} = start_breaker(failure_threshold: 1)
      CircuitBreaker.call(name, fn -> raise "boom" end)

      result = CircuitBreaker.call_with_fallback(name, fn -> 42 end, fn -> :fallback end)
      assert result == :fallback
    end

    test "calls fallback on error" do
      {_pid, name} = start_breaker()

      result =
        CircuitBreaker.call_with_fallback(
          name,
          fn -> raise "boom" end,
          fn -> :fallback end
        )

      assert result == :fallback
    end
  end

  describe "reset/1" do
    test "manually resets to closed state" do
      {_pid, name} = start_breaker(failure_threshold: 1)
      CircuitBreaker.call(name, fn -> raise "boom" end)
      assert CircuitBreaker.state(name) == :open

      CircuitBreaker.reset(name)
      assert CircuitBreaker.state(name) == :closed

      # The half-open timeout armed when the breaker opened must not fire
      # into the closed state.
      Process.sleep(150)
      assert CircuitBreaker.state(name) == :closed
    end
  end

  describe "stats/1" do
    test "tracks call metrics" do
      {_pid, name} = start_breaker()

      CircuitBreaker.call(name, fn -> :ok end)
      CircuitBreaker.call(name, fn -> :ok end)
      CircuitBreaker.call(name, fn -> raise "boom" end)

      stats = CircuitBreaker.stats(name)
      assert stats.metrics.total_calls == 3
      assert stats.metrics.successful_calls == 2
      assert stats.metrics.failed_calls == 1
    end

    test "records state changes" do
      {_pid, name} = start_breaker(failure_threshold: 1)

      CircuitBreaker.call(name, fn -> raise "boom" end)

      stats = CircuitBreaker.stats(name)
      state_changes = stats.metrics.state_changes
      assert [_ | _] = state_changes
      assert hd(state_changes).state == :open
    end
  end

  describe "error handling" do
    test "catches exits" do
      {_pid, name} = start_breaker()

      assert {:error, {:exit, :shutdown}} =
               CircuitBreaker.call(name, fn -> exit(:shutdown) end)
    end

    test "catches throws" do
      {_pid, name} = start_breaker()

      assert {:error, {:throw, :oops}} =
               CircuitBreaker.call(name, fn -> throw(:oops) end)
    end

    test "catches raised exceptions" do
      {_pid, name} = start_breaker()

      {:error, error} = CircuitBreaker.call(name, fn -> raise "test error" end)
      assert %RuntimeError{message: "test error"} = error
    end
  end

  describe "on_state_change callback" do
    test "fires on state transitions" do
      test_pid = self()

      {_pid, name} =
        start_breaker(
          failure_threshold: 1,
          on_state_change: fn from, to -> send(test_pid, {:state_change, from, to}) end
        )

      CircuitBreaker.call(name, fn -> raise "boom" end)
      assert_receive {:state_change, :closed, :open}, 500
    end
  end
end
