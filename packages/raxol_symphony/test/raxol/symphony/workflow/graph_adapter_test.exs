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
    test "builds a compiled graph with the five canonical nodes", _ctx do
      assert {:ok, compiled} = GraphAdapter.from_workflow([])

      node_ids = Map.keys(compiled.nodes) |> Enum.sort()

      assert node_ids == [
               :candidate_selection,
               :completion,
               :evidence_collection,
               :runner_dispatch,
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

      # One per successful node = 5
      assert length(checkpoints) == 5

      node_ids = checkpoints |> Enum.map(& &1.metadata.node_id) |> Enum.sort()

      assert node_ids == [
               :candidate_selection,
               :completion,
               :evidence_collection,
               :runner_dispatch,
               :tracker_poll
             ]
    end
  end
end
