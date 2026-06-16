defmodule Raxol.ACP.Job.ServerWorkflowTest do
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

  defp start_workflow_job(opts \\ []) do
    {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)

    {:ok, _pid} =
      Job.Supervisor.start_job(
        Keyword.merge(
          [job_id: job_id, persist?: true],
          opts
        )
      )

    job_id
  end

  describe "Job.Server: workflow-backed transitions" do
    test "happy path: request -> negotiation -> transaction -> evaluation -> completed" do
      job_id = start_workflow_job()

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{step: 1}, @sig)

      assert {:ok, :transaction} =
               Job.Server.transition(job_id, :accept_payment, %{step: 2}, @sig)

      assert {:ok, :evaluation} =
               Job.Server.transition(job_id, :deliver, %{step: 3}, @sig)

      assert {:ok, :completed} =
               Job.Server.transition(job_id, :approve, %{step: 4}, @sig)
    end

    test "memo history record shape" do
      job_id = start_workflow_job()

      Job.Server.transition(job_id, :accept_request, %{step: 1}, @sig)
      Job.Server.transition(job_id, :accept_payment, %{step: 2}, @sig)

      memos = Job.Server.memos(job_id)
      assert length(memos) == 2

      [m1, m2] = memos
      assert m1.next_phase == :negotiation
      assert m1.payload == %{step: 1}
      assert m1.signature == @sig
      assert m1.memo_type == :message

      assert m2.next_phase == :transaction
      assert m2.payload == %{step: 2}
      assert m2.memo_type == :txhash
    end

    test "invalid event for current phase returns {:error, {:invalid_transition, _, _}}" do
      job_id = start_workflow_job()

      assert {:error, {:invalid_transition, :request, :deliver}} =
               Job.Server.transition(job_id, :deliver, %{}, @sig)
    end

    test "Store gets mirrored writes for backward compat" do
      job_id = start_workflow_job()

      Job.Server.transition(job_id, :accept_request, %{step: 1}, @sig)

      assert {:ok, %{state: :negotiation, memos: [memo]}} =
               Job.Store.load(job_id)

      assert memo.next_phase == :negotiation
      assert memo.payload == %{step: 1}
    end

    test "telemetry: [:raxol, :acp, :job, :transition] still fires" do
      test_pid = self()
      handler_id = "acp_wf_tel_#{:erlang.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:raxol, :acp, :job, :transition],
        fn _e, _m, metadata, _ -> send(test_pid, {:transition, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      job_id = start_workflow_job()
      Job.Server.transition(job_id, :accept_request, %{}, @sig)

      assert_receive {:transition,
                      %{
                        job_id: ^job_id,
                        from: :request,
                        to: :negotiation,
                        next_phase: :negotiation
                      }},
                     500
    end

    test "terminal phase stops the server with :normal" do
      job_id = start_workflow_job()
      Job.Server.transition(job_id, :accept_request, %{}, @sig)
      Job.Server.transition(job_id, :accept_payment, %{}, @sig)
      Job.Server.transition(job_id, :deliver, %{}, @sig)

      pid = Job.Registry.whereis(job_id)
      ref = Process.monitor(pid)

      assert {:ok, :completed} =
               Job.Server.transition(job_id, :approve, %{}, @sig)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end

    test "reject from :request lands at :rejected and stops the server" do
      job_id = start_workflow_job()

      pid = Job.Registry.whereis(job_id)
      ref = Process.monitor(pid)

      assert {:ok, :rejected} =
               Job.Server.transition(job_id, :reject, %{reason: "no"}, @sig)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end

  describe "workflow-mode hydration on restart" do
    test "a restarted server hydrates state and memos from the Workflow's Saver" do
      job_id = start_workflow_job()

      Job.Server.transition(job_id, :accept_request, %{step: 1}, @sig)
      Job.Server.transition(job_id, :accept_payment, %{step: 2}, @sig)

      pid = Job.Registry.whereis(job_id)
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

      new_pid = wait_for_new_pid(job_id, pid)
      assert new_pid != pid

      assert Job.Server.current_state(job_id) == :transaction
      memos = Job.Server.memos(job_id)
      assert Enum.map(memos, & &1.next_phase) == [:negotiation, :transaction]

      assert {:ok, :evaluation} =
               Job.Server.transition(job_id, :deliver, %{step: 3}, @sig)
    end
  end

  defp wait_for_new_pid(job_id, old_pid, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(job_id, old_pid, deadline)
  end

  defp do_wait(job_id, old_pid, deadline) do
    case Job.Registry.whereis(job_id) do
      :undefined ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_wait(job_id, old_pid, deadline)
        else
          flunk("Job.Server never restarted")
        end

      ^old_pid ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(20)
          do_wait(job_id, old_pid, deadline)
        else
          flunk("Job.Server still pointing at old pid")
        end

      new_pid ->
        new_pid
    end
  end
end
