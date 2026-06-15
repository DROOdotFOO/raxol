defmodule Raxol.Workflow.GraphTest do
  use ExUnit.Case, async: true

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Edge.{ConditionalEdge, GuardedEdge}
  alias Raxol.Workflow.Edge.Edge, as: StaticEdge
  alias Raxol.Workflow.Graph
  alias Raxol.Workflow.Node.{BehaviourNode, FunctionNode, TypedNode}

  defmodule SampleBehaviourNode do
    @behaviour Raxol.Workflow.Node

    @impl true
    def run(state, _opts), do: {:ok, state}
  end

  defmodule SampleTypedStruct do
    defstruct [:label]
  end

  describe "new/1" do
    test "returns an empty graph with the given id" do
      g = Graph.new(:my_flow)
      assert g.id == :my_flow
      assert g.nodes == %{}
      assert g.edges == []
    end

    test "accepts binary ids" do
      g = Graph.new("flow-1")
      assert g.id == "flow-1"
    end
  end

  describe "add_node/3" do
    test "function body produces a FunctionNode" do
      fun = fn s -> {:ok, s} end
      g = Graph.new(:f) |> Graph.add_node(:n, fun)

      assert %FunctionNode{id: :n, fun: ^fun} = g.nodes[:n]
    end

    test "{module, opts} tuple produces a BehaviourNode" do
      g = Graph.new(:f) |> Graph.add_node(:n, {SampleBehaviourNode, [k: :v]})

      assert %BehaviourNode{
               id: :n,
               module: SampleBehaviourNode,
               opts: [k: :v]
             } = g.nodes[:n]
    end

    test "struct body produces a TypedNode" do
      struct = %SampleTypedStruct{label: "x"}
      g = Graph.new(:f) |> Graph.add_node(:n, struct)

      assert %TypedNode{id: :n, struct: ^struct} = g.nodes[:n]
    end

    test "raises on unsupported body" do
      assert_raise ArgumentError, fn ->
        Graph.new(:f) |> Graph.add_node(:n, "not a function")
      end
    end
  end

  describe "add_edge / add_guarded_edge / add_conditional_edge" do
    test "static edge stored" do
      g = Graph.new(:f) |> Graph.add_edge(:a, :b)
      assert [%StaticEdge{from: :a, to: :b}] = g.edges
    end

    test "guarded edge stored with guard" do
      guard = fn _ -> true end
      g = Graph.new(:f) |> Graph.add_guarded_edge(:a, :b, guard)
      assert [%GuardedEdge{from: :a, to: :b, guard: ^guard}] = g.edges
    end

    test "conditional edge stores candidates" do
      chooser = fn _ -> :x end
      g = Graph.new(:f) |> Graph.add_conditional_edge(:a, [:b, :c], chooser)

      assert [
               %ConditionalEdge{
                 from: :a,
                 candidates: [:b, :c],
                 chooser: ^chooser
               }
             ] =
               g.edges
    end

    test "edge insertion preserves order" do
      g =
        Graph.new(:f)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :c)
        |> Graph.add_edge(:c, :d)

      assert Enum.map(g.edges, & &1.from) == [:a, :b, :c]
    end
  end

  describe "compile/1: happy paths" do
    test "minimal linear graph compiles cleanly" do
      assert {:ok, %Compiled{} = compiled} =
               Graph.new(:linear)
               |> Graph.add_node(:work, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :work)
               |> Graph.add_edge(:work, :__end__)
               |> Graph.compile()

      assert compiled.id == :linear
      assert Map.keys(compiled.nodes) == [:work]
      assert compiled.edges_by_source[:__start__] != nil
      assert compiled.edges_by_source[:work] != nil
    end

    test "compile carries opts onto Compiled" do
      assert {:ok, compiled} =
               Graph.new(:opts)
               |> Graph.add_node(:n, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :n)
               |> Graph.add_edge(:n, :__end__)
               |> Graph.compile(
                 failure_policy: :compensate,
                 step_timeout_ms: 5_000,
                 run_timeout_ms: 60_000,
                 saver: SomeSaver
               )

      assert compiled.opts == %{
               failure_policy: :compensate,
               step_timeout_ms: 5_000,
               run_timeout_ms: 60_000,
               saver: SomeSaver
             }
    end

    test "compile drops unrecognized opts" do
      assert {:ok, compiled} =
               Graph.new(:o)
               |> Graph.add_node(:n, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :n)
               |> Graph.add_edge(:n, :__end__)
               |> Graph.compile(garbage: true, step_timeout_ms: 1)

      assert compiled.opts == %{step_timeout_ms: 1}
    end

    test "branching graph compiles" do
      assert {:ok, _} =
               Graph.new(:branch)
               |> Graph.add_node(:a, fn s -> {:ok, s} end)
               |> Graph.add_node(:b, fn s -> {:ok, s} end)
               |> Graph.add_node(:c, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :a)
               |> Graph.add_conditional_edge(:a, [:b, :c], fn _ -> :b end)
               |> Graph.add_edge(:b, :__end__)
               |> Graph.add_edge(:c, :__end__)
               |> Graph.compile()
    end
  end

  describe "compile/1: validation errors" do
    test "no start edge -> {:missing_start_edge, :__start__}" do
      assert {:error, {:missing_start_edge, :__start__}} =
               Graph.new(:no_start)
               |> Graph.add_node(:n, fn s -> {:ok, s} end)
               |> Graph.add_edge(:n, :__end__)
               |> Graph.compile()
    end

    test "no end edge -> {:missing_end_edge, :__end__}" do
      assert {:error, {:missing_end_edge, :__end__}} =
               Graph.new(:no_end)
               |> Graph.add_node(:n, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :n)
               |> Graph.compile()
    end

    test "edge references unknown node -> {:unknown_node, [_]}" do
      assert {:error, {:unknown_node, [:ghost]}} =
               Graph.new(:ghost)
               |> Graph.add_node(:n, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :n)
               |> Graph.add_edge(:n, :ghost)
               |> Graph.add_edge(:ghost, :__end__)
               |> Graph.compile()
    end

    test "orphan node (no incoming or outgoing edges) -> {:orphan_nodes, [_]}" do
      # :work is declared but no edge touches it; :alt linear path covers
      # start/end so the other checks pass.
      assert {:error, {:orphan_nodes, [:work]}} =
               Graph.new(:orphan)
               |> Graph.add_node(:alt, fn s -> {:ok, s} end)
               |> Graph.add_node(:work, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :alt)
               |> Graph.add_edge(:alt, :__end__)
               |> Graph.compile()
    end

    test "unreachable node -> {:unreachable_from_start, [_]}" do
      # :unreach has an edge to :__end__ but nothing reaches :unreach
      # from :__start__; main linear path avoids it but uses it as
      # in_play to dodge the orphan check.
      assert {:error, {:unreachable_from_start, [:unreach]}} =
               Graph.new(:un)
               |> Graph.add_node(:main, fn s -> {:ok, s} end)
               |> Graph.add_node(:unreach, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :main)
               |> Graph.add_edge(:main, :__end__)
               |> Graph.add_edge(:unreach, :main)
               |> Graph.compile()
    end

    test "cannot reach end -> {:cannot_reach_end, [_]}" do
      # :dead is reached from start but never reaches :__end__.
      assert {:error, {:cannot_reach_end, [:dead]}} =
               Graph.new(:dead)
               |> Graph.add_node(:main, fn s -> {:ok, s} end)
               |> Graph.add_node(:dead, fn s -> {:ok, s} end)
               |> Graph.add_edge(:__start__, :main)
               |> Graph.add_edge(:__start__, :dead)
               |> Graph.add_edge(:main, :__end__)
               |> Graph.compile()
    end
  end
end
