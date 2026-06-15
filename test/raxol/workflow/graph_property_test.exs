# credo:disable-for-this-file Credo.Check.Refactor.AppendSingleItem
# credo:disable-for-this-file Credo.Check.Refactor.ABCSize
defmodule Raxol.Workflow.GraphPropertyTest do
  @moduledoc """
  Property tests on `Raxol.Workflow.Graph.compile/2` validation rules.

  The graph builder has six independent validation rules
  (`missing_start_edge`, `missing_end_edge`, `unknown_node`,
  `orphan_nodes`, `unreachable_from_start`, `cannot_reach_end`). Example
  tests pin one happy path and one error path per rule; the properties
  below stress the rules with generated graphs to surface interactions
  the example tests miss.

  The two `credo:disable` directives above acknowledge that the test
  generators use `++ [sentinel]` to build start/end-anchored chains
  and that `arbitrary_graph/0` is intentionally complex enough that
  the ABC-size check fires; both are write-once helpers that don't
  warrant the rephrasing.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Workflow.Graph

  @start :__start__
  @end_ :__end__

  describe "property: linear graphs always compile" do
    property "any linear chain of N nodes with start and end edges compiles" do
      check all(node_count <- integer(1..10), max_runs: 50) do
        ids =
          for n <- 1..node_count, do: String.to_atom("node_#{n}")

        graph =
          ids
          |> Enum.reduce(Graph.new(:linear), fn id, g ->
            Graph.add_node(g, id, fn s -> {:ok, s} end)
          end)

        graph =
          [@start | ids]
          |> Enum.zip(ids ++ [@end_])
          |> Enum.reduce(graph, fn {from, to}, g ->
            Graph.add_edge(g, from, to)
          end)

        assert {:ok, compiled} = Graph.compile(graph)
        assert Map.keys(compiled.nodes) |> Enum.sort() == Enum.sort(ids)
      end
    end
  end

  describe "property: compile/2 either succeeds or returns a structured error" do
    property "any builder sequence yields {:ok, _} or {:error, atom_or_tuple}" do
      check all(graph <- arbitrary_graph(), max_runs: 100) do
        case Graph.compile(graph) do
          {:ok, _compiled} ->
            :ok

          {:error, reason} ->
            assert valid_error?(reason),
                   "unexpected error shape: #{inspect(reason)}"
        end
      end
    end
  end

  describe "property: orphan node detection" do
    property "an isolated extra node always trips :orphan_nodes" do
      check all(
              extra_id <- node_id_generator(),
              base_size <- integer(1..4),
              max_runs: 25
            ) do
        ids =
          for n <- 1..base_size, do: String.to_atom("base_#{n}")

        # Avoid collision between the extra and the linear chain.
        if extra_id in ids do
          :ok
        else
          graph =
            (ids ++ [extra_id])
            |> Enum.reduce(Graph.new(:orphan_check), fn id, g ->
              Graph.add_node(g, id, fn s -> {:ok, s} end)
            end)

          linear_edges =
            [@start | ids]
            |> Enum.zip(ids ++ [@end_])

          graph =
            linear_edges
            |> Enum.reduce(graph, fn {from, to}, g ->
              Graph.add_edge(g, from, to)
            end)

          assert {:error, {:orphan_nodes, orphans}} = Graph.compile(graph)
          assert orphans == [extra_id]
        end
      end
    end
  end

  describe "property: every reachable node has a path to :__end__" do
    property "a node reachable from start but with no outgoing edge trips :cannot_reach_end" do
      check all(
              base_size <- integer(1..4),
              dead_id <- node_id_generator(),
              max_runs: 25
            ) do
        ids = for n <- 1..base_size, do: String.to_atom("alive_#{n}")

        if dead_id in ids do
          :ok
        else
          graph =
            (ids ++ [dead_id])
            |> Enum.reduce(Graph.new(:dead_check), fn id, g ->
              Graph.add_node(g, id, fn s -> {:ok, s} end)
            end)

          linear_edges =
            [@start | ids] |> Enum.zip(ids ++ [@end_])

          graph =
            linear_edges
            |> Enum.reduce(graph, fn {from, to}, g ->
              Graph.add_edge(g, from, to)
            end)
            # dead_id is reached but has no outgoing edge to :__end__
            |> Graph.add_edge(@start, dead_id)

          assert {:error, {:cannot_reach_end, [^dead_id]}} =
                   Graph.compile(graph)
        end
      end
    end
  end

  # --- Generators ---

  defp arbitrary_graph do
    gen all(
          node_count <- integer(0..6),
          edge_count <- integer(0..10)
        ) do
      ids = for n <- 1..node_count, n > 0, do: String.to_atom("n_#{n}")

      graph =
        Enum.reduce(ids, Graph.new(:arb), fn id, g ->
          Graph.add_node(g, id, fn s -> {:ok, s} end)
        end)

      edge_pool = [@start | ids] ++ [@end_]

      Enum.reduce(1..edge_count, graph, fn _, g ->
        from = Enum.random(edge_pool)
        to = Enum.random(edge_pool)
        Graph.add_edge(g, from, to)
      end)
    end
  end

  defp node_id_generator do
    gen all(suffix <- string(:alphanumeric, min_length: 3, max_length: 8)) do
      String.to_atom("extra_" <> suffix)
    end
  end

  defp valid_error?({:missing_start_edge, @start}), do: true
  defp valid_error?({:missing_end_edge, @end_}), do: true
  defp valid_error?({:unknown_node, ids}), do: is_list(ids)
  defp valid_error?({:orphan_nodes, ids}), do: is_list(ids)
  defp valid_error?({:unreachable_from_start, ids}), do: is_list(ids)
  defp valid_error?({:cannot_reach_end, ids}), do: is_list(ids)
  defp valid_error?(_), do: false
end
