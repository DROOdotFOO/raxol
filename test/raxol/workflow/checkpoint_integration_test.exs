defmodule Raxol.Workflow.CheckpointIntegrationTest do
  use ExUnit.Case, async: false

  alias Raxol.Workflow.Checkpoint
  alias Raxol.Workflow.Checkpoint.Saver.Ets
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  setup do
    table = :"integration_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, config: %{table: table}, saver: {Ets, %{table: table}}}
  end

  defp two_node_graph(saver) do
    Graph.new(:int)
    |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :a, true)} end)
    |> Graph.add_node(:b, fn s -> {:ok, Map.put(s, :b, true)} end)
    |> Graph.add_edge(:__start__, :a)
    |> Graph.add_edge(:a, :b)
    |> Graph.add_edge(:b, :__end__)
    |> Graph.compile(saver: saver)
    |> elem(1)
  end

  describe "runtime writes checkpoints when :saver is configured" do
    test "one checkpoint per successful node plus initial __start__", ctx do
      compiled = two_node_graph(ctx.saver)
      {:ok, _final, meta} = Compiled.invoke(compiled, %{})

      {:ok, checkpoints} = Ets.list(ctx.config, meta.run_id, 10)
      assert length(checkpoints) == 3

      steps = checkpoints |> Enum.map(& &1.step) |> Enum.sort()
      assert steps == [0, 1, 2]
    end

    test "checkpoints carry node_id, run_id, graph_id metadata", ctx do
      compiled = two_node_graph(ctx.saver)
      {:ok, _final, meta} = Compiled.invoke(compiled, %{})

      {:ok, [_latest | _]} = Ets.list(ctx.config, meta.run_id, 10)

      {:ok, %Checkpoint{metadata: md}} = Ets.get_latest(ctx.config, meta.run_id)
      assert md.run_id == meta.run_id
      assert md.graph_id == :int
      assert md.node_id in [:a, :b]
    end

    test "initial checkpoint at step 0 is :__start__ with the initial state",
         ctx do
      compiled = two_node_graph(ctx.saver)
      {:ok, _final, meta} = Compiled.invoke(compiled, %{seed: 1})

      {:ok, all} = Ets.list(ctx.config, meta.run_id, 10)
      [initial] = Enum.filter(all, &(&1.step == 0))

      assert initial.metadata.node_id == :__start__
      assert initial.state == %{seed: 1}
      assert initial.parent_step == nil
    end

    test "checkpoint state reflects the state after each node", ctx do
      compiled = two_node_graph(ctx.saver)
      {:ok, _final, meta} = Compiled.invoke(compiled, %{})

      {:ok, all} = Ets.list(ctx.config, meta.run_id, 10)
      ordered = Enum.sort_by(all, & &1.step)
      [_initial, after_a, after_b] = ordered

      assert after_a.state == %{a: true}
      assert after_b.state == %{a: true, b: true}
    end

    test "parent_step chains through the run", ctx do
      compiled = two_node_graph(ctx.saver)
      {:ok, _final, meta} = Compiled.invoke(compiled, %{})

      {:ok, all} = Ets.list(ctx.config, meta.run_id, 10)
      ordered = Enum.sort_by(all, & &1.step)

      assert Enum.at(ordered, 0).parent_step == nil
      assert Enum.at(ordered, 1).parent_step == 0
      assert Enum.at(ordered, 2).parent_step == 1
    end

    test "no checkpoints when :saver is absent", ctx do
      compiled =
        Graph.new(:nosav)
        |> Graph.add_node(:n, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :n)
        |> Graph.add_edge(:n, :__end__)
        |> Graph.compile()
        |> elem(1)

      {:ok, _, meta} = Compiled.invoke(compiled, %{})
      assert {:ok, []} = Ets.list(ctx.config, meta.run_id, 10)
    end

    test "interrupt: only checkpoints up to the interrupting node's predecessor",
         ctx do
      compiled =
        Graph.new(:pause)
        |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :a, true)} end)
        |> Graph.add_node(:b, fn _ -> {:interrupt, :wait} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile(saver: ctx.saver)
        |> elem(1)

      {:interrupted, run_id, _state, :wait} = Compiled.invoke(compiled, %{})

      {:ok, checkpoints} = Ets.list(ctx.config, run_id, 10)
      assert length(checkpoints) == 2
      latest = hd(checkpoints)
      assert latest.metadata.node_id == :a
      assert latest.state == %{a: true}
    end

    test "error: no checkpoint for the failing node, prior ones preserved",
         ctx do
      compiled =
        Graph.new(:err)
        |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :a, true)} end)
        |> Graph.add_node(:b, fn _ -> {:error, :boom} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile(saver: ctx.saver)
        |> elem(1)

      {:error, :boom, _state} = Compiled.invoke(compiled, %{})

      # :__start__ initial + :a; no checkpoint for the failing :b.
      table = ctx.config.table
      all = :ets.tab2list(table)
      assert length(all) == 2
    end
  end
end
