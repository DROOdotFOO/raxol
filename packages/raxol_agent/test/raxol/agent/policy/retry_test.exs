defmodule Raxol.Agent.Policy.RetryTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Policy.Retry

  describe "constructors" do
    test "exponential/1 builds with required + defaults" do
      r = Retry.exponential(max_attempts: 3, base_ms: 100)
      assert r.max_attempts == 3
      assert r.base_ms == 100
      assert r.max_ms == :infinity
      assert r.mode == :exponential
      assert r.on == :any
    end

    test "exponential/1 respects :max_ms and :on" do
      r =
        Retry.exponential(
          max_attempts: 5,
          base_ms: 50,
          max_ms: 1_000,
          on: [:timeout, :transient]
        )

      assert r.max_ms == 1_000
      assert r.on == [:timeout, :transient]
    end

    test "linear/1 forces mode = :linear and max_ms = :infinity" do
      r = Retry.linear(max_attempts: 4, base_ms: 250)
      assert r.mode == :linear
      assert r.max_ms == :infinity
    end

    test "always/1 forces on = :any" do
      r = Retry.always(max_attempts: 3, base_ms: 100)
      assert r.on == :any
    end

    test "raises on invalid max_attempts" do
      assert_raise ArgumentError, ~r/max_attempts/, fn ->
        Retry.exponential(max_attempts: 0, base_ms: 100)
      end
    end

    test "raises on negative base_ms" do
      assert_raise ArgumentError, ~r/base_ms/, fn ->
        Retry.exponential(max_attempts: 3, base_ms: -1)
      end
    end
  end

  describe "backoff/2" do
    test "exponential doubles each attempt" do
      r = Retry.exponential(max_attempts: 5, base_ms: 100)
      assert Retry.backoff(r, 1) == 100
      assert Retry.backoff(r, 2) == 200
      assert Retry.backoff(r, 3) == 400
      assert Retry.backoff(r, 4) == 800
    end

    test "exponential caps at :max_ms" do
      r = Retry.exponential(max_attempts: 10, base_ms: 100, max_ms: 500)
      assert Retry.backoff(r, 1) == 100
      assert Retry.backoff(r, 2) == 200
      assert Retry.backoff(r, 3) == 400
      assert Retry.backoff(r, 4) == 500
      assert Retry.backoff(r, 5) == 500
    end

    test "linear is constant" do
      r = Retry.linear(max_attempts: 5, base_ms: 250)
      assert Retry.backoff(r, 1) == 250
      assert Retry.backoff(r, 3) == 250
    end
  end

  describe "retriable?/2" do
    test ":any matches everything" do
      r = Retry.always(max_attempts: 3, base_ms: 100)
      assert Retry.retriable?(r, :timeout)
      assert Retry.retriable?(r, {:error, :foo})
      assert Retry.retriable?(r, :anything)
    end

    test "list matches by membership" do
      r =
        Retry.exponential(
          max_attempts: 3,
          base_ms: 100,
          on: [:timeout, :transient]
        )

      assert Retry.retriable?(r, :timeout)
      assert Retry.retriable?(r, :transient)
      refute Retry.retriable?(r, :permanent)
    end

    test "function predicate" do
      r =
        Retry.exponential(
          max_attempts: 3,
          base_ms: 100,
          on: fn reason -> match?({:retry, _}, reason) end
        )

      assert Retry.retriable?(r, {:retry, :foo})
      refute Retry.retriable?(r, :permanent)
    end
  end
end
