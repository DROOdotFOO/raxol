defmodule Raxol.ACP.Job.ServerTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job

  @seller "0x" <> String.duplicate("ab", 20)
  @sig <<0xDE, 0xAD>>

  setup do
    # Terminate any leftover Job.Server children from prior tests so the
    # synthetic "job-1" id we get from InMemory's counter doesn't collide
    # with a still-running registration.
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    InMemory.reset()
    :ok
  end

  defp start_job(opts \\ []) do
    {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.50"), <<>>)
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

    test "respects :initial_state override" do
      {_pid, job_id} = start_job(initial_state: :negotiation)
      assert Job.Server.current_state(job_id) == :negotiation
    end
  end

  describe "transition/4 forward path" do
    test "valid transition appends a memo and advances state" do
      {_pid, job_id} = start_job()

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{ack: true}, @sig)

      assert Job.Server.current_state(job_id) == :negotiation

      [memo] = Job.Server.memos(job_id)
      assert memo.type == :negotiation
      assert memo.payload == %{ack: true}
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
      assert Enum.map(memos, & &1.type) == [:negotiation, :transaction, :evaluation, :completed]
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
    test "emits [:raxol, :acp, :job, :transition] with from/to/memo_type metadata" do
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
        assert meta.memo_type == :negotiation
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
