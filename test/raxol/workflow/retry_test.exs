defmodule Raxol.Workflow.RetryTest do
  use ExUnit.Case, async: false

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  defp counter_table do
    name = :"retry_counter_#{:erlang.unique_integer([:positive])}"
    :ets.new(name, [:public, :named_table, :set])
    name
  end

  defp bump(table, key) do
    :ets.update_counter(table, key, 1, {key, 0})
  end

  defp get(table, key) do
    case :ets.lookup(table, key) do
      [{^key, n}] -> n
      [] -> 0
    end
  end

  defp flaky_graph(table, fail_until: fail_until, policy_opts: policy_opts) do
    {:ok, compiled} =
      Graph.new(:flaky)
      |> Graph.add_node(:flaky, fn s ->
        n = bump(table, :flaky)

        if n <= fail_until do
          {:error, {:transient, n}}
        else
          {:ok, Map.put(s, :flaky_runs, n)}
        end
      end)
      |> Graph.add_edge(:__start__, :flaky)
      |> Graph.add_edge(:flaky, :__end__)
      |> Graph.compile(policy_opts)

    compiled
  end

  describe "failure_policy :retry" do
    test "halt is the default: a single failure surfaces immediately" do
      table = counter_table()
      compiled = flaky_graph(table, fail_until: 5, policy_opts: [])

      assert {:error, {:transient, 1}, _state} =
               Compiled.invoke(compiled, %{})

      assert get(table, :flaky) == 1
    end

    test "retry succeeds once the underlying error clears" do
      table = counter_table()

      compiled =
        flaky_graph(table,
          fail_until: 2,
          policy_opts: [
            failure_policy: :retry,
            max_attempts: 5,
            retry_backoff_ms: 1
          ]
        )

      assert {:ok, %{flaky_runs: 3}, %{nodes_executed: 1}} =
               Compiled.invoke(compiled, %{})

      assert get(table, :flaky) == 3
    end

    test "retry exhausts after max_attempts and returns the last error" do
      table = counter_table()

      compiled =
        flaky_graph(table,
          fail_until: 100,
          policy_opts: [
            failure_policy: :retry,
            max_attempts: 3,
            retry_backoff_ms: 1
          ]
        )

      assert {:error, {:transient, 3}, _state} =
               Compiled.invoke(compiled, %{})

      assert get(table, :flaky) == 3
    end

    test "max_attempts: 1 disables retries even when policy is :retry" do
      table = counter_table()

      compiled =
        flaky_graph(table,
          fail_until: 100,
          policy_opts: [
            failure_policy: :retry,
            max_attempts: 1,
            retry_backoff_ms: 1
          ]
        )

      assert {:error, {:transient, 1}, _state} =
               Compiled.invoke(compiled, %{})

      assert get(table, :flaky) == 1
    end

    test "raised exceptions are retried under :retry policy" do
      table = counter_table()

      {:ok, compiled} =
        Graph.new(:flaky_raise)
        |> Graph.add_node(:flaky, fn s ->
          n = bump(table, :flaky)

          if n <= 2 do
            raise "transient #{n}"
          else
            {:ok, Map.put(s, :ran, n)}
          end
        end)
        |> Graph.add_edge(:__start__, :flaky)
        |> Graph.add_edge(:flaky, :__end__)
        |> Graph.compile(
          failure_policy: :retry,
          max_attempts: 5,
          retry_backoff_ms: 1
        )

      assert {:ok, %{ran: 3}, _meta} = Compiled.invoke(compiled, %{})
      assert get(table, :flaky) == 3
    end

    test "halt policy does not retry exceptions either" do
      table = counter_table()

      {:ok, compiled} =
        Graph.new(:halt_raise)
        |> Graph.add_node(:bomb, fn _ -> raise "boom" end)
        |> Graph.add_edge(:__start__, :bomb)
        |> Graph.add_edge(:bomb, :__end__)
        |> Graph.compile(failure_policy: :halt)

      assert {:error, {:exception, "boom"}, _} = Compiled.invoke(compiled, %{})
      _ = table
    end
  end

  describe "retry telemetry" do
    test "each attempt emits node.started + node.failed; final success emits node.completed" do
      table = counter_table()
      test_pid = self()
      handler_id = "retry_tel_#{:erlang.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [
          [:raxol, :workflow, :node, :started],
          [:raxol, :workflow, :node, :completed],
          [:raxol, :workflow, :node, :failed]
        ],
        fn event, _m, metadata, _ ->
          send(test_pid, {:tel, event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      compiled =
        flaky_graph(table,
          fail_until: 2,
          policy_opts: [
            failure_policy: :retry,
            max_attempts: 5,
            retry_backoff_ms: 1
          ]
        )

      Compiled.invoke(compiled, %{})

      # 3 attempts -> 3 :started, 2 :failed, 1 :completed
      starts = collect(test_pid, [:raxol, :workflow, :node, :started], 3)
      fails = collect(test_pid, [:raxol, :workflow, :node, :failed], 2)
      completes = collect(test_pid, [:raxol, :workflow, :node, :completed], 1)

      assert length(starts) == 3
      assert length(fails) == 2
      assert length(completes) == 1
    end
  end

  describe "retry interaction with the saver" do
    test "checkpoints are not written for failed attempts; only the final success",
         _ctx do
      table = counter_table()
      ets_table = :"retry_ckpt_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        if :ets.whereis(ets_table) != :undefined, do: :ets.delete(ets_table)
      end)

      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: ets_table}}

      compiled =
        flaky_graph(table,
          fail_until: 2,
          policy_opts: [
            failure_policy: :retry,
            max_attempts: 5,
            retry_backoff_ms: 1,
            saver: saver
          ]
        )

      {:ok, _final, meta} = Compiled.invoke(compiled, %{})

      {:ok, checkpoints} =
        Raxol.Workflow.Checkpoint.Saver.Ets.list(
          %{table: ets_table},
          meta.run_id,
          10
        )

      # :__start__ initial + :flaky (one final successful checkpoint) = 2
      assert length(checkpoints) == 2

      node_ids =
        checkpoints |> Enum.map(& &1.metadata.node_id) |> Enum.sort()

      assert node_ids == [:__start__, :flaky]
    end
  end

  # Helpers

  defp collect(_pid, _event, 0), do: []

  defp collect(pid, event, n) do
    receive do
      {:tel, ^event, metadata} -> [metadata | collect(pid, event, n - 1)]
    after
      500 -> []
    end
  end
end
