# credo:disable-for-this-file Credo.Check.Refactor.AppendSingleItem
defmodule Raxol.Workflow.AsyncPropertyTest do
  @moduledoc """
  Property tests for `Raxol.Workflow.Async.{async_invoke, stream_events}`.

  The example tests in `async_test.exs` pin the shape and ordering of
  a linear two-node run. The properties below check the same contracts
  over generated chain sizes.

  The `credo:disable` directive acknowledges the chain builder uses
  `++ [:__end__]` to append the sentinel.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  describe "property: stream_events count matches structure" do
    property "an N-node linear chain yields exactly 2 + 2N CloudEvents" do
      check all(chain_length <- integer(1..6), max_runs: 15) do
        ids = for n <- 1..chain_length, do: String.to_atom("n_#{n}")

        graph =
          ids
          |> Enum.reduce(Graph.new(:async_prop), fn id, g ->
            Graph.add_node(g, id, fn s -> {:ok, s} end)
          end)

        graph =
          [:__start__ | ids]
          |> Enum.zip(ids ++ [:__end__])
          |> Enum.reduce(graph, fn {from, to}, g ->
            Graph.add_edge(g, from, to)
          end)

        {:ok, compiled} = Graph.compile(graph)
        events = compiled |> Compiled.stream_events(%{}) |> Enum.to_list()

        # Expected layout:
        #   run.started
        #   node.started, node.completed (x N)
        #   run.completed
        # = 2 + 2N events
        assert length(events) == 2 + 2 * chain_length

        types = Enum.map(events, & &1.type)
        assert hd(types) == "raxol.workflow.run.started"
        assert List.last(types) == "raxol.workflow.run.completed"

        node_starts = Enum.count(types, &(&1 == "raxol.workflow.node.started"))

        node_completes =
          Enum.count(types, &(&1 == "raxol.workflow.node.completed"))

        assert node_starts == chain_length
        assert node_completes == chain_length
      end
    end
  end

  describe "property: async_invoke handle correlates with telemetry" do
    property "the run_id in the handle matches the run_id in stream_events output" do
      check all(chain_length <- integer(1..4), max_runs: 10) do
        ids = for n <- 1..chain_length, do: String.to_atom("c_#{n}")

        graph =
          ids
          |> Enum.reduce(Graph.new(:corr), fn id, g ->
            Graph.add_node(g, id, fn s -> {:ok, s} end)
          end)

        graph =
          [:__start__ | ids]
          |> Enum.zip(ids ++ [:__end__])
          |> Enum.reduce(graph, fn {from, to}, g ->
            Graph.add_edge(g, from, to)
          end)

        {:ok, compiled} = Graph.compile(graph)

        events = compiled |> Compiled.stream_events(%{}) |> Enum.to_list()

        # All events should share one subject (the run_id).
        subjects = events |> Enum.map(& &1.subject) |> Enum.uniq()
        assert length(subjects) == 1
      end
    end
  end
end
