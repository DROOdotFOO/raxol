defmodule Raxol.Agent.ThreadLogRouterTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Policy.{Cache, Retry, Timeout}
  alias Raxol.Agent.PolicyApplier
  alias Raxol.Agent.ThreadLog
  alias Raxol.Agent.ThreadLog.Ets, as: EtsLog
  alias Raxol.Agent.ThreadLogRouter

  setup do
    nonce = System.unique_integer([:positive])
    cache_table = :"router_cache_#{nonce}"
    log_table = :"router_log_#{nonce}"
    log_seq = :"#{log_table}_seq"
    handler_id = "thread_log_router_test_#{nonce}"

    on_exit(fn ->
      ThreadLogRouter.detach(handler_id)
      Enum.each([cache_table, log_table, log_seq], &drop_table/1)
    end)

    {:ok,
     cache_table: cache_table,
     log_table: log_table,
     handler_id: handler_id,
     adapter: {EtsLog, %{table: log_table}}}
  end

  # The tables are named and owned by the test process, so ERTS reaps them as
  # that process exits -- concurrently with this callback, which ExUnit runs in
  # its own on_exit process. Guarding the delete with a `whereis` therefore
  # races: the reaper can free the table between the two calls and the delete
  # raises. "Already gone" is the goal state here, so tolerate exactly that;
  # any other ArgumentError is a real one and must not be swallowed.
  defp drop_table(table) do
    :ets.delete(table)
    :ok
  rescue
    error in ArgumentError ->
      if :ets.whereis(table) == :undefined,
        do: :ok,
        else: reraise(error, __STACKTRACE__)
  end

  describe "attach/3" do
    test "is a no-op when adapter is nil", %{handler_id: handler_id} do
      assert :ok = ThreadLogRouter.attach(handler_id, nil, "thr-1")
    end

    test "attaches and detaches successfully", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      assert :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")
      assert :ok = ThreadLogRouter.detach(handler_id)
    end

    test "detach is idempotent" do
      assert :ok = ThreadLogRouter.detach("nonexistent_handler")
    end
  end

  describe "policy event routing" do
    test "Retry events land as :policy_result with :retry payload", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      policy = Retry.exponential(max_attempts: 3, base_ms: 0, on: [:transient])
      counter = :counters.new(1, [])

      fun = fn _ ->
        _ = :counters.add(counter, 1, 1)
        n = :counters.get(counter, 1)
        if n < 3, do: {:error, :transient}, else: {:ok, n}
      end

      PolicyApplier.apply([policy], fun, %{})

      {:ok, events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "thr-1"
        )

      retry_events = Enum.filter(events, &(&1.kind == :policy_result))
      assert length(retry_events) >= 2

      attempts =
        retry_events
        |> Enum.filter(&(&1.payload.policy == :retry and &1.payload.decision == :attempt))
        |> Enum.map(& &1.payload.attempt)

      assert 1 in attempts
      assert 2 in attempts
    end

    test "Cache miss and hit fire :policy_result events", %{
      handler_id: handler_id,
      adapter: adapter,
      cache_table: cache_table
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      policy =
        Cache.ets(
          ttl_ms: 60_000,
          key_fn: fn _ -> :test_key end,
          table: cache_table
        )

      PolicyApplier.apply([policy], fn _ -> {:ok, :value} end, nil)
      PolicyApplier.apply([policy], fn _ -> {:ok, :value} end, nil)

      {:ok, events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "thr-1"
        )

      kinds =
        Enum.map(
          events,
          &{&1.kind, get_in(&1.payload, [:policy]), get_in(&1.payload, [:decision])}
        )

      assert {:policy_result, :cache, :miss} in kinds
      assert {:policy_result, :cache, :hit} in kinds
    end

    test "nothing persisted carries the wrapped argument", %{
      handler_id: handler_id,
      adapter: adapter,
      cache_table: cache_table
    } do
      # The router mirrors the whole telemetry metadata into the durable
      # entry, so the only defence is at the emitter. This holds the sink to
      # it: a prompt-shaped argument must not be findable in any persisted
      # payload or metadata, while the digest that replaces it is.
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      policy =
        Cache.ets(ttl_ms: 60_000, key_fn: fn _ -> :prompt_key end, table: cache_table)

      params = %{messages: [%{role: :user, content: "SECRET-PROMPT-7f3a"}]}
      PolicyApplier.apply([policy], fn _ -> {:ok, :value} end, params)

      {:ok, events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "thr-1"
        )

      policy_events = Enum.filter(events, &(&1.kind == :policy_result))
      assert length(policy_events) == 2

      for event <- policy_events do
        refute inspect(event) =~ "SECRET-PROMPT"
        assert event.payload.params_digest =~ ~r/\A[0-9a-f]{16}\z/
      end
    end

    test "Timeout event is captured", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      policy = Timeout.new(20)

      PolicyApplier.apply(
        [policy],
        fn _ ->
          Process.sleep(200)
          {:ok, :late}
        end,
        nil
      )

      {:ok, events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "thr-1"
        )

      timeout_event =
        Enum.find(events, fn e ->
          e.kind == :policy_result and e.payload.policy == :timeout
        end)

      assert timeout_event
      assert timeout_event.payload.decision == :fired
      assert timeout_event.payload.wall_ms == 20
    end

    test "applied event fires once per apply/3 with outcome", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      PolicyApplier.apply([], fn _ -> {:ok, :v} end, nil)
      PolicyApplier.apply([], fn _ -> {:error, :nope} end, nil)

      {:ok, events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "thr-1"
        )

      applied =
        Enum.filter(events, fn e ->
          e.kind == :policy_result and e.payload.policy == :applied
        end)

      outcomes = Enum.map(applied, & &1.payload.outcome)

      assert :ok in outcomes
      assert :error in outcomes
    end
  end

  describe "sandbox deny routing" do
    test ":sandbox_denied telemetry lands as :sandbox_deny event", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      :telemetry.execute(
        [:raxol, :agent, :sandbox, :denied],
        %{},
        %{
          agent_id: :test,
          agent_module: nil,
          action: :shell,
          reason: {:shell_denied, :deny_all, "rm"}
        }
      )

      {:ok, events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "thr-1"
        )

      assert [event] = events
      assert event.kind == :sandbox_deny
      assert event.payload.action == :shell
      assert event.payload.reason == {:shell_denied, :deny_all, "rm"}
    end

    test "a payload from an emitter that forgot to bound is bounded here", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")
      command = "curl -H 'Authorization: Bearer SECRET-TOKEN-7f3a' " <> String.duplicate("x", 64)

      :telemetry.execute(
        [:raxol, :agent, :sandbox, :denied],
        %{},
        %{action: :shell, reason: {:shell_denied, :deny_all, command}, command_digest: "abcd"}
      )

      assert [event] = persisted(adapter, "thr-1")

      assert event.payload.reason ==
               {:shell_denied, :deny_all, {:redacted, :binary, byte_size(command)}}

      assert event.payload.command_digest == "abcd"
      refute inspect(event) =~ "SECRET-TOKEN"
    end
  end

  defp persisted(adapter, thread_id) do
    {:ok, events} =
      ThreadLog.list({EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}}, thread_id)

    events
  end

  describe "persisted metadata" do
    test "carries the core and host-named correlation keys, and nothing else", %{
      handler_id: handler_id,
      adapter: adapter,
      cache_table: cache_table
    } do
      :ok =
        ThreadLogRouter.attach(handler_id, adapter, "thr-1", metadata_keys: [:turn, :issue_id])

      policy = Cache.ets(ttl_ms: 60_000, key_fn: fn _ -> :k end, table: cache_table)

      PolicyApplier.apply([policy], fn _ -> {:ok, :v} end, %{prompt: "SECRET-PROMPT-7f3a"},
        metadata: %{session_id: "sess-1", turn: 3, issue_id: "issue-9", trace_id: "abc"}
      )

      events = persisted(adapter, "thr-1")
      assert length(events) == 2

      for event <- events do
        # The event's own fields (policy_kind, key, params_digest) live in the
        # payload; the metadata is identifiers only.
        assert event.metadata == %{
                 session_id: "sess-1",
                 turn: 3,
                 issue_id: "issue-9",
                 trace_id: "abc"
               }

        refute inspect(event) =~ "SECRET-PROMPT"
      end
    end

    test "a key the host did not name is dropped even when the emitter sends it", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      PolicyApplier.apply([], fn _ -> {:ok, :v} end, nil,
        metadata: %{session_id: "sess-1", turn: 3, issue_id: "issue-9"}
      )

      assert [event] = persisted(adapter, "thr-1")
      assert event.metadata == %{session_id: "sess-1"}
    end

    test "a listed key with a non-identifier value is dropped and the handler survives", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      # An emitter that violates the contract (here a raw execute, since
      # PolicyApplier refuses such values at the call site) must not be able
      # to write content through a listed key -- and must not be able to
      # detach the audit handler by making it raise.
      :ok = ThreadLogRouter.attach(handler_id, adapter, "thr-1")

      violating = %{
        session_id: %{nested: "SECRET-PROMPT-7f3a"},
        turn_id: String.duplicate("x", 65),
        trace_id: "abc",
        policy_kinds: [],
        outcome: :ok,
        params_digest: "0000000000000000"
      }

      :telemetry.execute([:raxol, :agent, :policy, :applied], %{}, violating)
      :telemetry.execute([:raxol, :agent, :policy, :applied], %{}, %{turn_id: "t2", outcome: :ok})

      assert [first, second] = persisted(adapter, "thr-1")
      assert first.metadata == %{trace_id: "abc"}
      assert second.metadata == %{turn_id: "t2"}
      refute inspect(first) =~ "SECRET-PROMPT"
    end

    test "attach/4 refuses metadata_keys that are not atoms", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      assert_raise ArgumentError, ~r/must be a list of atoms/, fn ->
        ThreadLogRouter.attach(handler_id, adapter, "thr-1", metadata_keys: ["turn"])
      end
    end
  end

  describe "thread isolation" do
    test "events keyed on the attached thread_id only", %{
      handler_id: handler_id,
      adapter: adapter
    } do
      :ok = ThreadLogRouter.attach(handler_id, adapter, "agent-A")

      PolicyApplier.apply([], fn _ -> {:ok, :v} end, nil)

      {:ok, a_events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "agent-A"
        )

      {:ok, b_events} =
        ThreadLog.list(
          {EtsLog, %{table: adapter |> elem(1) |> Map.get(:table)}},
          "agent-B"
        )

      assert length(a_events) >= 1
      assert b_events == []
    end
  end
end
