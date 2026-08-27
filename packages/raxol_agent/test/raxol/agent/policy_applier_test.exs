defmodule Raxol.Agent.PolicyApplierTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Policy.{Cache, Retry, Timeout}
  alias Raxol.Agent.PolicyApplier

  setup do
    table = :"applier_test_#{System.unique_integer([:positive])}"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, table: table}
  end

  describe "empty policies" do
    test "calls fun directly and returns its result" do
      assert {:ok, 42} = PolicyApplier.apply([], fn :x -> {:ok, 42} end, :x)
    end

    test "passes params through" do
      assert {:ok, %{user_id: 7}} =
               PolicyApplier.apply([], fn p -> {:ok, p} end, %{user_id: 7})
    end
  end

  describe "Retry policy" do
    test "succeeds on first attempt without retries" do
      policy = Retry.exponential(max_attempts: 3, base_ms: 0)
      ref = make_ref()
      pid = self()

      result =
        PolicyApplier.apply(
          [policy],
          fn _ ->
            send(pid, {ref, :called})
            {:ok, :win}
          end,
          nil
        )

      assert {:ok, :win} = result
      assert_received {^ref, :called}
      # No second call
      refute_received {^ref, :called}
    end

    test "retries on matching error and eventually succeeds" do
      policy =
        Retry.exponential(
          max_attempts: 3,
          base_ms: 0,
          on: [:transient]
        )

      counter = :counters.new(1, [])

      fun = fn _ ->
        case :counters.add(counter, 1, 1) do
          :ok -> :noop
        end

        n = :counters.get(counter, 1)
        if n < 3, do: {:error, :transient}, else: {:ok, n}
      end

      assert {:ok, 3} = PolicyApplier.apply([policy], fun, nil)
    end

    test "exhausts attempts and returns the final error" do
      policy = Retry.exponential(max_attempts: 3, base_ms: 0, on: [:transient])

      counter = :counters.new(1, [])

      fun = fn _ ->
        _ = :counters.add(counter, 1, 1)
        {:error, :transient}
      end

      assert {:error, :transient} = PolicyApplier.apply([policy], fun, nil)
      assert :counters.get(counter, 1) == 3
    end

    test "non-retriable error short-circuits" do
      policy = Retry.exponential(max_attempts: 5, base_ms: 0, on: [:transient])

      counter = :counters.new(1, [])

      fun = fn _ ->
        _ = :counters.add(counter, 1, 1)
        {:error, :permanent}
      end

      assert {:error, :permanent} = PolicyApplier.apply([policy], fun, nil)
      assert :counters.get(counter, 1) == 1
    end
  end

  describe "Timeout policy" do
    test "returns the result when fun finishes in time" do
      policy = Timeout.new(1_000)

      assert {:ok, :fast} =
               PolicyApplier.apply([policy], fn _ -> {:ok, :fast} end, nil)
    end

    test "aborts with {:error, :timeout} when fun overruns" do
      policy = Timeout.new(50)

      fun = fn _ ->
        Process.sleep(500)
        {:ok, :too_late}
      end

      assert {:error, :timeout} = PolicyApplier.apply([policy], fun, nil)
    end
  end

  describe "Cache policy" do
    test "stores and reuses on second invocation", %{table: table} do
      policy =
        Cache.ets(
          ttl_ms: 60_000,
          key_fn: fn p -> p.id end,
          table: table
        )

      counter = :counters.new(1, [])

      fun = fn p ->
        _ = :counters.add(counter, 1, 1)
        {:ok, "result-for-#{p.id}"}
      end

      assert {:ok, "result-for-1"} =
               PolicyApplier.apply([policy], fun, %{id: 1})

      assert {:ok, "result-for-1"} =
               PolicyApplier.apply([policy], fun, %{id: 1})

      # Two calls but only one underlying invocation.
      assert :counters.get(counter, 1) == 1
    end

    test "different keys produce different cached entries", %{table: table} do
      policy = Cache.ets(ttl_ms: 60_000, key_fn: fn p -> p.id end, table: table)
      counter = :counters.new(1, [])

      fun = fn p ->
        _ = :counters.add(counter, 1, 1)
        {:ok, p.id * 2}
      end

      assert {:ok, 2} = PolicyApplier.apply([policy], fun, %{id: 1})
      assert {:ok, 4} = PolicyApplier.apply([policy], fun, %{id: 2})
      assert {:ok, 2} = PolicyApplier.apply([policy], fun, %{id: 1})

      assert :counters.get(counter, 1) == 2
    end

    test "errors are surfaced without caching", %{table: table} do
      policy = Cache.ets(ttl_ms: 60_000, key_fn: fn p -> p.id end, table: table)
      counter = :counters.new(1, [])

      fun = fn _ ->
        _ = :counters.add(counter, 1, 1)
        {:error, :upstream_down}
      end

      assert {:error, :upstream_down} =
               PolicyApplier.apply([policy], fun, %{id: 1})

      assert {:error, :upstream_down} =
               PolicyApplier.apply([policy], fun, %{id: 1})

      # No caching on errors -> two invocations.
      assert :counters.get(counter, 1) == 2
    end
  end

  describe "composition order" do
    test "Cache wraps Retry: cache hit short-circuits retry", %{table: table} do
      cache =
        Cache.ets(ttl_ms: 60_000, key_fn: fn p -> p.id end, table: table)

      retry = Retry.exponential(max_attempts: 5, base_ms: 0, on: [:transient])

      counter = :counters.new(1, [])

      fun = fn _ ->
        _ = :counters.add(counter, 1, 1)
        {:ok, :computed}
      end

      assert {:ok, :computed} =
               PolicyApplier.apply([cache, retry], fun, %{id: 1})

      assert {:ok, :computed} =
               PolicyApplier.apply([cache, retry], fun, %{id: 1})

      # Second call hits cache, never enters fn.
      assert :counters.get(counter, 1) == 1
    end

    test "Timeout wraps Retry: timeout aborts the in-flight retry", %{table: _t} do
      timeout = Timeout.new(50)
      retry = Retry.exponential(max_attempts: 10, base_ms: 0, on: [:transient])

      fun = fn _ ->
        Process.sleep(20)
        {:error, :transient}
      end

      # The retries run inside the timeout; total elapsed exceeds 50ms.
      assert {:error, :timeout} =
               PolicyApplier.apply([timeout, retry], fun, nil)
    end
  end

  describe "telemetry" do
    setup do
      handler_id = "policy_applier_test_#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:raxol, :agent, :policy, :cache_hit],
          [:raxol, :agent, :policy, :cache_miss],
          [:raxol, :agent, :policy, :retry_attempt],
          [:raxol, :agent, :policy, :retry_exhausted],
          [:raxol, :agent, :policy, :timeout],
          [:raxol, :agent, :policy, :applied]
        ],
        fn event, measurements, metadata, _ ->
          send(test_pid, {:tel, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "applied fires once per apply/3 call with the outcome tag" do
      PolicyApplier.apply([], fn _ -> {:ok, :ok_thing} end, nil)

      assert_receive {:tel, [:raxol, :agent, :policy, :applied], _, %{outcome: :ok}}

      PolicyApplier.apply([], fn _ -> {:error, :bad} end, nil)

      assert_receive {:tel, [:raxol, :agent, :policy, :applied], _, %{outcome: :error}}
    end

    test "retry_attempt fires with attempt + reason + backoff_ms" do
      policy = Retry.exponential(max_attempts: 3, base_ms: 0, on: [:transient])
      counter = :counters.new(1, [])

      fun = fn _ ->
        _ = :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        if n < 3, do: {:error, :transient}, else: {:ok, n}
      end

      PolicyApplier.apply([policy], fun, nil)

      assert_receive {:tel, [:raxol, :agent, :policy, :retry_attempt], _,
                      %{attempt: 1, reason: :transient, backoff_ms: _}}

      assert_receive {:tel, [:raxol, :agent, :policy, :retry_attempt], _,
                      %{attempt: 2, reason: :transient, backoff_ms: _}}
    end

    test "cache_miss + cache_hit fire on first + second call", %{table: table} do
      policy =
        Cache.ets(ttl_ms: 60_000, key_fn: fn _ -> :only_key end, table: table)

      PolicyApplier.apply([policy], fn _ -> {:ok, :v} end, nil)
      PolicyApplier.apply([policy], fn _ -> {:ok, :v} end, nil)

      assert_receive {:tel, [:raxol, :agent, :policy, :cache_miss], _, %{key: :only_key}}

      assert_receive {:tel, [:raxol, :agent, :policy, :cache_hit], _, %{key: :only_key}}
    end

    test "timeout fires when fun overruns" do
      policy = Timeout.new(20)

      PolicyApplier.apply(
        [policy],
        fn _ ->
          Process.sleep(200)
          {:ok, :late}
        end,
        nil
      )

      assert_receive {:tel, [:raxol, :agent, :policy, :timeout], _, %{wall_ms: 20}}
    end
  end
end
