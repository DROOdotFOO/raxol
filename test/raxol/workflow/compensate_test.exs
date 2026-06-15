defmodule Raxol.Workflow.CompensateTest do
  use ExUnit.Case, async: false

  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  describe "failure_policy :compensate" do
    test "runs compensations in reverse order for nodes that succeeded" do
      {:ok, compiled} =
        Graph.new(:saga)
        |> Graph.add_node(
          :reserve,
          fn s -> {:ok, Map.put(s, :reserved, true)} end,
          fn s -> {:ok, Map.put(s, :reserve_compensated, true)} end
        )
        |> Graph.add_node(
          :charge,
          fn s -> {:ok, Map.put(s, :charged, true)} end,
          fn s -> {:ok, Map.put(s, :charge_compensated, true)} end
        )
        |> Graph.add_node(:ship, fn _ -> {:error, :ship_failed} end)
        |> Graph.add_edge(:__start__, :reserve)
        |> Graph.add_edge(:reserve, :charge)
        |> Graph.add_edge(:charge, :ship)
        |> Graph.add_edge(:ship, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      assert {:error, :ship_failed, final_state} =
               Compiled.invoke(compiled, %{})

      # Both compensations ran (charge first, then reserve).
      assert final_state.reserved == true
      assert final_state.charged == true
      assert final_state.charge_compensated == true
      assert final_state.reserve_compensated == true
    end

    test "compensations thread state through reverse execution" do
      {:ok, compiled} =
        Graph.new(:thread)
        |> Graph.add_node(
          :a,
          fn s -> {:ok, Map.put(s, :a, true)} end,
          fn s -> {:ok, Map.update(s, :order, [:a], &[:a | &1])} end
        )
        |> Graph.add_node(
          :b,
          fn s -> {:ok, Map.put(s, :b, true)} end,
          fn s -> {:ok, Map.update(s, :order, [:b], &[:b | &1])} end
        )
        |> Graph.add_node(:c, fn _ -> {:error, :c_failed} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :c)
        |> Graph.add_edge(:c, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      assert {:error, :c_failed, %{order: order}} =
               Compiled.invoke(compiled, %{})

      # b is compensated first (reverse order), prepending to :order.
      # Then a, also prepending. Final order: [:a, :b].
      assert order == [:a, :b]
    end

    test "nodes without compensate_fun are skipped silently" do
      {:ok, compiled} =
        Graph.new(:partial)
        |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :a, true)} end)
        |> Graph.add_node(
          :b,
          fn s -> {:ok, Map.put(s, :b, true)} end,
          fn s -> {:ok, Map.put(s, :b_compensated, true)} end
        )
        |> Graph.add_node(:c, fn _ -> {:error, :boom} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :c)
        |> Graph.add_edge(:c, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      assert {:error, :boom, final_state} = Compiled.invoke(compiled, %{})
      # b had compensate; a did not.
      assert final_state.b_compensated == true
      refute Map.has_key?(final_state, :a_compensated)
    end

    test "no compensations run when the workflow succeeds" do
      {:ok, compiled} =
        Graph.new(:success)
        |> Graph.add_node(
          :a,
          fn s -> {:ok, Map.put(s, :a, true)} end,
          fn s -> {:ok, Map.put(s, :a_compensated, true)} end
        )
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, %{})
      assert final.a == true
      refute Map.has_key?(final, :a_compensated)
    end

    test "compensate is a no-op under :halt policy (default)" do
      {:ok, compiled} =
        Graph.new(:halt_default)
        |> Graph.add_node(
          :a,
          fn s -> {:ok, Map.put(s, :a, true)} end,
          fn s -> {:ok, Map.put(s, :a_compensated, true)} end
        )
        |> Graph.add_node(:b, fn _ -> {:error, :boom} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile()

      assert {:error, :boom, final_state} = Compiled.invoke(compiled, %{})
      assert final_state.a == true
      refute Map.has_key?(final_state, :a_compensated)
    end

    test "compensate errors are surfaced via telemetry, original failure still wins" do
      test_pid = self()
      handler_id = "compensate_tel_#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol, :workflow, :node, :compensated],
        fn _event, _m, metadata, _ ->
          send(test_pid, {:compensated, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, compiled} =
        Graph.new(:comp_error)
        |> Graph.add_node(
          :a,
          fn s -> {:ok, Map.put(s, :a, true)} end,
          fn _ -> {:error, :compensation_failed} end
        )
        |> Graph.add_node(:b, fn _ -> {:error, :original_failure} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      assert {:error, :original_failure, _} = Compiled.invoke(compiled, %{})

      assert_receive {:compensated,
                      %{
                        node_id: :a,
                        result: {:error, :compensation_failed}
                      }},
                     500
    end

    test "raised exceptions inside compensate are caught and reported as :exception" do
      test_pid = self()
      handler_id = "compensate_raise_#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol, :workflow, :node, :compensated],
        fn _event, _m, metadata, _ ->
          send(test_pid, {:compensated, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, compiled} =
        Graph.new(:comp_raise)
        |> Graph.add_node(
          :a,
          fn s -> {:ok, Map.put(s, :a, true)} end,
          fn _ -> raise "compensate kaboom" end
        )
        |> Graph.add_node(:b, fn _ -> {:error, :original} end)
        |> Graph.add_edge(:__start__, :a)
        |> Graph.add_edge(:a, :b)
        |> Graph.add_edge(:b, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      Compiled.invoke(compiled, %{})

      assert_receive {:compensated,
                      %{
                        node_id: :a,
                        result: {:error, {:exception, "compensate kaboom"}}
                      }},
                     500
    end
  end

  describe "BehaviourNode compensation" do
    defmodule CompensableNode do
      @behaviour Raxol.Workflow.Node

      @impl true
      def run(state, _opts), do: {:ok, Map.put(state, :ran, true)}

      @impl true
      def compensate(state, _opts),
        do: {:ok, Map.put(state, :compensated, true)}
    end

    defmodule NonCompensableNode do
      @behaviour Raxol.Workflow.Node

      @impl true
      def run(state, _opts), do: {:ok, Map.put(state, :nc_ran, true)}
    end

    test "BehaviourNode with compensate/2 runs under :compensate policy" do
      {:ok, compiled} =
        Graph.new(:beh_comp)
        |> Graph.add_node(:beh, {CompensableNode, []})
        |> Graph.add_node(:bomb, fn _ -> {:error, :boom} end)
        |> Graph.add_edge(:__start__, :beh)
        |> Graph.add_edge(:beh, :bomb)
        |> Graph.add_edge(:bomb, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      assert {:error, :boom, final} = Compiled.invoke(compiled, %{})
      assert final.ran == true
      assert final.compensated == true
    end

    test "BehaviourNode without compensate/2 is silently skipped" do
      {:ok, compiled} =
        Graph.new(:beh_nocomp)
        |> Graph.add_node(:nc, {NonCompensableNode, []})
        |> Graph.add_node(:bomb, fn _ -> {:error, :boom} end)
        |> Graph.add_edge(:__start__, :nc)
        |> Graph.add_edge(:nc, :bomb)
        |> Graph.add_edge(:bomb, :__end__)
        |> Graph.compile(failure_policy: :compensate)

      assert {:error, :boom, final} = Compiled.invoke(compiled, %{})
      assert final.nc_ran == true
    end
  end
end
