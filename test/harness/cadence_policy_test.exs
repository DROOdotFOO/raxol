defmodule Raxol.Harness.CadencePolicyTest do
  use ExUnit.Case, async: true

  alias Raxol.Harness.CadencePolicy

  describe "constant accessors" do
    test "flush_interval_ms/0" do
      assert CadencePolicy.flush_interval_ms() == 16
    end

    test "max_drain_per_flush/0" do
      assert CadencePolicy.max_drain_per_flush() == 32
    end

    test "input_yield_retry_ms/0" do
      assert CadencePolicy.input_yield_retry_ms() == 1
    end
  end

  describe "decide/5 -- never flushed" do
    test "last_flush_ms nil always flushes now (cadence has no memory yet)" do
      assert CadencePolicy.decide(1_000, nil, 1, false) == :flush_now
    end

    test "nil last_flush beats a huge now_ms too" do
      assert CadencePolicy.decide(1_000_000, nil, 5, false) == :flush_now
    end
  end

  describe "decide/5 -- cadence elapsed" do
    test "elapsed exactly equal to interval flushes (boundary is inclusive)" do
      assert CadencePolicy.decide(1_016, 1_000, 3, false) == :flush_now
    end

    test "elapsed greater than interval flushes" do
      assert CadencePolicy.decide(2_000, 1_000, 3, false) == :flush_now
    end
  end

  describe "decide/5 -- cadence not yet elapsed" do
    test "elapsed 5ms of 16ms window defers by exact remainder" do
      assert CadencePolicy.decide(1_005, 1_000, 3, false) == {:defer, 11}
    end

    test "elapsed 15ms of 16ms window defers by 1ms" do
      assert CadencePolicy.decide(1_015, 1_000, 3, false) == {:defer, 1}
    end

    test "defer is always >= 1 by construction" do
      {:defer, remaining} = CadencePolicy.decide(1_001, 1_000, 3, false)
      assert remaining >= 1
    end
  end

  describe "decide/5 -- input priority" do
    test "input pending yields even when cadence is fully elapsed" do
      assert CadencePolicy.decide(2_000, 1_000, 3, true) == :yield_to_input
    end

    test "input pending yields even when last_flush_ms is nil (beats first paint)" do
      assert CadencePolicy.decide(1_000, nil, 1, true) == :yield_to_input
    end

    test "input pending yields mid-window too" do
      assert CadencePolicy.decide(1_005, 1_000, 3, true) == :yield_to_input
    end
  end

  describe "decide/5 -- guard" do
    test "pending_count == 0 crashes loudly (caller bug)" do
      assert_raise FunctionClauseError, fn ->
        CadencePolicy.decide(1_000, nil, 0, false)
      end
    end

    test "negative pending_count crashes loudly too" do
      assert_raise FunctionClauseError, fn ->
        CadencePolicy.decide(1_000, nil, -1, false)
      end
    end
  end

  describe "decide/5 -- :flush_interval_ms override" do
    test "override changes the flush-now boundary" do
      assert CadencePolicy.decide(1_100, 1_000, 3, false,
               flush_interval_ms: 100
             ) ==
               :flush_now
    end

    test "override changes the defer arithmetic" do
      assert CadencePolicy.decide(1_050, 1_000, 3, false,
               flush_interval_ms: 100
             ) ==
               {:defer, 50}
    end

    test "override still respects input priority" do
      assert CadencePolicy.decide(1_050, 1_000, 3, true, flush_interval_ms: 100) ==
               :yield_to_input
    end
  end

  describe "drain_count/2" do
    test "caps at the default max_drain_per_flush" do
      assert CadencePolicy.drain_count(1_000) == 32
    end

    test "passes through counts below the cap" do
      assert CadencePolicy.drain_count(5) == 5
    end

    test "exact boundary passes through" do
      assert CadencePolicy.drain_count(32) == 32
    end

    test "honors the :max_drain_per_flush override" do
      assert CadencePolicy.drain_count(1_000, max_drain_per_flush: 10) == 10
    end

    test "override does not raise the cap for small counts" do
      assert CadencePolicy.drain_count(5, max_drain_per_flush: 10) == 5
    end
  end

  describe "table-driven verdicts, including a burst-coalescing narrative" do
    # {now_ms, last_flush_ms, pending_count, input_pending?, expected}
    table = [
      # First delta of a fresh stream paints immediately.
      {1_000, nil, 1, false, :flush_now},
      # A burst arrives across several timestamps, all inside the same
      # 16ms window opened by last_flush_ms = 1_000: every one of these
      # defers to the *same* deadline (1_016), which is how a token
      # flood coalesces into a single scheduled flush instead of one
      # timer per delta.
      {1_001, 1_000, 2, false, {:defer, 15}},
      {1_003, 1_000, 5, false, {:defer, 13}},
      {1_009, 1_000, 12, false, {:defer, 7}},
      {1_015, 1_000, 40, false, {:defer, 1}},
      # The window closes: the next flush is due.
      {1_016, 1_000, 41, false, :flush_now},
      {1_020, 1_000, 41, false, :flush_now},
      # Input always preempts, regardless of where we are in the window.
      {1_001, 1_000, 2, true, :yield_to_input},
      {1_016, 1_000, 41, true, :yield_to_input},
      {1_000, nil, 1, true, :yield_to_input}
    ]

    for {now, last, pending, input?, expected} <- table do
      test "decide(#{now}, #{inspect(last)}, #{pending}, #{input?}) == #{inspect(expected)}" do
        assert CadencePolicy.decide(
                 unquote(now),
                 unquote(last),
                 unquote(pending),
                 unquote(input?)
               ) == unquote(Macro.escape(expected))
      end
    end
  end
end
