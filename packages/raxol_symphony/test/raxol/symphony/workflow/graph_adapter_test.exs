defmodule Raxol.Symphony.Workflow.GraphAdapterTest do
  use ExUnit.Case, async: false

  alias Raxol.Symphony.Config
  alias Raxol.Symphony.Issue
  alias Raxol.Symphony.Runners.Noop
  alias Raxol.Symphony.Trackers.Memory
  alias Raxol.Symphony.Workflow.GraphAdapter
  alias Raxol.Workflow.Compiled

  setup do
    start_supervised!({Memory, []})
    start_supervised!(Noop.Director)
    Noop.Director.clear()

    config =
      Config.from_workflow(%{
        config: %{
          tracker: %{
            kind: "memory",
            active_states: ["Todo", "In Progress"],
            terminal_states: ["Done", "Cancelled"]
          },
          polling: %{interval_ms: 60_000},
          agent: %{max_concurrent_agents: 3, max_retry_backoff_ms: 60_000},
          codex: %{stall_timeout_ms: 0},
          runner: %{kind: "noop"}
        },
        prompt_template: ""
      })

    %{config: config}
  end

  defp issue(id, identifier, state) do
    %Issue{id: id, identifier: identifier, title: "T-#{identifier}", state: state}
  end

  describe "from_workflow/1" do
    test "builds a compiled graph with the six canonical nodes", _ctx do
      assert {:ok, compiled} = GraphAdapter.from_workflow([])

      node_ids = Map.keys(compiled.nodes) |> Enum.sort()

      assert node_ids == [
               :candidate_selection,
               :completion,
               :evidence_collection,
               :runner_dispatch,
               :runner_wait,
               :tracker_poll
             ]
    end

    test "compile honors :saver opt", _ctx do
      table = :"adapter_test_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)

      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      assert {:ok, compiled} = GraphAdapter.from_workflow(saver: saver)
      assert compiled.opts.saver == saver
    end
  end

  describe "end-to-end pipeline" do
    test "invokes the graph against the Memory tracker + Noop runner", ctx do
      Memory.put_issue(issue("a", "MT-1", "Todo"))
      Noop.Director.set("MT-1", {:succeed_after, 0})

      {:ok, compiled} = GraphAdapter.from_workflow([])
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      assert {:ok, final, meta} = Compiled.invoke(compiled, state)

      assert meta.nodes_executed == 5

      assert is_list(final.candidates)
      assert %Issue{identifier: "MT-1"} = final.candidate
      assert final.run_result == :ok
      assert final.evidence != nil
      assert %DateTime{} = final.completed_at
    end

    test "graceful handling when tracker returns no issues", ctx do
      # No issue seeded in Memory tracker.
      {:ok, compiled} = GraphAdapter.from_workflow([])
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      assert {:ok, final, meta} = Compiled.invoke(compiled, state)
      assert meta.nodes_executed == 5

      assert final.candidate == nil
      assert final.run_result == {:error, :no_candidate}
      assert final.evidence == nil
      assert %DateTime{} = final.completed_at
    end

    test "runner failure is recorded in run_result, downstream nodes still run", ctx do
      Memory.put_issue(issue("b", "MT-2", "Todo"))
      Noop.Director.set("MT-2", {:fail_after, 0, :simulated})

      {:ok, compiled} = GraphAdapter.from_workflow([])
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, state)

      assert {:error, :simulated} = final.run_result
      assert final.evidence != nil
      assert %DateTime{} = final.completed_at
    end

    test "runner pause surfaces as {:interrupted, ...}; resume completes the run", ctx do
      Memory.put_issue(issue("p1", "MT-P1", "Todo"))

      Noop.Director.set(
        "MT-P1",
        {:pause_then, :awaiting_review, %{phase: 1}, {:succeed_after, 0}}
      )

      table = :"adapter_pause_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      {:ok, compiled} = GraphAdapter.from_workflow(saver: saver)
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      # First invoke: runner pauses, runner_wait interrupts.
      assert {:interrupted, run_id, paused_state, interrupt_value} =
               Compiled.invoke(compiled, state)

      assert interrupt_value == {:awaiting_review, %{phase: 1}}
      assert paused_state.runner_pause == {:awaiting_review, %{phase: 1}}
      assert paused_state.run_result == nil

      # Resume with an :approved value; runner re-runs with the resume context
      # and now hits the {:succeed_after, 0} action queued by Director.
      assert {:ok, final, meta} = Compiled.resume(compiled, run_id, :approved)

      assert final.run_result == :ok
      assert final.runner_pause == nil
      assert final.runner_pending_resume == nil
      assert final.evidence != nil
      assert %DateTime{} = final.completed_at

      # Meta from resume reports only the nodes the resume executed
      # (runner_wait completion + runner_dispatch re-run + evidence + completion).
      assert meta.nodes_executed >= 4
    end

    test "checkpoints written when saver is configured", ctx do
      Memory.put_issue(issue("c", "MT-3", "Todo"))
      Noop.Director.set("MT-3", {:succeed_after, 0})

      table = :"adapter_int_#{:erlang.unique_integer([:positive])}"
      on_exit(fn -> if :ets.whereis(table) != :undefined, do: :ets.delete(table) end)
      saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

      {:ok, compiled} = GraphAdapter.from_workflow(saver: saver)
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      {:ok, _final, meta} = Compiled.invoke(compiled, state)

      {:ok, checkpoints} =
        Raxol.Workflow.Checkpoint.Saver.Ets.list(%{table: table}, meta.run_id, 10)

      # :__start__ initial + one per successful node = 6
      assert length(checkpoints) == 6

      node_ids = checkpoints |> Enum.map(& &1.metadata.node_id) |> Enum.sort()

      assert node_ids == [
               :__start__,
               :candidate_selection,
               :completion,
               :evidence_collection,
               :runner_dispatch,
               :tracker_poll
             ]
    end
  end

  describe "from_workflow_parallel/1" do
    test "builds a parallel graph with one branch per slot", _ctx do
      {:ok, compiled} = GraphAdapter.from_workflow_parallel(max_candidates: 2)
      node_ids = Map.keys(compiled.nodes) |> Enum.sort()

      assert node_ids == [
               :aggregate,
               :completion,
               :fan_out_candidates,
               :slot_dispatch_0,
               :slot_dispatch_1,
               :slot_evidence_0,
               :slot_evidence_1,
               :slot_prepare_0,
               :slot_prepare_1,
               :tracker_poll
             ]
    end

    test "fans out across both candidates and aggregates run_results", ctx do
      Memory.put_issue(issue("a", "PAR-1", "Todo"))
      Memory.put_issue(issue("b", "PAR-2", "Todo"))
      Noop.Director.set("PAR-1", {:succeed_after, 0})
      Noop.Director.set("PAR-2", {:succeed_after, 0})

      {:ok, compiled} = GraphAdapter.from_workflow_parallel(max_candidates: 2)
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, state)

      results_by_id = Map.new(final.run_results)
      assert results_by_id["a"] == :ok
      assert results_by_id["b"] == :ok

      evidences_by_id = Map.new(final.evidences)
      assert evidences_by_id["a"] != nil
      assert evidences_by_id["b"] != nil

      assert %DateTime{} = final.completed_at
    end

    test "empty slot returns nil run_result + evidence and is skipped on aggregate", ctx do
      Memory.put_issue(issue("solo", "PAR-3", "Todo"))
      Noop.Director.set("PAR-3", {:succeed_after, 0})

      {:ok, compiled} = GraphAdapter.from_workflow_parallel(max_candidates: 3)
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, state)

      # Only the one populated slot shows up; the two empty slots are
      # filtered out by the aggregator.
      assert [{"solo", :ok}] = final.run_results
    end

    test "per-slot runner failure surfaces in aggregated run_results", ctx do
      Memory.put_issue(issue("ok", "PAR-4", "Todo"))
      Memory.put_issue(issue("bad", "PAR-5", "Todo"))
      Noop.Director.set("PAR-4", {:succeed_after, 0})
      Noop.Director.set("PAR-5", {:fail_after, 0, :boom})

      {:ok, compiled} = GraphAdapter.from_workflow_parallel(max_candidates: 2)
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, state)

      results_by_id = Map.new(final.run_results)
      assert results_by_id["ok"] == :ok
      assert results_by_id["bad"] == {:error, :boom}
    end

    test "a paused slot surfaces its pause verbatim and skips evidence", ctx do
      Memory.put_issue(issue("p", "PAR-6", "Todo"))
      Noop.Director.set("PAR-6", {:pause, :awaiting_review, %{token: 1}})

      {:ok, compiled} = GraphAdapter.from_workflow_parallel(max_candidates: 1)
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      # The run COMPLETES (no interrupt); the pause rides through aggregate.
      assert {:ok, final, _meta} = Compiled.invoke(compiled, state)

      assert [{"p", {:pause, :awaiting_review, %{token: 1}}}] = final.run_results
      # A half-done branch collects no evidence.
      assert [{"p", nil}] = final.evidences
      assert %DateTime{} = final.completed_at
    end

    test "a paused branch does not stop its siblings from completing", ctx do
      Memory.put_issue(issue("ok", "PAR-7", "Todo"))
      Memory.put_issue(issue("paused", "PAR-8", "Todo"))
      Noop.Director.set("PAR-7", {:succeed_after, 0})
      Noop.Director.set("PAR-8", {:pause, :awaiting_review, %{token: 2}})

      {:ok, compiled} = GraphAdapter.from_workflow_parallel(max_candidates: 2)
      state = GraphAdapter.initial_state(config: ctx.config, runner_module: Noop)

      assert {:ok, final, _meta} = Compiled.invoke(compiled, state)

      results_by_id = Map.new(final.run_results)
      assert results_by_id["ok"] == :ok
      assert results_by_id["paused"] == {:pause, :awaiting_review, %{token: 2}}

      # the sibling that finished still has evidence; the paused one does not
      evidences_by_id = Map.new(final.evidences)
      assert evidences_by_id["ok"] != nil
      assert evidences_by_id["paused"] == nil
    end
  end
end
