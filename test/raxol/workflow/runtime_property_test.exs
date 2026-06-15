# credo:disable-for-this-file Credo.Check.Refactor.AppendSingleItem
defmodule Raxol.Workflow.RuntimePropertyTest do
  @moduledoc """
  Property tests for `Raxol.Workflow.Runtime.invoke/3`.

  The example tests in `runtime_test.exs` pin specific shapes and
  result tuples. The properties below stress the linear-chain happy
  path and the telemetry contract over generated graph sizes.

  The `credo:disable` directive above acknowledges that the chain
  builder uses `++ [:__end__]` to append a sentinel; the generator is
  a write-once helper, not a hot path.
  """

  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  describe "property: linear chains always terminate cleanly" do
    property "an N-node chain of FunctionNodes returning {:ok, state+1} always returns {:ok, %{count: N}, _}" do
      check all(chain_length <- integer(1..15), max_runs: 25) do
        ids =
          for n <- 1..chain_length, do: String.to_atom("step_#{n}")

        graph =
          ids
          |> Enum.reduce(Graph.new(:linear_prop), fn id, g ->
            Graph.add_node(g, id, fn s ->
              {:ok, Map.update(s, :count, 1, &(&1 + 1))}
            end)
          end)

        # Wire __start__ -> step_1 -> step_2 -> ... -> step_N -> __end__
        graph =
          [:__start__ | ids]
          |> Enum.zip(ids ++ [:__end__])
          |> Enum.reduce(graph, fn {from, to}, g ->
            Graph.add_edge(g, from, to)
          end)

        assert {:ok, compiled} = Graph.compile(graph)
        assert {:ok, %{count: n}, meta} = Compiled.invoke(compiled, %{})
        assert n == chain_length
        assert meta.nodes_executed == chain_length
      end
    end
  end

  describe "property: telemetry count matches structural execution count" do
    property "node.started count == node.completed count == graph length" do
      check all(chain_length <- integer(1..6), max_runs: 15) do
        handler_id = "rtprop_#{:erlang.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach_many(
          handler_id,
          [
            [:raxol, :workflow, :node, :started],
            [:raxol, :workflow, :node, :completed]
          ],
          fn event, _m, _md, _ ->
            send(test_pid, {:tel, event})
          end,
          nil
        )

        ids = for n <- 1..chain_length, do: String.to_atom("n_#{n}")

        graph =
          ids
          |> Enum.reduce(Graph.new(:tel_prop), fn id, g ->
            Graph.add_node(g, id, fn s -> {:ok, s} end)
          end)

        graph =
          [:__start__ | ids]
          |> Enum.zip(ids ++ [:__end__])
          |> Enum.reduce(graph, fn {from, to}, g ->
            Graph.add_edge(g, from, to)
          end)

        {:ok, compiled} = Graph.compile(graph)
        assert {:ok, _, _} = Compiled.invoke(compiled, %{})

        started = drain_tel([:raxol, :workflow, :node, :started])
        completed = drain_tel([:raxol, :workflow, :node, :completed])

        :telemetry.detach(handler_id)

        assert started == chain_length
        assert completed == chain_length
      end
    end
  end

  defp drain_tel(event, count \\ 0) do
    receive do
      {:tel, ^event} -> drain_tel(event, count + 1)
    after
      0 -> count
    end
  end
end
