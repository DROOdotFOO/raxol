defmodule Raxol.Workflow.ResumeTest do
  use ExUnit.Case, async: false

  alias Raxol.Workflow
  alias Raxol.Workflow.Checkpoint.Saver.Ets
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  setup do
    table = :"resume_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, config: %{table: table}, saver: {Ets, %{table: table}}}
  end

  defp approval_graph(saver) do
    Graph.new(:approval)
    |> Graph.add_node(:prep, fn s -> {:ok, Map.put(s, :prepared, true)} end)
    |> Graph.add_node(:approve, fn s ->
      decision = Workflow.interrupt(:awaiting_approval)
      {:ok, Map.put(s, :decision, decision)}
    end)
    |> Graph.add_node(:finalize, fn s -> {:ok, Map.put(s, :final, true)} end)
    |> Graph.add_edge(:__start__, :prep)
    |> Graph.add_edge(:prep, :approve)
    |> Graph.add_edge(:approve, :finalize)
    |> Graph.add_edge(:finalize, :__end__)
    |> Graph.compile(saver: saver)
    |> elem(1)
  end

  describe "interrupt path" do
    test "Workflow.interrupt inside a node returns {:interrupted, run_id, state, value}",
         ctx do
      compiled = approval_graph(ctx.saver)

      {:interrupted, run_id, state, value} = Compiled.invoke(compiled, %{})

      assert is_binary(run_id)
      assert value == :awaiting_approval
      assert state == %{prepared: true}
    end

    test "checkpoints include a pause marker at the interrupting node (ADR-0017)",
         ctx do
      compiled = approval_graph(ctx.saver)
      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      {:ok, checkpoints} = Ets.list(ctx.config, run_id, 10)
      assert length(checkpoints) == 3
      latest = hd(checkpoints)
      assert latest.metadata.node_id == :approve
      assert latest.metadata.interrupt_reason == :awaiting_approval
      assert %DateTime{} = latest.metadata.paused_at

      node_ids =
        checkpoints |> Enum.map(& &1.metadata.node_id) |> Enum.sort()

      assert node_ids == [:__start__, :approve, :prep]
    end
  end

  describe "resume path" do
    test "Compiled.resume picks up at the interrupting node with the supplied value",
         ctx do
      compiled = approval_graph(ctx.saver)

      {:interrupted, run_id, _, :awaiting_approval} =
        Compiled.invoke(compiled, %{})

      assert {:ok, final, meta} = Compiled.resume(compiled, run_id, :approved)

      assert final == %{prepared: true, decision: :approved, final: true}
      assert meta.run_id == run_id
    end

    test "resume creates checkpoints for the nodes that run on the resume path",
         ctx do
      compiled = approval_graph(ctx.saver)
      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      {:ok, _, _} = Compiled.resume(compiled, run_id, :approved)

      {:ok, checkpoints} = Ets.list(ctx.config, run_id, 10)
      # ADR-0017: :__start__ + :prep + :approve (paused) + :approve
      # (resumed-success) + :finalize = 5 checkpoints. The two
      # :approve entries are at different steps; the latest has no
      # :interrupt_reason in metadata.
      node_ids = Enum.map(checkpoints, & &1.metadata.node_id) |> Enum.sort()
      assert node_ids == [:__start__, :approve, :approve, :finalize, :prep]

      latest = hd(checkpoints)
      refute Map.has_key?(latest.metadata, :interrupt_reason)
    end

    test "resume continues to {:ok, _} when the resume value is accepted",
         ctx do
      compiled = approval_graph(ctx.saver)
      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      assert {:ok, _, _} = Compiled.resume(compiled, run_id, :approved)
    end

    test "two consecutive interrupts can be resumed with two values", ctx do
      # Two approval gates, each preceded by a regular node so both
      # interrupts have a predecessor checkpoint to resume from.
      {:ok, compiled} =
        Graph.new(:two_gates)
        |> Graph.add_node(:pre1, fn s -> {:ok, Map.put(s, :p1, true)} end)
        |> Graph.add_node(:gate1, fn s ->
          d = Workflow.interrupt(:first_gate)
          {:ok, Map.put(s, :g1, d)}
        end)
        |> Graph.add_node(:pre2, fn s -> {:ok, Map.put(s, :p2, true)} end)
        |> Graph.add_node(:gate2, fn s ->
          d = Workflow.interrupt(:second_gate)
          {:ok, Map.put(s, :g2, d)}
        end)
        |> Graph.add_node(:done, fn s -> {:ok, Map.put(s, :done, true)} end)
        |> Graph.add_edge(:__start__, :pre1)
        |> Graph.add_edge(:pre1, :gate1)
        |> Graph.add_edge(:gate1, :pre2)
        |> Graph.add_edge(:pre2, :gate2)
        |> Graph.add_edge(:gate2, :done)
        |> Graph.add_edge(:done, :__end__)
        |> Graph.compile(saver: ctx.saver)

      {:interrupted, run_id, _, :first_gate} = Compiled.invoke(compiled, %{})

      # The first resume runs gate1 with :gate1_ok, then pre2 (which
      # writes its checkpoint), then gate2 interrupts.
      {:interrupted, ^run_id, _, :second_gate} =
        Compiled.resume(compiled, run_id, :gate1_ok)

      {:ok, final, _} = Compiled.resume(compiled, run_id, :gate2_ok)

      assert final == %{
               p1: true,
               g1: :gate1_ok,
               p2: true,
               g2: :gate2_ok,
               done: true
             }
    end
  end

  describe "first-node-interrupt resume" do
    test "resume works when the very first real node interrupts", ctx do
      {:ok, compiled} =
        Graph.new(:first_gate)
        |> Graph.add_node(:gate, fn s ->
          d = Workflow.interrupt(:wait_for_approval)
          {:ok, Map.put(s, :gate, d)}
        end)
        |> Graph.add_node(:done, fn s -> {:ok, Map.put(s, :done, true)} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_edge(:gate, :done)
        |> Graph.add_edge(:done, :__end__)
        |> Graph.compile(saver: ctx.saver)

      {:interrupted, run_id, state, :wait_for_approval} =
        Compiled.invoke(compiled, %{init: true})

      assert state == %{init: true}

      assert {:ok, final, meta} =
               Compiled.resume(compiled, run_id, :approved)

      assert final == %{init: true, gate: :approved, done: true}
      assert meta.run_id == run_id
    end

    test "the initial __start__ checkpoint carries the initial state", ctx do
      {:ok, compiled} =
        Graph.new(:first_gate_state)
        |> Graph.add_node(:gate, fn _ -> {:interrupt, :pause} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_edge(:gate, :__end__)
        |> Graph.compile(saver: ctx.saver)

      {:interrupted, run_id, _, :pause} =
        Compiled.invoke(compiled, %{seeded: :value})

      # ADR-0017: __start__ at step 0 plus a pause checkpoint for :gate at
      # step 1. Initial state is preserved on the __start__ row.
      {:ok, checkpoints} = Ets.list(ctx.config, run_id, 10)
      assert length(checkpoints) == 2

      initial = Enum.find(checkpoints, &(&1.metadata.node_id == :__start__))
      assert initial.step == 0
      assert initial.state == %{seeded: :value}

      paused = Enum.find(checkpoints, &(&1.metadata.node_id == :gate))
      assert paused.step == 1
      assert paused.metadata.interrupt_reason == :pause
    end
  end

  describe "resume error tuples" do
    test "no saver configured returns {:error, :no_saver_configured, nil}",
         _ctx do
      {:ok, compiled} =
        Graph.new(:no_saver)
        |> Graph.add_node(:n, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :n)
        |> Graph.add_edge(:n, :__end__)
        |> Graph.compile()

      assert {:error, :no_saver_configured, nil} =
               Compiled.resume(compiled, "anything", :payload)
    end

    test "no checkpoint for the run_id returns {:error, :no_checkpoint, nil}",
         ctx do
      compiled = approval_graph(ctx.saver)

      assert {:error, :no_checkpoint, nil} =
               Compiled.resume(compiled, "ghost-run-id", :anything)
    end
  end
end
