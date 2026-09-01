defmodule Raxol.Core.TokenBucketTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.TokenBucket

  # capacity 10, one token back every 100ms
  @limit [capacity: 10, refill_per_second: 10.0]

  setup do
    {:ok, table: TokenBucket.new()}
  end

  defp limit(extra), do: Keyword.merge(@limit, extra)

  defp drain(table, key, count, at) do
    Enum.each(1..count, fn _ -> {:ok, _} = TokenBucket.take(table, key, limit(now_ms: at)) end)
  end

  describe "a bucket that has never been seen" do
    test "starts full, so the first take leaves capacity minus one", %{table: table} do
      assert {:ok, 9.0} = TokenBucket.take(table, "origin", limit(now_ms: 0))
    end

    test "reports full capacity from peek without creating it", %{table: table} do
      assert TokenBucket.peek(table, "origin", limit(now_ms: 0)) == 10.0
      assert :ets.lookup(table, "origin") == []
    end
  end

  describe "bursting" do
    test "admits exactly capacity calls before refusing", %{table: table} do
      drain(table, "origin", 10, 0)

      assert TokenBucket.take(table, "origin", limit(now_ms: 0)) == {:error, :rate_limited}
    end

    test "refuses every further call while the bucket stays empty", %{table: table} do
      drain(table, "origin", 10, 0)

      for _ <- 1..5 do
        assert TokenBucket.take(table, "origin", limit(now_ms: 0)) == {:error, :rate_limited}
      end
    end

    test "a refusal does not consume anything, so peek still reads zero", %{table: table} do
      drain(table, "origin", 10, 0)

      assert TokenBucket.take(table, "origin", limit(now_ms: 0)) == {:error, :rate_limited}
      assert TokenBucket.peek(table, "origin", limit(now_ms: 0)) == 0.0
    end
  end

  describe "refill over elapsed time" do
    test "regains one token per refill interval", %{table: table} do
      drain(table, "origin", 10, 0)

      assert TokenBucket.peek(table, "origin", limit(now_ms: 100)) == 1.0
      assert TokenBucket.peek(table, "origin", limit(now_ms: 500)) == 5.0
    end

    test "an emptied bucket admits again once one token has accrued", %{table: table} do
      drain(table, "origin", 10, 0)

      assert TokenBucket.take(table, "origin", limit(now_ms: 99)) == {:error, :rate_limited}
      assert {:ok, +0.0} = TokenBucket.take(table, "origin", limit(now_ms: 100))
    end

    test "never refills past capacity, however long the bucket sits idle", %{table: table} do
      drain(table, "origin", 10, 0)

      assert TokenBucket.peek(table, "origin", limit(now_ms: 10_000_000)) == 10.0
      assert {:ok, 9.0} = TokenBucket.take(table, "origin", limit(now_ms: 10_000_000))
    end

    test "preserves fractional tokens across takes", %{table: table} do
      drain(table, "origin", 10, 0)

      # 150ms accrues 1.5 tokens; taking one must leave the half behind
      assert {:ok, remaining} = TokenBucket.take(table, "origin", limit(now_ms: 150))
      assert_in_delta remaining, 0.5, 1.0e-9

      # a further 50ms accrues 0.5, which with the carried half funds one more take
      assert {:ok, after_second} = TokenBucket.take(table, "origin", limit(now_ms: 200))
      assert_in_delta after_second, 0.0, 1.0e-9
    end

    test "sustains exactly the refill rate over a long run", %{table: table} do
      drain(table, "origin", 10, 0)

      # one take every 100ms is precisely the refill rate, so all 50 must be admitted
      for tick <- 1..50 do
        assert {:ok, _} = TokenBucket.take(table, "origin", limit(now_ms: tick * 100))
      end

      # and asking a millisecond early is one short
      assert TokenBucket.take(table, "origin", limit(now_ms: 5099)) == {:error, :rate_limited}
    end
  end

  describe "independent keys" do
    test "draining one key leaves another untouched", %{table: table} do
      drain(table, "trongrid", 10, 0)

      assert TokenBucket.take(table, "trongrid", limit(now_ms: 0)) == {:error, :rate_limited}
      assert {:ok, 9.0} = TokenBucket.take(table, "blockscout", limit(now_ms: 0))
    end

    test "one table holds keys carrying different limits", %{table: table} do
      slow = [capacity: 2, refill_per_second: 1.0, now_ms: 0]

      assert {:ok, 1.0} = TokenBucket.take(table, "slow", slow)
      assert {:ok, +0.0} = TokenBucket.take(table, "slow", slow)
      assert TokenBucket.take(table, "slow", slow) == {:error, :rate_limited}
      assert {:ok, 9.0} = TokenBucket.take(table, "fast", limit(now_ms: 0))
    end

    test "keys may be any term, not only strings", %{table: table} do
      assert {:ok, 9.0} = TokenBucket.take(table, {:evm, 8453}, limit(now_ms: 0))
      assert {:ok, 9.0} = TokenBucket.take(table, {:evm, 137}, limit(now_ms: 0))
    end
  end

  describe "cost" do
    test "takes more than one token at a time", %{table: table} do
      assert {:ok, 6.0} = TokenBucket.take(table, "origin", limit(cost: 4, now_ms: 0))
      assert {:ok, 2.0} = TokenBucket.take(table, "origin", limit(cost: 4, now_ms: 0))

      assert TokenBucket.take(table, "origin", limit(cost: 4, now_ms: 0)) ==
               {:error, :rate_limited}
    end

    test "a cost of exactly capacity is takeable from a full bucket", %{table: table} do
      assert {:ok, +0.0} = TokenBucket.take(table, "origin", limit(cost: 10, now_ms: 0))
    end

    test "a cost above capacity raises rather than refusing forever", %{table: table} do
      assert_raise ArgumentError, ~r/could never be taken/, fn ->
        TokenBucket.take(table, "origin", limit(cost: 11, now_ms: 0))
      end
    end

    test "a non-positive cost raises", %{table: table} do
      assert_raise ArgumentError, ~r/:cost must be a positive number/, fn ->
        TokenBucket.take(table, "origin", limit(cost: 0, now_ms: 0))
      end
    end
  end

  describe "clock" do
    test "a clock that moves backwards does not drain the bucket", %{table: table} do
      assert {:ok, 9.0} = TokenBucket.take(table, "origin", limit(now_ms: 1000))
      assert {:ok, 8.0} = TokenBucket.take(table, "origin", limit(now_ms: 0))
      assert TokenBucket.peek(table, "origin", limit(now_ms: 0)) == 8.0
    end

    test "defaults to the monotonic clock when none is injected", %{table: table} do
      assert {:ok, 9.0} = TokenBucket.take(table, "origin", @limit)
    end
  end

  describe "retry_after/3" do
    test "is zero while the bucket can cover the cost", %{table: table} do
      assert TokenBucket.retry_after(table, "origin", limit(now_ms: 0)) == 0

      drain(table, "origin", 9, 0)

      assert TokenBucket.retry_after(table, "origin", limit(now_ms: 0)) == 0
    end

    test "reports the wait for one token once the bucket is empty", %{table: table} do
      drain(table, "origin", 10, 0)

      assert TokenBucket.retry_after(table, "origin", limit(now_ms: 0)) == 100
      assert TokenBucket.retry_after(table, "origin", limit(now_ms: 40)) == 60
    end

    test "rounds up, so waiting that long always succeeds", %{table: table} do
      drain(table, "origin", 10, 0)

      wait = TokenBucket.retry_after(table, "origin", limit(now_ms: 1))
      assert wait == 99
      assert {:ok, _} = TokenBucket.take(table, "origin", limit(now_ms: 1 + wait))
    end

    test "scales with the cost being waited for", %{table: table} do
      drain(table, "origin", 10, 0)

      assert TokenBucket.retry_after(table, "origin", limit(cost: 5, now_ms: 0)) == 500
    end
  end

  describe "reset" do
    test "reset/2 refills one key and leaves the others", %{table: table} do
      drain(table, "a", 10, 0)
      drain(table, "b", 10, 0)

      assert TokenBucket.reset(table, "a") == :ok
      assert {:ok, 9.0} = TokenBucket.take(table, "a", limit(now_ms: 0))
      assert TokenBucket.take(table, "b", limit(now_ms: 0)) == {:error, :rate_limited}
    end

    test "reset_all/1 refills every key", %{table: table} do
      drain(table, "a", 10, 0)
      drain(table, "b", 10, 0)

      assert TokenBucket.reset_all(table) == :ok
      assert {:ok, 9.0} = TokenBucket.take(table, "a", limit(now_ms: 0))
      assert {:ok, 9.0} = TokenBucket.take(table, "b", limit(now_ms: 0))
    end

    test "resetting a key that was never seen is harmless", %{table: table} do
      assert TokenBucket.reset(table, "missing") == :ok
    end
  end

  describe "required options" do
    test "capacity must be given, because the upstream owns the limit", %{table: table} do
      assert_raise ArgumentError, ~r/:capacity is required/, fn ->
        TokenBucket.take(table, "origin", refill_per_second: 1.0)
      end
    end

    test "refill_per_second must be given", %{table: table} do
      assert_raise ArgumentError, ~r/:refill_per_second is required/, fn ->
        TokenBucket.take(table, "origin", capacity: 10)
      end
    end

    test "a non-positive capacity raises", %{table: table} do
      assert_raise ArgumentError, ~r/:capacity must be a positive number/, fn ->
        TokenBucket.take(table, "origin", capacity: 0, refill_per_second: 1.0)
      end
    end

    test "a non-numeric refill rate raises", %{table: table} do
      assert_raise ArgumentError, ~r/:refill_per_second must be a positive number/, fn ->
        TokenBucket.take(table, "origin", capacity: 10, refill_per_second: :fast)
      end
    end
  end

  describe "concurrent takes" do
    # Every task blocks on a barrier and is released together, which is what makes the
    # takes genuinely overlap. Replacing the compare-and-swap commit with a plain
    # `:ets.insert/2` admits 11 or 12 under this workload, so these assertions have teeth.
    # A frozen clock means zero refill, so capacity is the entire budget and any
    # over-admission is a lost update rather than a timing artefact.
    @tasks 400

    defp burst(keys, work) do
      parent = self()

      pids =
        Enum.map(keys, fn key ->
          spawn(fn ->
            send(parent, {:ready, self()})
            receive do: (:go -> :ok)
            send(parent, {:took, key, work.(key)})
          end)
        end)

      Enum.each(pids, fn _ -> receive do: ({:ready, _pid} -> :ok) end)
      Enum.each(pids, &send(&1, :go))

      Enum.reduce(pids, %{}, fn _pid, acc ->
        receive do
          {:took, key, {:ok, _remaining}} -> Map.update(acc, key, 1, &(&1 + 1))
          {:took, _key, {:error, :rate_limited}} -> acc
        after
          5000 -> flunk("a burst task never reported")
        end
      end)
    end

    test "admit exactly capacity when the clock is held still", %{table: table} do
      opts = limit(now_ms: 0)
      keys = List.duplicate("origin", @tasks)

      assert burst(keys, &TokenBucket.take(table, &1, opts)) == %{"origin" => 10}
      assert TokenBucket.peek(table, "origin", opts) == 0.0
    end

    test "keep each key's budget separate under contention", %{table: table} do
      opts = limit(now_ms: 0)
      keys = Enum.map(1..@tasks, &Enum.at(["a", "b", "c"], rem(&1, 3)))

      assert burst(keys, &TokenBucket.take(table, &1, opts)) == %{"a" => 10, "b" => 10, "c" => 10}
    end
  end

  describe "table isolation" do
    test "two tables track the same key independently", %{table: table} do
      other = TokenBucket.new()
      drain(table, "origin", 10, 0)

      assert TokenBucket.take(table, "origin", limit(now_ms: 0)) == {:error, :rate_limited}
      assert {:ok, 9.0} = TokenBucket.take(other, "origin", limit(now_ms: 0))
    end
  end
end
