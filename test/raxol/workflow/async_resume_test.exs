defmodule Raxol.Workflow.AsyncResumeTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Events.CloudEvent
  alias Raxol.Workflow
  alias Raxol.Workflow.Checkpoint.Saver.Ets
  alias Raxol.Workflow.Compiled
  alias Raxol.Workflow.Graph

  setup do
    table = :"async_resume_#{:erlang.unique_integer([:positive])}"

    on_exit(fn ->
      if :ets.whereis(table) != :undefined, do: :ets.delete(table)
    end)

    {:ok, config: %{table: table}, saver: {Ets, %{table: table}}}
  end

  defp approval_graph(saver) do
    {:ok, compiled} =
      Graph.new(:async_resume)
      |> Graph.add_node(:prep, fn s -> {:ok, Map.put(s, :prep, true)} end)
      |> Graph.add_node(:gate, fn s ->
        d = Workflow.interrupt(:wait)
        {:ok, Map.put(s, :gate, d)}
      end)
      |> Graph.add_node(:done, fn s -> {:ok, Map.put(s, :done, true)} end)
      |> Graph.add_edge(:__start__, :prep)
      |> Graph.add_edge(:prep, :gate)
      |> Graph.add_edge(:gate, :done)
      |> Graph.add_edge(:done, :__end__)
      |> Graph.compile(saver: saver)

    compiled
  end

  describe "async_resume/4" do
    test "returns a handle keyed on the supplied run_id", ctx do
      compiled = approval_graph(ctx.saver)
      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      assert {:ok, %{run_id: ^run_id, pid: pid, ref: ref}} =
               Compiled.async_resume(compiled, run_id, :approved)

      assert is_pid(pid)
      assert is_reference(ref)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000
    end

    test "resume completes and writes the resume-path checkpoints", ctx do
      compiled = approval_graph(ctx.saver)
      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      {:ok, %{ref: ref, pid: pid}} =
        Compiled.async_resume(compiled, run_id, :approved)

      assert_receive {:DOWN, ^ref, :process, ^pid, _reason}, 1_000

      {:ok, checkpoints} = Ets.list(ctx.config, run_id, 10)

      node_ids =
        checkpoints |> Enum.map(& &1.metadata.node_id) |> Enum.sort()

      # ADR-0017: pause checkpoint at :gate plus the resume's success
      # checkpoint at :gate, hence the duplicate.
      assert node_ids == [:__start__, :done, :gate, :gate, :prep]
    end

    test "returns {:error, :no_saver_configured, nil} when no saver wired" do
      {:ok, compiled} =
        Graph.new(:no_saver)
        |> Graph.add_node(:n, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :n)
        |> Graph.add_edge(:n, :__end__)
        |> Graph.compile()

      assert {:error, :no_saver_configured, nil} =
               Compiled.async_resume(compiled, "any", :payload)
    end

    test "returns {:error, :no_checkpoint, nil} when run_id is unknown", ctx do
      compiled = approval_graph(ctx.saver)

      assert {:error, :no_checkpoint, nil} =
               Compiled.async_resume(compiled, "ghost-run-id", :payload)
    end
  end

  describe "resume_events/4" do
    test "emits CloudEvents for the resume invocation and terminates on completion",
         ctx do
      compiled = approval_graph(ctx.saver)
      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      events =
        compiled
        |> Compiled.resume_events(run_id, :approved, timeout_ms: 1_500)
        |> Enum.to_list()

      assert Enum.any?(events, fn
               %CloudEvent{type: "raxol.workflow.run.started"} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               %CloudEvent{type: "raxol.workflow.run.completed"} -> true
               _ -> false
             end)

      assert Enum.any?(events, fn
               %CloudEvent{type: "raxol.workflow.node.completed", data: data} ->
                 data.metadata.node_id == :done

               _ ->
                 false
             end)
    end

    test "every emitted event carries the resumed run_id as subject", ctx do
      compiled = approval_graph(ctx.saver)
      {:interrupted, run_id, _, _} = Compiled.invoke(compiled, %{})

      events =
        compiled
        |> Compiled.resume_events(run_id, :approved, timeout_ms: 1_500)
        |> Enum.to_list()

      assert events != []
      assert Enum.all?(events, fn %CloudEvent{subject: s} -> s == run_id end)
    end

    test "raises ArgumentError when preflight fails (no saver)" do
      {:ok, compiled} =
        Graph.new(:no_saver_stream)
        |> Graph.add_node(:n, fn s -> {:ok, s} end)
        |> Graph.add_edge(:__start__, :n)
        |> Graph.add_edge(:n, :__end__)
        |> Graph.compile()

      assert_raise ArgumentError, ~r/no_saver_configured/, fn ->
        compiled
        |> Compiled.resume_events("any", :payload)
        |> Enum.to_list()
      end
    end

    test "raises ArgumentError when run_id has no checkpoint", ctx do
      compiled = approval_graph(ctx.saver)

      assert_raise ArgumentError, ~r/no_checkpoint/, fn ->
        compiled
        |> Compiled.resume_events("ghost", :payload)
        |> Enum.to_list()
      end
    end
  end
end
