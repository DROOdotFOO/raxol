defmodule Raxol.Workflow.ParallelTest do
  @moduledoc """
  Reference tests for ADR-0019 parallel branches.

  Covers the happy paths the runtime must support:

  - Builder + compile: `add_channel/3` + `add_join/4` validate as expected.
  - 2-branch fan-out with default last-write-wins merge.
  - 3-branch fan-out with an explicit `:reduce` reducer.
  - 3-branch fan-out with a `Channel`-keyed merge.

  Per-branch failure semantics, pause-inside-branch, retry-per-branch,
  and compensate-across-branches are deferred to follow-up work and are
  intentionally not covered here.
  """

  use ExUnit.Case, async: false

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  describe "add_channel/3 + add_join/4 builders" do
    test "channel name uniqueness is enforced at the struct level" do
      graph =
        Graph.new(:c1)
        |> Graph.add_channel(:findings, into: :findings, with: &Map.merge/2)

      assert Map.has_key?(graph.channels, :findings)
      assert %Raxol.Workflow.Channel{into: :findings} = graph.channels[:findings]
    end

    test "add_channel/3 rejects non-2-arity reducer" do
      assert_raise ArgumentError, ~r/:with must be a 2-arity/, fn ->
        Graph.new(:c2) |> Graph.add_channel(:f, into: :f, with: fn _ -> :nope end)
      end
    end

    test "add_join/4 rejects non-1-arity :reduce" do
      assert_raise ArgumentError, ~r/:reduce must be a 1-arity/, fn ->
        Graph.new(:c3) |> Graph.add_join(:t, [:a], reduce: fn _, _ -> :nope end)
      end
    end

    test "compile rejects a join whose target is unknown" do
      graph =
        Graph.new(:c4)
        |> Graph.add_node(:a, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :__end__)
        |> Graph.add_join(:nonexistent, [:a])

      # The generic edge-reference check fires first because a JoinEdge
      # surfaces its target via Edge.from/1 + Edge.targets/1. Either
      # error tag is acceptable; both describe the same misconfiguration.
      assert {:error, error} = Graph.compile(graph)

      assert error == {:unknown_node, [:nonexistent]} or
               error == {:join_target_unknown, :nonexistent}
    end

    test "compile rejects a join whose upstream is unknown" do
      graph =
        Graph.new(:c5)
        |> Graph.add_node(:join, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :join)
        |> Graph.add_edge(:join, :__end__)
        |> Graph.add_join(:join, [:ghost])

      # Same logic as the unknown-target case: the generic edge-reference
      # check fires before the join-specific one when the upstream isn't a
      # declared node. Both tags describe the same misconfiguration.
      assert {:error, error} = Graph.compile(graph)

      assert error == {:unknown_node, [:ghost]} or
               error == {:join_upstream_unknown, :join, [:ghost]}
    end

    test "compile rejects two joins sharing an upstream" do
      graph =
        Graph.new(:c6)
        |> Graph.add_node(:a, fn s -> {:ok, s} end)
        |> Graph.add_node(:j1, fn s -> {:ok, s} end)
        |> Graph.add_node(:j2, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :j1)
        |> Graph.add_edge(:j1, :j2)
        |> Graph.add_edge(:j2, :__end__)
        |> Graph.add_join(:j1, [:a])
        |> Graph.add_join(:j2, [:a])

      assert {:error, {:join_upstream_shared, [_ | _]}} = Graph.compile(graph)
    end

    test "compile records channels + joins on the Compiled struct" do
      graph =
        Graph.new(:c7)
        |> Graph.add_node(:a, fn s -> {:ok, s} end)
        |> Graph.add_node(:b, fn s -> {:ok, s} end)
        |> Graph.add_node(:report, fn s -> {:ok, s} end)
        |> Graph.add_channel(:findings, into: :findings, with: &Map.merge/2)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:__start__, :b)
        |> Graph.add_edge(:a, :report)
        |> Graph.add_edge(:b, :report)
        |> Graph.add_edge(:report, :__end__)
        |> Graph.add_join(:report, [:a, :b])

      assert {:ok, %Compiled{} = compiled} = Graph.compile(graph)

      assert Map.has_key?(compiled.channels, :findings)
      assert %Raxol.Workflow.Edge.JoinEdge{upstream: [:a, :b]} = compiled.joins_by_node[:report]
      assert compiled.joins_by_upstream[:a].target == :report
      assert compiled.joins_by_upstream[:b].target == :report
    end
  end

  describe "2-branch fan-out (happy path)" do
    test "both branches run; join body sees a merged state" do
      graph =
        Graph.new(:fan2)
        |> Graph.add_node(:fan_out, fn s -> {:ok, s} end)
        |> Graph.add_node(:scout_a, fn s -> {:ok, Map.put(s, :a, "from-a")} end)
        |> Graph.add_node(:scout_b, fn s -> {:ok, Map.put(s, :b, "from-b")} end)
        |> Graph.add_node(:report, fn s ->
          {:ok, Map.put(s, :report, "a=#{s.a} b=#{s.b}")}
        end)
        |> Graph.add_edge(:__start__, :fan_out)
        |> Graph.add_conditional_edge(:fan_out, [:scout_a, :scout_b], fn _ ->
          [:scout_a, :scout_b]
        end)
        |> Graph.add_edge(:scout_a, :report)
        |> Graph.add_edge(:scout_b, :report)
        |> Graph.add_join(:report, [:scout_a, :scout_b])
        |> Graph.add_edge(:report, :__end__)

      {:ok, compiled} = Graph.compile(graph)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, %{})
      assert final.a == "from-a"
      assert final.b == "from-b"
      assert final.report == "a=from-a b=from-b"
    end
  end

  describe "3-branch fan-out with explicit reducer" do
    test "reduce/1 receives all branch terminal states; join sees the merged result" do
      graph =
        Graph.new(:fan3)
        |> Graph.add_node(:fan_out, fn s -> {:ok, s} end)
        |> Graph.add_node(:partial_x, fn s -> {:ok, Map.put(s, :counts, %{x: 1})} end)
        |> Graph.add_node(:partial_y, fn s -> {:ok, Map.put(s, :counts, %{y: 2})} end)
        |> Graph.add_node(:partial_z, fn s -> {:ok, Map.put(s, :counts, %{z: 3})} end)
        |> Graph.add_node(:report, fn s ->
          {:ok, Map.put(s, :total, Enum.sum(Map.values(s.counts)))}
        end)
        |> Graph.add_edge(:__start__, :fan_out)
        |> Graph.add_conditional_edge(
          :fan_out,
          [:partial_x, :partial_y, :partial_z],
          fn _ -> [:partial_x, :partial_y, :partial_z] end
        )
        |> Graph.add_edge(:partial_x, :report)
        |> Graph.add_edge(:partial_y, :report)
        |> Graph.add_edge(:partial_z, :report)
        |> Graph.add_join(
          :report,
          [:partial_x, :partial_y, :partial_z],
          reduce: fn branch_states ->
            counts =
              branch_states
              |> Enum.map(& &1.counts)
              |> Enum.reduce(%{}, &Map.merge/2)

            branch_states |> List.first() |> Map.put(:counts, counts)
          end
        )
        |> Graph.add_edge(:report, :__end__)

      {:ok, compiled} = Graph.compile(graph)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, %{})
      assert final.counts == %{x: 1, y: 2, z: 3}
      assert final.total == 6
    end
  end

  describe "channel-based merge" do
    test "a channel-keyed key is reduced via the channel's :with reducer" do
      graph =
        Graph.new(:chan)
        |> Graph.add_channel(:findings, into: :findings, with: &Map.merge/2)
        |> Graph.add_node(:fan_out, fn s -> {:ok, Map.put(s, :findings, %{})} end)
        |> Graph.add_node(:scout_a, fn s ->
          {:ok, Map.put(s, :findings, Map.put(s.findings, :a, 1))}
        end)
        |> Graph.add_node(:scout_b, fn s ->
          {:ok, Map.put(s, :findings, Map.put(s.findings, :b, 2))}
        end)
        |> Graph.add_node(:scout_c, fn s ->
          {:ok, Map.put(s, :findings, Map.put(s.findings, :c, 3))}
        end)
        |> Graph.add_node(:report, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :fan_out)
        |> Graph.add_conditional_edge(
          :fan_out,
          [:scout_a, :scout_b, :scout_c],
          fn _ -> [:scout_a, :scout_b, :scout_c] end
        )
        |> Graph.add_edge(:scout_a, :report)
        |> Graph.add_edge(:scout_b, :report)
        |> Graph.add_edge(:scout_c, :report)
        |> Graph.add_join(:report, [:scout_a, :scout_b, :scout_c])
        |> Graph.add_edge(:report, :__end__)

      {:ok, compiled} = Graph.compile(graph)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, %{})
      # All three contributions merged via the channel's reducer.
      assert final.findings == %{a: 1, b: 2, c: 3}
    end
  end

  describe "branch_id in checkpoint metadata" do
    test "per-branch checkpoints carry branch_id; sequential ones carry nil" do
      table = :"branch_id_ckpt_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      graph =
        Graph.new(:bid)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:scout_a, fn s -> {:ok, Map.put(s, :a, 1)} end)
        |> Graph.add_node(:scout_b, fn s -> {:ok, Map.put(s, :b, 2)} end)
        |> Graph.add_node(:report, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:scout_a, :scout_b], fn _ ->
          [:scout_a, :scout_b]
        end)
        |> Graph.add_edge(:scout_a, :report)
        |> Graph.add_edge(:scout_b, :report)
        |> Graph.add_join(:report, [:scout_a, :scout_b])
        |> Graph.add_edge(:report, :__end__)

      {:ok, compiled} = Graph.compile(graph, saver: saver)
      {:ok, _final, meta} = Compiled.invoke(compiled, %{})

      {:ok, checkpoints} =
        Raxol.Workflow.Checkpoint.Saver.Ets.list(%{table: table}, meta.run_id, 50)

      by_node =
        Map.new(checkpoints, fn ck -> {ck.metadata.node_id, ck.metadata.branch_id} end)

      # Branch nodes carry {join_target, branch_index}.
      assert by_node[:scout_a] == {:report, 0}
      assert by_node[:scout_b] == {:report, 1}

      # Sequential nodes (gate, report) carry nil.
      assert by_node[:gate] == nil
      assert by_node[:report] == nil
    end
  end

  describe "branch_id in :node telemetry" do
    test ":node events carry branch_id for branch nodes, nil for sequential" do
      handler_id = "branch_id_telemetry_#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach_many(
        handler_id,
        [
          [:raxol, :workflow, :node, :started],
          [:raxol, :workflow, :node, :completed]
        ],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:node_event, metadata.node_id, metadata.branch_id})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      graph =
        Graph.new(:tlb)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:b0, fn s -> {:ok, Map.put(s, :b0, true)} end)
        |> Graph.add_node(:b1, fn s -> {:ok, Map.put(s, :b1, true)} end)
        |> Graph.add_node(:b2, fn s -> {:ok, Map.put(s, :b2, true)} end)
        |> Graph.add_node(:merge, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:b0, :b1, :b2], fn _ -> [:b0, :b1, :b2] end)
        |> Graph.add_edge(:b0, :merge)
        |> Graph.add_edge(:b1, :merge)
        |> Graph.add_edge(:b2, :merge)
        |> Graph.add_join(:merge, [:b0, :b1, :b2])
        |> Graph.add_edge(:merge, :__end__)

      {:ok, compiled} = Graph.compile(graph)
      {:ok, _final, _meta} = Compiled.invoke(compiled, %{})

      # Gather all events emitted during the run.
      events = drain_node_events([])

      # Each branch node fired with {:merge, index}.
      assert {:b0, {:merge, 0}} in events
      assert {:b1, {:merge, 1}} in events
      assert {:b2, {:merge, 2}} in events

      # Sequential nodes (gate, merge) fired with nil.
      assert {:gate, nil} in events
      assert {:merge, nil} in events
    end

    defp drain_node_events(acc) do
      receive do
        {:node_event, node_id, branch_id} ->
          drain_node_events([{node_id, branch_id} | acc])
      after
        50 -> acc
      end
    end
  end

  describe "multi-node branches" do
    test "each branch walks a 2-node sub-graph before reaching the join" do
      graph =
        Graph.new(:multi2)
        |> Graph.add_node(:fan_out, fn s -> {:ok, s} end)
        |> Graph.add_node(:scout_a, fn s -> {:ok, Map.put(s, :a, 1)} end)
        |> Graph.add_node(:scout_a_squared, fn s -> {:ok, Map.put(s, :a, s.a * s.a)} end)
        |> Graph.add_node(:scout_b, fn s -> {:ok, Map.put(s, :b, 10)} end)
        |> Graph.add_node(:scout_b_doubled, fn s -> {:ok, Map.put(s, :b, s.b * 2)} end)
        |> Graph.add_node(:report, fn s ->
          {:ok, Map.put(s, :total, s.a + s.b)}
        end)
        |> Graph.add_edge(:__start__, :fan_out)
        |> Graph.add_conditional_edge(:fan_out, [:scout_a, :scout_b], fn _ ->
          [:scout_a, :scout_b]
        end)
        |> Graph.add_edge(:scout_a, :scout_a_squared)
        |> Graph.add_edge(:scout_a_squared, :report)
        |> Graph.add_edge(:scout_b, :scout_b_doubled)
        |> Graph.add_edge(:scout_b_doubled, :report)
        |> Graph.add_join(:report, [:scout_a, :scout_b])
        |> Graph.add_edge(:report, :__end__)

      {:ok, compiled} = Graph.compile(graph)
      {:ok, final, _meta} = Compiled.invoke(compiled, %{})

      # scout_a path: 1, then squared = 1.
      # scout_b path: 10, then doubled = 20.
      # Merged + report: 1 + 20 = 21.
      assert final.a == 1
      assert final.b == 20
      assert final.total == 21
    end

    test "branches with mixed depths still reach the join" do
      graph =
        Graph.new(:mixed_depths)
        |> Graph.add_node(:fan_out, fn s -> {:ok, s} end)
        |> Graph.add_node(:short, fn s -> {:ok, Map.put(s, :short, true)} end)
        |> Graph.add_node(:medium_1, fn s -> {:ok, Map.put(s, :m1, true)} end)
        |> Graph.add_node(:medium_2, fn s -> {:ok, Map.put(s, :m2, true)} end)
        |> Graph.add_node(:long_1, fn s -> {:ok, Map.put(s, :l1, true)} end)
        |> Graph.add_node(:long_2, fn s -> {:ok, Map.put(s, :l2, true)} end)
        |> Graph.add_node(:long_3, fn s -> {:ok, Map.put(s, :l3, true)} end)
        |> Graph.add_node(:join, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :fan_out)
        |> Graph.add_conditional_edge(:fan_out, [:short, :medium_1, :long_1], fn _ ->
          [:short, :medium_1, :long_1]
        end)
        |> Graph.add_edge(:short, :join)
        |> Graph.add_edge(:medium_1, :medium_2)
        |> Graph.add_edge(:medium_2, :join)
        |> Graph.add_edge(:long_1, :long_2)
        |> Graph.add_edge(:long_2, :long_3)
        |> Graph.add_edge(:long_3, :join)
        |> Graph.add_join(:join, [:short, :medium_1, :long_1])
        |> Graph.add_edge(:join, :__end__)

      {:ok, compiled} = Graph.compile(graph)
      {:ok, final, _meta} = Compiled.invoke(compiled, %{})

      assert final.short == true
      assert final.m1 == true
      assert final.m2 == true
      assert final.l1 == true
      assert final.l2 == true
      assert final.l3 == true
    end

    test "every node in a multi-node branch carries the same branch_id in checkpoint metadata" do
      table = :"multi_bid_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      graph =
        Graph.new(:multi_bid)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:a1, fn s -> {:ok, Map.put(s, :a1, true)} end)
        |> Graph.add_node(:a2, fn s -> {:ok, Map.put(s, :a2, true)} end)
        |> Graph.add_node(:b1, fn s -> {:ok, Map.put(s, :b1, true)} end)
        |> Graph.add_node(:b2, fn s -> {:ok, Map.put(s, :b2, true)} end)
        |> Graph.add_node(:join, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:a1, :b1], fn _ -> [:a1, :b1] end)
        |> Graph.add_edge(:a1, :a2)
        |> Graph.add_edge(:a2, :join)
        |> Graph.add_edge(:b1, :b2)
        |> Graph.add_edge(:b2, :join)
        |> Graph.add_join(:join, [:a1, :b1])
        |> Graph.add_edge(:join, :__end__)

      {:ok, compiled} = Graph.compile(graph, saver: saver)
      {:ok, _final, meta} = Compiled.invoke(compiled, %{})

      {:ok, checkpoints} =
        Raxol.Workflow.Checkpoint.Saver.Ets.list(%{table: table}, meta.run_id, 50)

      by_node =
        Map.new(checkpoints, fn ck -> {ck.metadata.node_id, ck.metadata.branch_id} end)

      # Branch A: both a1 and a2 share {:join, 0}.
      assert by_node[:a1] == {:join, 0}
      assert by_node[:a2] == {:join, 0}

      # Branch B: both b1 and b2 share {:join, 1}.
      assert by_node[:b1] == {:join, 1}
      assert by_node[:b2] == {:join, 1}

      # Sequential nodes carry nil.
      assert by_node[:gate] == nil
      assert by_node[:join] == nil
    end

    test "a mid-branch node failure surfaces the error to the run" do
      graph =
        Graph.new(:branch_fail)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:a1, fn s -> {:ok, Map.put(s, :a1, true)} end)
        |> Graph.add_node(:a2_bomb, fn _s -> {:error, :a2_boom} end)
        |> Graph.add_node(:b1, fn s -> {:ok, Map.put(s, :b1, true)} end)
        |> Graph.add_node(:join, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:a1, :b1], fn _ -> [:a1, :b1] end)
        |> Graph.add_edge(:a1, :a2_bomb)
        |> Graph.add_edge(:a2_bomb, :join)
        |> Graph.add_edge(:b1, :join)
        |> Graph.add_join(:join, [:a1, :b1])
        |> Graph.add_edge(:join, :__end__)

      {:ok, compiled} = Graph.compile(graph)
      assert {:error, :a2_boom, _state} = Compiled.invoke(compiled, %{})
    end

    test "a mid-branch interrupt surfaces as a run-level interrupt with branch_id" do
      graph =
        Graph.new(:branch_pause)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:a1, fn s -> {:ok, Map.put(s, :a1, true)} end)
        |> Graph.add_node(:a2_pause, fn _s -> Raxol.Workflow.interrupt(:awaiting_review) end)
        |> Graph.add_node(:b1, fn s -> {:ok, Map.put(s, :b1, true)} end)
        |> Graph.add_node(:join, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:a1, :b1], fn _ -> [:a1, :b1] end)
        |> Graph.add_edge(:a1, :a2_pause)
        |> Graph.add_edge(:a2_pause, :join)
        |> Graph.add_edge(:b1, :join)
        |> Graph.add_join(:join, [:a1, :b1])
        |> Graph.add_edge(:join, :__end__)

      {:ok, compiled} = Graph.compile(graph)

      assert {:interrupted, _run_id, state, :awaiting_review} =
               Compiled.invoke(compiled, %{})

      # Run state carries a fan-out continuation: branch A paused at
      # :a2_pause, branch B completed.
      continuation = state.__raxol_workflow_fan_out__
      assert continuation.join_target == :join
      assert continuation.branch_ids == [:a1, :b1]

      assert [
               {:paused, :a2_pause, %{a1: true}, :awaiting_review},
               {:done, %{b1: true}}
             ] = continuation.slots
    end

    test "nested fan-out inside a branch is rejected" do
      graph =
        Graph.new(:nested_rejected)
        |> Graph.add_node(:fan_out, fn s -> {:ok, s} end)
        |> Graph.add_node(:scout_a, fn s -> {:ok, Map.put(s, :a, true)} end)
        |> Graph.add_node(:scout_b, fn s -> {:ok, Map.put(s, :b, true)} end)
        |> Graph.add_node(:inner_fan, fn s -> {:ok, s} end)
        |> Graph.add_node(:inner_x, fn s -> {:ok, Map.put(s, :x, true)} end)
        |> Graph.add_node(:inner_y, fn s -> {:ok, Map.put(s, :y, true)} end)
        |> Graph.add_node(:inner_join, fn s -> {:ok, s} end)
        |> Graph.add_node(:outer_join, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :fan_out)
        |> Graph.add_conditional_edge(:fan_out, [:scout_a, :scout_b], fn _ ->
          [:scout_a, :scout_b]
        end)
        |> Graph.add_edge(:scout_a, :inner_fan)
        |> Graph.add_conditional_edge(:inner_fan, [:inner_x, :inner_y], fn _ ->
          [:inner_x, :inner_y]
        end)
        |> Graph.add_edge(:inner_x, :inner_join)
        |> Graph.add_edge(:inner_y, :inner_join)
        |> Graph.add_join(:inner_join, [:inner_x, :inner_y])
        |> Graph.add_edge(:inner_join, :outer_join)
        |> Graph.add_edge(:scout_b, :outer_join)
        |> Graph.add_join(:outer_join, [:scout_a, :scout_b])
        |> Graph.add_edge(:outer_join, :__end__)

      {:ok, compiled} = Graph.compile(graph)

      # scout_a's traverse hits an interior conditional_edge that returns
      # a list -- not supported in Phase A.
      assert {:error, {:nested_fan_out_unsupported, :inner_fan}, _state} =
               Compiled.invoke(compiled, %{})
    end
  end

  describe "per-branch pause + resume" do
    test "Compiled.resume completes a paused branch and merges with siblings" do
      table = :"pb_pause_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      graph =
        Graph.new(:pb1)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:a1, fn s -> {:ok, Map.put(s, :a1, true)} end)
        |> Graph.add_node(:a2_pause, fn s ->
          decision = Raxol.Workflow.interrupt(:awaiting_review)
          {:ok, Map.put(s, :decision, decision)}
        end)
        |> Graph.add_node(:b1, fn s -> {:ok, Map.put(s, :b1, true)} end)
        |> Graph.add_node(:join, fn s -> {:ok, Map.put(s, :joined, true)} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:a1, :b1], fn _ -> [:a1, :b1] end)
        |> Graph.add_edge(:a1, :a2_pause)
        |> Graph.add_edge(:a2_pause, :join)
        |> Graph.add_edge(:b1, :join)
        |> Graph.add_join(:join, [:a1, :b1])
        |> Graph.add_edge(:join, :__end__)

      {:ok, compiled} = Graph.compile(graph, saver: saver)

      assert {:interrupted, run_id, _state, :awaiting_review} =
               Compiled.invoke(compiled, %{})

      # Resume with an :approved decision; branch A finishes, merges
      # with branch B, runs the join body, ends cleanly.
      assert {:ok, final, _meta} = Compiled.resume(compiled, run_id, :approved)

      assert final.a1 == true
      assert final.b1 == true
      assert final.decision == :approved
      assert final.joined == true
      refute Map.has_key?(final, :__raxol_workflow_fan_out__)
    end

    test "branch_id is set on the pause checkpoint's metadata" do
      table = :"pb_meta_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      graph =
        Graph.new(:pb2)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :a, true)} end)
        |> Graph.add_node(:b_pause, fn _s -> Raxol.Workflow.interrupt(:awaiting_b) end)
        |> Graph.add_node(:join, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:a, :b_pause], fn _ -> [:a, :b_pause] end)
        |> Graph.add_edge(:a, :join)
        |> Graph.add_edge(:b_pause, :join)
        |> Graph.add_join(:join, [:a, :b_pause])
        |> Graph.add_edge(:join, :__end__)

      {:ok, compiled} = Graph.compile(graph, saver: saver)
      {:interrupted, run_id, _state, _} = Compiled.invoke(compiled, %{})

      {:ok, latest} = Raxol.Workflow.Runtime.preflight_resume(compiled, run_id)

      # The latest checkpoint is the pause; metadata carries branch_id
      # for the paused branch (index 1 because :b_pause was the second
      # entry in the upstream list).
      assert latest.metadata.branch_id == {:join, 1}
      assert latest.metadata.node_id == :b_pause
      assert latest.metadata.interrupt_reason == :awaiting_b
    end

    test "two paused branches resume one at a time" do
      table = :"pb_two_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      graph =
        Graph.new(:pb3)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:a_pause, fn s ->
          v = Raxol.Workflow.interrupt(:awaiting_a)
          {:ok, Map.put(s, :a_decision, v)}
        end)
        |> Graph.add_node(:b_pause, fn s ->
          v = Raxol.Workflow.interrupt(:awaiting_b)
          {:ok, Map.put(s, :b_decision, v)}
        end)
        |> Graph.add_node(:join, fn s -> {:ok, Map.put(s, :joined, true)} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:a_pause, :b_pause], fn _ ->
          [:a_pause, :b_pause]
        end)
        |> Graph.add_edge(:a_pause, :join)
        |> Graph.add_edge(:b_pause, :join)
        |> Graph.add_join(:join, [:a_pause, :b_pause])
        |> Graph.add_edge(:join, :__end__)

      {:ok, compiled} = Graph.compile(graph, saver: saver)

      # First run: both branches pause. Surfaces the FIRST paused
      # branch (index 0, :a_pause, reason :awaiting_a).
      assert {:interrupted, run_id, _state, :awaiting_a} = Compiled.invoke(compiled, %{})

      # Resume :a_pause with :approved_a. Branch B is still paused, so
      # the resume itself interrupts again -- this time for :b_pause.
      assert {:interrupted, ^run_id, _state2, :awaiting_b} =
               Compiled.resume(compiled, run_id, :approved_a)

      # Resume :b_pause with :approved_b. Both branches now complete;
      # the join body runs and the run finishes.
      assert {:ok, final, _meta} = Compiled.resume(compiled, run_id, :approved_b)

      assert final.a_decision == :approved_a
      assert final.b_decision == :approved_b
      assert final.joined == true
    end
  end

  describe "back-compat" do
    test "sequential graph with a single-id chooser still works unchanged" do
      graph =
        Graph.new(:seq)
        |> Graph.add_node(:gate, fn s -> {:ok, s} end)
        |> Graph.add_node(:left, fn s -> {:ok, Map.put(s, :branch, :left)} end)
        |> Graph.add_node(:right, fn s -> {:ok, Map.put(s, :branch, :right)} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_conditional_edge(:gate, [:left, :right], fn _ -> :left end)
        |> Graph.add_edge(:left, :__end__)
        |> Graph.add_edge(:right, :__end__)

      {:ok, compiled} = Graph.compile(graph)
      assert {:ok, final, _meta} = Compiled.invoke(compiled, %{})
      assert final.branch == :left
    end
  end
end
