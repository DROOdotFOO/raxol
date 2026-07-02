defmodule Raxol.ACP.Job.EvaluatorRejectTest do
  @moduledoc """
  The evaluator (or buyer) can reject a delivered job during `:evaluation`, so a
  rejected deliverable settles to `:rejected` immediately instead of stranding
  the escrow until the SLA timer fires. A graded terminal outcome (completed or
  rejected) emits a dedicated telemetry event, so a rejection is distinguishable
  from a process crash.
  """

  use ExUnit.Case, async: false

  import Raxol.ACP.TestSupport.WorkflowSetup

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job
  alias Raxol.ACP.Job.Store

  @seller "0x" <> String.duplicate("ab", 20)
  @evaluator "0x" <> String.duplicate("ee", 20)
  @sig <<0xDE, 0xAD>>

  setup :with_isolated_workflow_saver

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    InMemory.reset()
    Store.clear()
    :ok
  end

  defp start_job(opts) do
    {:ok, job_id} = ContractClient.create_job(@seller, @evaluator, 9_999_999_999)
    opts = Keyword.put(opts, :job_id, job_id)
    {:ok, _pid} = Job.Supervisor.start_job(opts)
    job_id
  end

  defp drive_to_evaluation(job_id) do
    assert {:ok, :negotiation} = Job.Server.transition(job_id, :accept_request, %{}, @sig)
    assert {:ok, :transaction} = Job.Server.transition(job_id, :accept_payment, %{}, @sig)
    assert {:ok, :evaluation} = Job.Server.transition(job_id, :deliver, %{}, @sig)
    :ok
  end

  defp attach_outcome(event) do
    ref = make_ref()
    test = self()
    handler = "outcome-#{inspect(ref)}"

    :telemetry.attach(
      handler,
      [:raxol, :acp, :job, event],
      fn _e, _m, meta, _ -> send(test, {:outcome, event, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
  end

  describe "reject from :evaluation" do
    test "settles the job to :rejected" do
      job_id = start_job(evaluator: @evaluator)
      drive_to_evaluation(job_id)

      assert {:ok, :rejected} =
               Job.Server.reject(job_id, %{reason: "output did not meet spec"}, @sig)
    end

    test "emits a :rejected outcome event carrying the reason and evaluator" do
      attach_outcome(:rejected)
      job_id = start_job(evaluator: @evaluator)
      drive_to_evaluation(job_id)

      assert {:ok, :rejected} = Job.Server.reject(job_id, %{reason: "bad output"}, @sig)

      assert_receive {:outcome, :rejected, meta}
      assert meta.from == :evaluation
      assert meta.evaluator == @evaluator
      assert meta.reason =~ "bad output"
    end

    test "is rejected before delivery (invalid from :negotiation)" do
      job_id = start_job(evaluator: @evaluator)
      assert {:ok, :negotiation} = Job.Server.transition(job_id, :accept_request, %{}, @sig)

      assert {:error, {:invalid_transition, :negotiation, :reject}} =
               Job.Server.reject(job_id, %{reason: "too early"}, @sig)
    end
  end

  describe "approve from :evaluation" do
    test "settles the job to :completed and emits a :completed outcome event" do
      attach_outcome(:completed)
      job_id = start_job(evaluator: @evaluator)
      drive_to_evaluation(job_id)

      assert {:ok, :completed} = Job.Server.approve(job_id, %{}, @sig)

      assert_receive {:outcome, :completed, meta}
      assert meta.from == :evaluation
      assert meta.evaluator == @evaluator
    end
  end
end
