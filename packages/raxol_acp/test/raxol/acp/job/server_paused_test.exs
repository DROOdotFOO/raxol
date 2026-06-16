defmodule Raxol.ACP.Job.ServerPausedTest do
  use ExUnit.Case, async: false

  import Raxol.ACP.TestSupport.WorkflowSetup

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job

  @seller "0x" <> String.duplicate("ab", 20)
  @sig "0x" <> String.duplicate("ff", 65)

  setup :with_isolated_workflow_saver

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    InMemory.reset()
    Job.Store.clear()
    :ok
  end

  defp start_job do
    {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)
    {:ok, _pid} = Job.Supervisor.start_job(job_id: job_id, persist?: true)
    job_id
  end

  describe "Job.Server.list_paused/0,1 (ADR-0017)" do
    test "lists each in-flight job's current waiting phase with the canonical reason" do
      a = start_job()
      b = start_job()
      c = start_job()

      Job.Server.transition(a, :accept_request, %{}, @sig)
      Job.Server.transition(b, :accept_request, %{}, @sig)
      Job.Server.transition(b, :accept_payment, %{}, @sig)

      rows = Job.Server.list_paused()

      assert length(rows) == 3

      indexed = Map.new(rows, fn row -> {row.job_id, row} end)

      assert indexed[a].interrupt_reason == :awaiting_buyer_payment
      assert indexed[a].state == :negotiation

      assert indexed[b].interrupt_reason == :awaiting_delivery
      assert indexed[b].state == :transaction

      assert indexed[c].interrupt_reason == :awaiting_request_response
      assert indexed[c].state == :request
    end

    test "a resumed job drops out of the list" do
      a = start_job()
      _b = start_job()

      Job.Server.transition(a, :accept_request, %{}, @sig)
      Job.Server.transition(a, :accept_payment, %{}, @sig)
      # Now `a` waits at :transaction (awaiting_delivery), still paused.

      Job.Server.transition(a, :deliver, %{}, @sig)

      # Now `a` waits at :evaluation (awaiting_evaluator_approval), still paused.

      Job.Server.transition(a, :approve, %{}, @sig)
      # Approve transitions to :completed which is terminal; the
      # workflow run ends, the latest checkpoint has no
      # interrupt_reason, and `a` falls out of list_paused.

      rows = Job.Server.list_paused()
      ids = Enum.map(rows, & &1.job_id)

      refute a in ids
    end

    test ":reason filter narrows the result set" do
      a = start_job()
      b = start_job()

      Job.Server.transition(a, :accept_request, %{}, @sig)

      rows = Job.Server.list_paused(reason: :awaiting_buyer_payment)
      ids = Enum.map(rows, & &1.job_id)

      assert ids == [a]
      refute b in ids
    end

    test ":limit caps the result set" do
      _a = start_job()
      _b = start_job()
      _c = start_job()

      assert Job.Server.list_paused(limit: 2) |> length() == 2
    end

    test "returns an empty list when no jobs are paused" do
      # No jobs started; nothing should be in flight.
      assert [] == Job.Server.list_paused()
    end
  end

  describe "pause_reasons/0 contract surface" do
    test "Workflow.pause_reasons/0 returns the canonical four phase atoms" do
      assert Raxol.ACP.Job.Workflow.pause_reasons() == [
               :awaiting_request_response,
               :awaiting_buyer_payment,
               :awaiting_delivery,
               :awaiting_evaluator_approval
             ]
    end
  end
end
