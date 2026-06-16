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
      if :ets.whereis(cache_table) != :undefined, do: :ets.delete(cache_table)
      if :ets.whereis(log_table) != :undefined, do: :ets.delete(log_table)
      if :ets.whereis(log_seq) != :undefined, do: :ets.delete(log_seq)
    end)

    {:ok,
     cache_table: cache_table,
     log_table: log_table,
     handler_id: handler_id,
     adapter: {EtsLog, %{table: log_table}}}
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
        |> Enum.filter(
          &(&1.payload.policy == :retry and &1.payload.decision == :attempt)
        )
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
          &{&1.kind, get_in(&1.payload, [:policy]),
           get_in(&1.payload, [:decision])}
        )

      assert {:policy_result, :cache, :miss} in kinds
      assert {:policy_result, :cache, :hit} in kinds
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
