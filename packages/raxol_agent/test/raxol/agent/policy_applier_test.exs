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

    test "the wrapped argument never reaches metadata; a digest joins the events",
         %{table: table} do
      # At the one production call site the argument is the LLM turn payload,
      # i.e. the prompt, and ThreadLogRouter persists every metadata key. The
      # marker below must not appear anywhere in what is emitted.
      params = %{messages: [%{role: :user, content: "SECRET-PROMPT-7f3a"}]}
      policy = Cache.ets(ttl_ms: 60_000, key_fn: fn _ -> :k end, table: table)

      PolicyApplier.apply([policy], fn _ -> {:ok, :v} end, params)

      assert_receive {:tel, [:raxol, :agent, :policy, :cache_miss], _, miss}
      assert_receive {:tel, [:raxol, :agent, :policy, :applied], _, applied}

      for metadata <- [miss, applied] do
        refute Map.has_key?(metadata, :params)
        refute inspect(metadata) =~ "SECRET-PROMPT"
        assert metadata.params_digest =~ ~r/\A[0-9a-f]{16}\z/
      end

      assert miss.params_digest == applied.params_digest

      # A different argument is a different digest, or the join is useless.
      PolicyApplier.apply([], fn _ -> {:ok, :v} end, %{messages: []})
      assert_receive {:tel, [:raxol, :agent, :policy, :applied], _, other}
      refute other.params_digest == applied.params_digest
    end

    test "key and reason are bounded; the digest rides on every event of one call",
         %{table: table} do
      # `key_fn` is user code and may return the argument itself; `reason` is
      # whatever the wrapped operation returned. Neither may carry content.
      content = "SECRET-PROMPT-7f3a " <> String.duplicate("x", 64)
      cache = Cache.ets(ttl_ms: 60_000, key_fn: fn p -> p end, table: table)
      retry = Retry.exponential(max_attempts: 2, base_ms: 0, on: :any)

      PolicyApplier.apply(
        [cache, retry],
        fn _ -> {:error, {:http_error, 500, content}} end,
        content
      )

      assert_receive {:tel, [:raxol, :agent, :policy, :cache_miss], _, miss}
      assert_receive {:tel, [:raxol, :agent, :policy, :retry_attempt], _, attempt}
      assert_receive {:tel, [:raxol, :agent, :policy, :retry_exhausted], _, exhausted}
      assert_receive {:tel, [:raxol, :agent, :policy, :applied], _, applied}

      assert miss.key == {:redacted, :binary, byte_size(content)}
      assert attempt.reason == {:http_error, 500, {:redacted, :binary, byte_size(content)}}
      assert exhausted.reason == attempt.reason

      digests = Enum.map([miss, attempt, exhausted, applied], & &1.params_digest)
      assert [_] = Enum.uniq(digests)

      for metadata <- [miss, attempt, exhausted, applied] do
        refute inspect(metadata) =~ "SECRET-PROMPT"
      end
    end

    test "caller metadata: rides on every event and cannot relabel the event's own keys",
         %{table: table} do
      policy = Cache.ets(ttl_ms: 60_000, key_fn: fn _ -> :k end, table: table)
      context = %{turn: 3, issue_id: "issue-9", policy_kind: :spoofed}

      PolicyApplier.apply([policy], fn _ -> {:ok, :v} end, nil, metadata: context)

      assert_receive {:tel, [:raxol, :agent, :policy, :cache_miss], _, miss}
      assert_receive {:tel, [:raxol, :agent, :policy, :applied], _, applied}

      assert %{turn: 3, issue_id: "issue-9", policy_kind: :cache} = miss
      assert %{turn: 3, issue_id: "issue-9", policy_kinds: ["Cache"]} = applied

      assert_raise ArgumentError, ~r/must be a map/, fn ->
        PolicyApplier.apply([], fn _ -> {:ok, :v} end, nil, metadata: [turn: 3])
      end
    end

    test "caller metadata: refuses anything that is not an identifier, without echoing it" do
      never = fn _ -> flunk("the operation must not run when metadata is refused") end
      secret = "SECRET-PROMPT-7f3a " <> String.duplicate("x", 64)

      # `%URI{}` stands in for any request/turn struct a caller might hand
      # over whole: `%{}` matches a struct, and enumerating one raises with
      # the entire value in the message.
      leaky_struct = %URI{scheme: "https", userinfo: secret, host: "x.test"}

      for {label, context} <- [
            {"a long binary", %{prompt: secret}},
            {"a map", %{payload: %{content: secret}}},
            {"a list", %{messages: [secret]}},
            {"a struct", %{policy: Timeout.new(1)}},
            {"a non-atom key", %{"turn" => 1}},
            {"a secret-bearing key", %{secret => 1}},
            {"a struct as the map", leaky_struct},
            {"a keyword list with content", [prompt: secret]}
          ] do
        error =
          assert_raise ArgumentError, fn ->
            PolicyApplier.apply([], never, nil, metadata: context)
          end

        message = Exception.message(error)
        refute message =~ "SECRET-PROMPT", "#{label}: the refusal echoed the content"
        assert message =~ "correlation identifiers" or message =~ "keys must be atoms"
      end

      # Every shape this repo mints as an identifier is accepted, including a
      # binary of exactly the cap.
      accepted = %{
        session_id: "sess-1725580800-1",
        trace_id: String.duplicate("a", 64),
        turn: 3,
        ratio: 0.5,
        flag: true,
        none: nil
      }

      assert {:ok, :v} = PolicyApplier.apply([], fn _ -> {:ok, :v} end, nil, metadata: accepted)
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
