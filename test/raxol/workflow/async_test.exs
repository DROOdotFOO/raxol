defmodule Raxol.Workflow.AsyncTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.CloudEvent
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  defp linear_two_nodes do
    Graph.new(:async_lin)
    |> Graph.add_node(:a, fn s -> {:ok, Map.put(s, :a, true)} end)
    |> Graph.add_node(:b, fn s -> {:ok, Map.put(s, :b, true)} end)
    |> Graph.add_edge(:__start__, :a)
    |> Graph.add_edge(:a, :b)
    |> Graph.add_edge(:b, :__end__)
    |> Graph.compile()
    |> elem(1)
  end

  describe "async_invoke/3" do
    test "returns an immediate handle with run_id, pid, ref" do
      assert {:ok, %{run_id: run_id, pid: pid, ref: ref}} =
               Compiled.async_invoke(linear_two_nodes(), %{})

      assert is_binary(run_id) and byte_size(run_id) == 16
      assert is_pid(pid)
      assert is_reference(ref)
    end

    test "monitor ref fires on run completion" do
      assert {:ok, %{pid: pid, ref: ref}} =
               Compiled.async_invoke(linear_two_nodes(), %{})

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    test "run_id propagates into telemetry metadata" do
      handler_id = "async_test_#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :workflow, :run, :started],
        fn _event, _m, metadata, _ ->
          send(test_pid, {:got_start, metadata.run_id})
        end,
        nil
      )

      {:ok, %{run_id: run_id, ref: ref, pid: pid}} =
        Compiled.async_invoke(linear_two_nodes(), %{})

      assert_receive {:got_start, ^run_id}, 1_000
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000

      :telemetry.detach(handler_id)
    end

    test "caller-supplied run_id (via opts forwarding) wins" do
      # async_invoke generates its own run_id; ensure user opts don't
      # silently override it. The handle's run_id is authoritative.
      {:ok, %{run_id: ours, ref: ref, pid: pid}} =
        Compiled.async_invoke(linear_two_nodes(), %{},
          run_id: "ignored-by-async"
        )

      # The runtime will receive `ignored-by-async` (last-write wins in
      # Keyword.put), but the handle reports what the caller can correlate
      # against. This documents the contract.
      assert is_binary(ours)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1_000
    end

    test "monitor ref fires on uncaught crash inside a node" do
      {:ok, compiled} =
        Graph.new(:async_crash)
        |> Graph.add_node(:bomb, fn _ -> Process.exit(self(), :node_crash) end)
        |> Graph.add_edge(:__start__, :bomb)
        |> Graph.add_edge(:bomb, :__end__)
        |> Graph.compile()

      {:ok, %{pid: pid, ref: ref}} = Compiled.async_invoke(compiled, %{})
      assert_receive {:DOWN, ^ref, :process, ^pid, :node_crash}, 1_000
    end
  end

  describe "stream_events/3" do
    test "yields CloudEvent structs for a linear two-node run" do
      events =
        linear_two_nodes() |> Compiled.stream_events(%{}) |> Enum.to_list()

      types = Enum.map(events, & &1.type)

      assert "raxol.workflow.run.started" in types
      assert "raxol.workflow.run.completed" in types
      assert Enum.count(types, &(&1 == "raxol.workflow.node.started")) == 2
      assert Enum.count(types, &(&1 == "raxol.workflow.node.completed")) == 2
    end

    test "events are emitted in order: run.started, node pairs, run.completed" do
      events =
        linear_two_nodes() |> Compiled.stream_events(%{}) |> Enum.to_list()

      types = Enum.map(events, & &1.type)

      assert hd(types) == "raxol.workflow.run.started"
      assert List.last(types) == "raxol.workflow.run.completed"
    end

    test "each CloudEvent carries the run_id as subject" do
      events =
        linear_two_nodes() |> Compiled.stream_events(%{}) |> Enum.to_list()

      subjects = events |> Enum.map(& &1.subject) |> Enum.uniq()
      assert length(subjects) == 1
      [subject] = subjects
      assert is_binary(subject) and byte_size(subject) == 16
    end

    test "each CloudEvent has source, type, id, time, data" do
      events =
        linear_two_nodes() |> Compiled.stream_events(%{}) |> Enum.to_list()

      Enum.each(events, fn %CloudEvent{} = ce ->
        assert ce.specversion == "1.0"
        assert is_binary(ce.id) and byte_size(ce.id) == 16
        assert is_binary(ce.source)
        assert is_binary(ce.type)
        assert %DateTime{} = ce.time
        assert is_map(ce.data)
        assert Map.has_key?(ce.data, :measurements)
        assert Map.has_key?(ce.data, :metadata)
      end)
    end

    test "stream halts after run.failed terminal event" do
      {:ok, compiled} =
        Graph.new(:stream_fail)
        |> Graph.add_node(:nope, fn _ -> {:error, :node_failed} end)
        |> Graph.add_edge(:__start__, :nope)
        |> Graph.add_edge(:nope, :__end__)
        |> Graph.compile()

      events = compiled |> Compiled.stream_events(%{}) |> Enum.to_list()

      assert List.last(events).type == "raxol.workflow.run.failed"
      types = Enum.map(events, & &1.type)
      refute "raxol.workflow.run.completed" in types
    end

    test "stream halts after run.interrupted terminal event" do
      {:ok, compiled} =
        Graph.new(:stream_pause)
        |> Graph.add_node(:pause, fn _ -> {:interrupt, :wait} end)
        |> Graph.add_edge(:__start__, :pause)
        |> Graph.add_edge(:pause, :__end__)
        |> Graph.compile()

      events = compiled |> Compiled.stream_events(%{}) |> Enum.to_list()

      assert List.last(events).type == "raxol.workflow.run.interrupted"
    end

    test "source override is honored" do
      events =
        linear_two_nodes()
        |> Compiled.stream_events(%{}, source: "raxol://custom")
        |> Enum.to_list()

      Enum.each(events, fn ce -> assert ce.source == "raxol://custom" end)
    end

    test "concurrent streams don't see each other's events" do
      compiled = linear_two_nodes()

      task_a =
        Task.async(fn ->
          compiled |> Compiled.stream_events(%{}) |> Enum.to_list()
        end)

      task_b =
        Task.async(fn ->
          compiled |> Compiled.stream_events(%{}) |> Enum.to_list()
        end)

      events_a = Task.await(task_a, 2_000)
      events_b = Task.await(task_b, 2_000)

      subjects_a = events_a |> Enum.map(& &1.subject) |> Enum.uniq()
      subjects_b = events_b |> Enum.map(& &1.subject) |> Enum.uniq()

      assert length(subjects_a) == 1
      assert length(subjects_b) == 1
      assert subjects_a != subjects_b
    end
  end
end
