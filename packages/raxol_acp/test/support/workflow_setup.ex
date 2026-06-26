defmodule Raxol.ACP.TestSupport.WorkflowSetup do
  @moduledoc """
  ExUnit setup helpers that isolate the workflow Saver per test.

  Every Job.Server test that boots a `Raxol.ACP.Job.Server` under the
  workflow path (now the default) must use a
  fresh ETS table for the workflow Saver. Otherwise the shared default
  table (`:raxol_acp_job_workflow`) accumulates checkpoints across tests
  and stale state ghost-hydrates into fresh Job.Servers (the `InMemory`
  contract client resets its counter, so successive tests reuse the
  same `job-1`, `job-2`, ... ids).

  Usage:

      use ExUnit.Case
      import Raxol.ACP.TestSupport.WorkflowSetup

      setup :with_isolated_workflow_saver
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @spec with_isolated_workflow_saver(map()) :: {:ok, keyword()}
  def with_isolated_workflow_saver(_ctx) do
    table = :"acp_test_wf_#{:erlang.unique_integer([:positive])}"
    saver = {Raxol.Workflow.Checkpoint.Saver.Ets, %{table: table}}

    # Create the ETS table from the test process so it outlives any
    # Job.Server we may kill in this test (the restart-hydration test
    # relies on this).
    Raxol.Workflow.Checkpoint.Saver.Ets.ensure_table(%{table: table})

    Application.put_env(:raxol_acp, :job_workflow_saver, saver)

    on_exit(fn ->
      Application.delete_env(:raxol_acp, :job_workflow_saver)

      case :ets.whereis(table) do
        :undefined -> :ok
        _ref -> :ets.delete(table)
      end
    end)

    {:ok, workflow_saver_table: table}
  end
end
