defmodule Raxol.Workflow.RuntimeTest do
  use ExUnit.Case, async: false

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  defmodule IncBehaviour do
    @behaviour Raxol.Workflow.Node

    @impl true
    def run(state, opts) do
      step = Keyword.get(opts, :step, 1)
      {:ok, Map.update(state, :count, step, &(&1 + step))}
    end
  end

  defmodule TaggedNode do
    defstruct [:tag]
  end

  defimpl Raxol.Workflow.Node.Executor,
    for: Raxol.Workflow.RuntimeTest.TaggedNode do
    def execute(%{tag: tag}, state, _opts) do
      {:ok, Map.update(state, :tags, [tag], &[tag | &1])}
    end
  end

  defp linear_two_nodes do
    Graph.new(:lin2)
    |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :a, true)} end)
    |> Graph.add_node(:b, fn s -> {:ok, Map.put(s, :b, true)} end)
    |> Graph.add_edge(:__start__, :a)
    |> Graph.add_edge(:a, :b)
    |> Graph.add_edge(:b, :__end__)
    |> Graph.compile()
    |> elem(1)
  end

  describe "linear runs" do
    test "two FunctionNodes execute in order and return final state" do
      assert {:ok, final, meta} = Compiled.invoke(linear_two_nodes(), %{})
      assert final == %{a: true, b: true}
      assert meta.nodes_executed == 2
      assert is_binary(meta.run_id)
    end

    test "BehaviourNode runs with opts" do
      {:ok, compiled} =
        Graph.new(:beh)
        |> Graph.add_node(:inc, {IncBehaviour, [step: 5]})
        |> Graph.add_edge(:__start__, :inc)
        |> Graph.add_edge(:inc, :__end__)
        |> Graph.compile()

      assert {:ok, %{count: 5}, _meta} = Compiled.invoke(compiled, %{})
    end

    test "TypedNode dispatches via Node.Executor protocol" do
      {:ok, compiled} =
        Graph.new(:typed)
        |> Graph.add_node(:tag, %TaggedNode{tag: :hello})
        |> Graph.add_edge(:__start__, :tag)
        |> Graph.add_edge(:tag, :__end__)
        |> Graph.compile()

      assert {:ok, %{tags: [:hello]}, _meta} = Compiled.invoke(compiled, %{})
    end
  end

  describe "guarded edges" do
    test "first matching guard wins" do
      {:ok, compiled} =
        Graph.new(:guards)
        |> Graph.add_node(:start_n, fn s -> {:ok, s} end)
        |> Graph.add_node(:left, fn s -> {:ok, Map.put(s, :branch, :left)} end)
        |> Graph.add_node(:right, fn s -> {:ok, Map.put(s, :branch, :right)} end)
        |> Graph.add_edge(:__start__, :start_n)
        |> Graph.add_guarded_edge(:start_n, :left, fn s -> s.go == :left end)
        |> Graph.add_guarded_edge(:start_n, :right, fn s -> s.go == :right end)
        |> Graph.add_edge(:left, :__end__)
        |> Graph.add_edge(:right, :__end__)
        |> Graph.compile()

      assert {:ok, %{branch: :left}, _} =
               Compiled.invoke(compiled, %{go: :left})

      assert {:ok, %{branch: :right}, _} =
               Compiled.invoke(compiled, %{go: :right})
    end

    test "no guard matches -> {:error, :no_outgoing_edge_matched}" do
      {:ok, compiled} =
        Graph.new(:no_match)
        |> Graph.add_node(:start_n, fn s -> {:ok, s} end)
        |> Graph.add_node(:never, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :start_n)
        |> Graph.add_guarded_edge(:start_n, :never, fn _ -> false end)
        |> Graph.add_edge(:never, :__end__)
        |> Graph.compile()

      assert {:error, {:no_outgoing_edge_matched, :start_n}, %{}} =
               Compiled.invoke(compiled, %{})
    end
  end

  describe "conditional edges" do
    test "chooser routes to a single candidate" do
      {:ok, compiled} =
        Graph.new(:cond)
        |> Graph.add_node(:pick, fn s -> {:ok, s} end)
        |> Graph.add_node(:x, fn s -> {:ok, Map.put(s, :took, :x)} end)
        |> Graph.add_node(:y, fn s -> {:ok, Map.put(s, :took, :y)} end)
        |> Graph.add_edge(:__start__, :pick)
        |> Graph.add_conditional_edge(:pick, [:x, :y], fn s -> s.route end)
        |> Graph.add_edge(:x, :__end__)
        |> Graph.add_edge(:y, :__end__)
        |> Graph.compile()

      assert {:ok, %{took: :x}, _} = Compiled.invoke(compiled, %{route: :x})
      assert {:ok, %{took: :y}, _} = Compiled.invoke(compiled, %{route: :y})
    end

    test "chooser returning unknown candidate is an error" do
      {:ok, compiled} =
        Graph.new(:bad_route)
        |> Graph.add_node(:pick, fn s -> {:ok, s} end)
        |> Graph.add_node(:x, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :pick)
        |> Graph.add_conditional_edge(:pick, [:x], fn _ -> :ghost end)
        |> Graph.add_edge(:x, :__end__)
        |> Graph.compile()

      assert {:error, {:chooser_returned_unknown_candidate, :ghost, [:x]}, _} =
               Compiled.invoke(compiled, %{})
    end
  end

  describe "result tuples" do
    test "node returning {:interrupt, value} returns {:interrupted, run_id, state, value}" do
      {:ok, compiled} =
        Graph.new(:pause)
        |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :seen, :a)} end)
        |> Graph.add_node(:b, fn _s -> {:interrupt, :approval_required} end)
        |> Graph.add_node(:c, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :c)
        |> Graph.add_edge(:c, :__end__)
        |> Graph.compile()

      assert {:interrupted, run_id, state, :approval_required} =
               Compiled.invoke(compiled, %{})

      assert is_binary(run_id)
      assert state == %{seen: :a}
    end

    test "node returning {:error, reason} returns {:error, reason, state}" do
      {:ok, compiled} =
        Graph.new(:err)
        |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :seen, :a)} end)
        |> Graph.add_node(:b, fn _s -> {:error, :kaboom} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()

      assert {:error, :kaboom, %{seen: :a}} = Compiled.invoke(compiled, %{})
    end

    test "node returning {:effects, [], state} continues to next node" do
      {:ok, compiled} =
        Graph.new(:effects)
        |> Graph.add_node(:a, fn s ->
          {:effects, [], Map.put(s, :effects, :done)}
        end)
        |> Graph.add_node(:b, fn s -> {:ok, Map.put(s, :b, true)} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()

      assert {:ok, %{effects: :done, b: true}, _} =
               Compiled.invoke(compiled, %{})
    end

    test "node returning unexpected shape -> {:error, {:invalid_result, _}}" do
      {:ok, compiled} =
        Graph.new(:weird)
        |> Graph.add_node(:a, fn _ -> :something_else end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :__end__)
        |> Graph.compile()

      assert {:error, {:invalid_result, :something_else}, %{}} =
               Compiled.invoke(compiled, %{})
    end

    test "raised exception in node -> {:error, {:exception, msg}, state}" do
      {:ok, compiled} =
        Graph.new(:raise)
        |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :seen, :a)} end)
        |> Graph.add_node(:b, fn _ -> raise "boom" end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()

      assert {:error, {:exception, "boom"}, %{seen: :a}} =
               Compiled.invoke(compiled, %{})
    end
  end

  describe "effects dispatch" do
    test "Directive.spawn from {:effects, [...], state} fires async, state continues" do
      {:ok, compiled} =
        Graph.new(:dispatch)
        |> Graph.add_node(:emit, fn s ->
          test_pid = s.test_pid

          dir =
            Raxol.Core.Runtime.Directive.spawn_task(fn ->
              send(test_pid, :fired)
              {:ok, :fired}
            end)

          {:effects, [dir], Map.put(s, :emitted, true)}
        end)
        |> Graph.add_node(:next, fn s -> {:ok, Map.put(s, :next, true)} end)
        |> Graph.add_edge(:__start__, :emit)
        |> Graph.add_edge(:emit, :next)
        |> Graph.add_edge(:next, :__end__)
        |> Graph.compile()

      assert {:ok, %{emitted: true, next: true}, _} =
               Compiled.invoke(compiled, %{test_pid: self()})

      assert_receive :fired, 500
    end
  end

  describe "telemetry" do
    setup do
      handler_id = "workflow_test_#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      events = [
        [:raxol, :workflow, :run, :started],
        [:raxol, :workflow, :run, :completed],
        [:raxol, :workflow, :run, :interrupted],
        [:raxol, :workflow, :run, :paused],
        [:raxol, :workflow, :run, :resumed],
        [:raxol, :workflow, :run, :failed],
        [:raxol, :workflow, :node, :started],
        [:raxol, :workflow, :node, :completed],
        [:raxol, :workflow, :node, :failed]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        fn event, measurements, metadata, _ ->
          send(test_pid, {:tel, event, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)
      :ok
    end

    test "run.started and run.completed bracket a successful run" do
      Compiled.invoke(linear_two_nodes(), %{})

      assert_receive {:tel, [:raxol, :workflow, :run, :started], %{},
                      %{run_id: rid}}

      assert is_binary(rid)

      assert_receive {:tel, [:raxol, :workflow, :run, :completed], %{},
                      %{nodes_executed: 2}}
    end

    test "each node emits started + completed with duration_us" do
      Compiled.invoke(linear_two_nodes(), %{})

      assert_receive {:tel, [:raxol, :workflow, :node, :started], _,
                      %{node_id: :a}}

      assert_receive {:tel, [:raxol, :workflow, :node, :completed],
                      %{duration_us: d1}, %{node_id: :a, result_type: :ok}}

      assert is_integer(d1) and d1 >= 0

      assert_receive {:tel, [:raxol, :workflow, :node, :started], _,
                      %{node_id: :b}}

      assert_receive {:tel, [:raxol, :workflow, :node, :completed], _,
                      %{node_id: :b}}
    end

    test "metadata carries trace_id and span_id" do
      Compiled.invoke(linear_two_nodes(), %{})

      assert_receive {:tel, [:raxol, :workflow, :run, :started], _,
                      %{trace_id: trace_id, span_id: span_id}}

      assert is_binary(trace_id) and is_binary(span_id)
    end

    test "interrupt emits run.interrupted with interrupt_reason lifted (ADR-0017)" do
      {:ok, compiled} =
        Graph.new(:pause)
        |> Graph.add_node(:pause, fn _ -> {:interrupt, :wait} end)
        |> Graph.add_edge(:__start__, :pause)
        |> Graph.add_edge(:pause, :__end__)
        |> Graph.compile()

      Compiled.invoke(compiled, %{})

      assert_receive {:tel, [:raxol, :workflow, :run, :interrupted], _,
                      %{
                        value: :wait,
                        interrupt_reason: :wait,
                        nodes_executed: 1
                      }}
    end

    test "with a saver, interrupt also emits run.paused after the pause checkpoint commits" do
      table = :"runtime_telemetry_paused_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      end)

      {:ok, compiled} =
        Graph.new(:paused_event)
        |> Graph.add_node(:gate, fn _ -> {:interrupt, :need_approval} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_edge(:gate, :__end__)
        |> Graph.compile(
          saver: {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}
        )

      Compiled.invoke(compiled, %{})

      assert_receive {:tel, [:raxol, :workflow, :run, :paused], _,
                      %{
                        node_id: :gate,
                        interrupt_reason: :need_approval,
                        paused_at: %DateTime{}
                      }}
    end

    test "resume emits run.resumed carrying the original interrupt_reason" do
      table =
        :"runtime_telemetry_resumed_#{:erlang.unique_integer([:positive])}"

      on_exit(fn ->
        if :ets.whereis(table) != :undefined, do: :ets.delete(table)
      end)

      {:ok, compiled} =
        Graph.new(:resumed_event)
        |> Graph.add_node(:gate, fn s ->
          decision = Raxol.Workflow.interrupt(:need_decision)
          {:ok, Map.put(s, :decision, decision)}
        end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_edge(:gate, :__end__)
        |> Graph.compile(
          saver: {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}
        )

      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      Compiled.resume(compiled, run_id, :approved)

      assert_receive {:tel, [:raxol, :workflow, :run, :resumed], _,
                      %{
                        node_id: :gate,
                        interrupt_reason: :need_decision,
                        resume_mode: :reenter
                      }}
    end

    test "with no saver, run.paused does not fire" do
      {:ok, compiled} =
        Graph.new(:no_saver_paused)
        |> Graph.add_node(:gate, fn _ -> {:interrupt, :ignore} end)
        |> Graph.add_edge(:__start__, :gate)
        |> Graph.add_edge(:gate, :__end__)
        |> Graph.compile()

      Compiled.invoke(compiled, %{})

      # :interrupted still fires (back-compat), but :paused does not
      # because there is no durable pause state to announce.
      assert_receive {:tel, [:raxol, :workflow, :run, :interrupted], _, _}
      refute_received {:tel, [:raxol, :workflow, :run, :paused], _, _}
    end

    test "node error emits run.failed" do
      {:ok, compiled} =
        Graph.new(:fail)
        |> Graph.add_node(:nope, fn _ -> {:error, :nope_reason} end)
        |> Graph.add_edge(:__start__, :nope)
        |> Graph.add_edge(:nope, :__end__)
        |> Graph.compile()

      Compiled.invoke(compiled, %{})

      assert_receive {:tel, [:raxol, :workflow, :run, :failed], _,
                      %{reason: :nope_reason}}
    end
  end

  describe "walltime guard" do
    test "long-running graph aborts after run_timeout_ms" do
      {:ok, compiled} =
        Graph.new(:slow)
        |> Graph.add_node(:slow, fn s ->
          Process.sleep(100)
          {:ok, s}
        end)
        |> Graph.add_edge(:__start__, :slow)
        |> Graph.add_edge(:slow, :slow)
        |> Graph.add_edge(:slow, :__end__)
        |> Graph.compile()

      # Static-edge precedence picks the first outgoing (self-loop). With
      # a tiny timeout we should trip the deadline within a few iterations.
      assert {:error, :run_timeout, _state} =
               Compiled.invoke(compiled, %{}, run_timeout_ms: 50)
    end
  end
end
