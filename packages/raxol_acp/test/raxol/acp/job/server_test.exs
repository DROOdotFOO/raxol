defmodule Raxol.ACP.Job.ServerTest do
  use ExUnit.Case, async: false

  import Raxol.ACP.TestSupport.WorkflowSetup

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job
  alias Raxol.ACP.Job.Store

  @seller "0x" <> String.duplicate("ab", 20)
  @sig <<0xDE, 0xAD>>

  setup :with_isolated_workflow_saver

  setup do
    # Terminate any leftover Job.Server children from prior tests so the
    # synthetic "job-1" id we get from InMemory's counter doesn't collide
    # with a still-running registration.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    InMemory.reset()
    Store.clear()
    :ok
  end

  defp start_job(opts \\ []) do
    {:ok, job_id} = ContractClient.create_job(@seller, @seller, 9_999_999_999)
    opts = Keyword.put(opts, :job_id, job_id)
    {:ok, pid} = Job.Supervisor.start_job(opts)
    {pid, job_id}
  end

  # The Registry processes :DOWN messages in its own GenServer mailbox,
  # asynchronously to our receipt of the same message. Poll briefly for
  # the unregistration to land.
  defp wait_unregistered(job_id, timeout_ms \\ 500) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_unregistered(job_id, deadline)
  end

  defp do_wait_unregistered(job_id, deadline) do
    case Job.Registry.whereis(job_id) do
      :undefined ->
        :ok

      _pid ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_unregistered(job_id, deadline)
        else
          flunk("Job.Registry still has #{job_id} after #{deadline}ms")
        end
    end
  end

  describe "start_link/1 + registration" do
    test "registers under Job.Registry by job_id" do
      {pid, job_id} = start_job()

      assert Job.Registry.whereis(job_id) == pid
      assert Job.Server.current_state(job_id) == :request
      assert Job.Server.memos(job_id) == []
    end

    test "advances to :negotiation after :accept_request" do
      {_pid, job_id} = start_job()

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{}, @sig)

      assert Job.Server.current_state(job_id) == :negotiation
    end
  end

  describe "expiry timer" do
    test "auto-fires :expire once the deadline has passed" do
      test_pid = self()
      handler_id = "job-expired-#{System.unique_integer([:positive])}"

      :telemetry.attach_many(
        handler_id,
        [[:raxol, :acp, :job, :expired], [:raxol, :acp, :job, :transition]],
        fn event, _m, meta, _ -> send(test_pid, {event, meta}) end,
        nil
      )

      try do
        now = System.system_time(:second)
        {_pid, job_id} = start_job(expired_at: now - 1)

        assert_receive {[:raxol, :acp, :job, :expired], %{from: :request}}, 1_000

        assert_receive {[:raxol, :acp, :job, :transition], %{to: :expired}}, 1_000

        # Reaching a terminal state stops the process (transient restart won't
        # resurrect it), so the registration is released.
        wait_unregistered(job_id)
      after
        :telemetry.detach(handler_id)
      end
    end

    test "does not fire while the deadline is still in the future" do
      now = System.system_time(:second)
      {_pid, job_id} = start_job(expired_at: now + 3600)

      Process.sleep(50)
      assert Job.Server.current_state(job_id) == :request
    end

    test "no timer is armed without :expired_at (unchanged behaviour)" do
      {_pid, job_id} = start_job()

      Process.sleep(50)
      assert Job.Server.current_state(job_id) == :request
    end
  end

  describe "reclaim/1" do
    test "withdraws the escrowed budget through the contract client" do
      {_pid, job_id} = start_job()
      {:ok, _tx} = ContractClient.set_budget(job_id, Decimal.new("1.00"))

      assert {:ok, "tx-" <> _} = Job.Server.reclaim(job_id)
      assert InMemory.get_job(job_id).refunded
    end
  end

  describe "transition/4 forward path" do
    test "valid transition appends a memo and advances state" do
      {_pid, job_id} = start_job()

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{ack: true}, @sig)

      assert Job.Server.current_state(job_id) == :negotiation

      [memo] = Job.Server.memos(job_id)
      assert memo.next_phase == :negotiation
      assert memo.memo_type == :message
      assert memo.payload == %{ack: true}
      assert Jason.decode!(memo.content) == %{"ack" => true}
      assert memo.signature == @sig
      assert memo.tx_hash == "tx-1"
    end

    test "invalid transition returns error and leaves state intact" do
      {_pid, job_id} = start_job()

      assert {:error, {:invalid_transition, :request, :deliver}} =
               Job.Server.transition(job_id, :deliver, %{}, @sig)

      assert Job.Server.current_state(job_id) == :request
      assert Job.Server.memos(job_id) == []
    end
  end

  describe "full happy-path lifecycle" do
    test "request -> negotiation -> transaction -> evaluation -> completed; server terminates" do
      {pid, job_id} = start_job()
      ref = Process.monitor(pid)

      events = [
        {:accept_request, %{step: 1}, :negotiation},
        {:accept_payment, %{step: 2}, :transaction},
        {:deliver, %{step: 3, payload: "result"}, :evaluation}
      ]

      for {event, payload, expected} <- events do
        assert {:ok, ^expected} = Job.Server.transition(job_id, event, payload, @sig)
      end

      # Final transition into terminal :completed -- server stops normally
      assert {:ok, :completed} =
               Job.Server.transition(job_id, :approve, %{evaluator: "buyer"}, @sig)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
      wait_unregistered(job_id)

      # The InMemory contract client recorded all four memos against the job
      memos = InMemory.list_memos(job_id)

      assert Enum.map(memos, & &1.next_phase) == [
               :negotiation,
               :transaction,
               :evaluation,
               :completed
             ]

      assert Enum.map(memos, & &1.tx_hash) == ["tx-1", "tx-2", "tx-3", "tx-4"]
    end

    test ":expire from any non-terminal state stops the server" do
      {pid, job_id} = start_job()
      ref = Process.monitor(pid)

      assert {:ok, :expired} = Job.Server.transition(job_id, :expire, %{reason: "sla"}, @sig)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 500
    end
  end

  describe "telemetry" do
    test "emits [:raxol, :acp, :job, :transition] with from/to/memo_type/next_phase metadata" do
      {_pid, job_id} = start_job()

      handler_id = "job-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:raxol, :acp, :job, :transition],
        fn _event, _measurements, metadata, _ -> send(test_pid, {:telemetry, metadata}) end,
        nil
      )

      try do
        assert {:ok, :negotiation} =
                 Job.Server.transition(job_id, :accept_request, %{}, @sig)

        assert_receive {:telemetry, %{from: :request, to: :negotiation} = meta}, 500
        assert meta.job_id == job_id
        assert meta.memo_type == :message
        assert meta.next_phase == :negotiation
        assert meta.tx_hash == "tx-1"
      after
        :telemetry.detach(handler_id)
      end
    end
  end

  describe "Job.Supervisor.terminate_job/1" do
    test "stops a running job and removes it from the registry" do
      {pid, job_id} = start_job()
      ref = Process.monitor(pid)

      assert :ok = Job.Supervisor.terminate_job(job_id)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 500
      wait_unregistered(job_id)
    end

    test "returns :not_found for unknown job_id" do
      assert {:error, :not_found} = Job.Supervisor.terminate_job("nope-no-such-job")
    end
  end
end
