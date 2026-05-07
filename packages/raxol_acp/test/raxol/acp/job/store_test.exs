defmodule Raxol.ACP.Job.StoreTest do
  use ExUnit.Case, async: false

  alias Raxol.ACP.ContractClient
  alias Raxol.ACP.ContractClient.InMemory
  alias Raxol.ACP.Job
  alias Raxol.ACP.Job.Store

  @seller "0x" <> String.duplicate("ab", 20)
  @sig <<0xDE, 0xAD>>

  setup do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Job.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(Job.Supervisor, pid)
    end

    InMemory.reset()
    Store.clear()
    :ok
  end

  defp memo(type, payload, tx_hash) do
    %{
      type: type,
      payload: payload,
      signature: <<0xAB, 0xCD>>,
      tx_hash: tx_hash,
      transitioned_at: DateTime.utc_now()
    }
  end

  describe "save/3 + load/1" do
    test "persists a snapshot and reads it back" do
      m = memo(:negotiation, %{ack: true}, "tx-1")
      assert :ok = Store.save("job-1", :negotiation, [m])

      assert {:ok, %{state: :negotiation, memos: [^m], updated_at: %DateTime{}}} =
               Store.load("job-1")
    end

    test "load/1 returns :error for unknown job_id" do
      assert :error = Store.load("never-saved")
    end

    test "save/3 overwrites prior records for the same job_id" do
      :ok = Store.save("job-x", :request, [memo(:request, %{}, "tx-old")])
      :ok = Store.save("job-x", :evaluation, [memo(:evaluation, %{}, "tx-new")])

      {:ok, record} = Store.load("job-x")
      assert record.state == :evaluation
      assert [%{tx_hash: "tx-new"}] = record.memos
    end
  end

  describe "append_memo/3" do
    test "adds the first memo when no prior record exists" do
      m = memo(:negotiation, %{first: true}, "tx-1")
      assert :ok = Store.append_memo("job-2", :negotiation, m)

      assert {:ok, %{state: :negotiation, memos: [^m]}} = Store.load("job-2")
    end

    test "appends additional memos in submission order" do
      m1 = memo(:negotiation, %{step: 1}, "tx-1")
      m2 = memo(:transaction, %{step: 2}, "tx-2")
      m3 = memo(:evaluation, %{step: 3}, "tx-3")

      :ok = Store.append_memo("job-3", :negotiation, m1)
      :ok = Store.append_memo("job-3", :transaction, m2)
      :ok = Store.append_memo("job-3", :evaluation, m3)

      {:ok, record} = Store.load("job-3")
      assert record.state == :evaluation
      assert Enum.map(record.memos, & &1.tx_hash) == ["tx-1", "tx-2", "tx-3"]
    end

    test "updates :updated_at on every append" do
      :ok = Store.append_memo("job-4", :negotiation, memo(:negotiation, %{}, "tx-1"))
      {:ok, %{updated_at: t1}} = Store.load("job-4")

      Process.sleep(10)
      :ok = Store.append_memo("job-4", :transaction, memo(:transaction, %{}, "tx-2"))
      {:ok, %{updated_at: t2}} = Store.load("job-4")

      assert DateTime.compare(t2, t1) == :gt
    end
  end

  describe "list_jobs/0 + count/0" do
    test "are zero on a clean store" do
      assert Store.list_jobs() == []
      assert Store.count() == 0
    end

    test "reflect every saved job" do
      :ok = Store.save("a", :request, [])
      :ok = Store.save("b", :request, [])
      :ok = Store.save("c", :request, [])

      assert Store.count() == 3
      assert Enum.sort(Store.list_jobs()) == ["a", "b", "c"]
    end
  end

  describe "delete/1" do
    test "removes a record" do
      :ok = Store.save("doomed", :request, [])
      assert {:ok, _} = Store.load("doomed")

      assert :ok = Store.delete("doomed")
      assert :error = Store.load("doomed")
    end

    test "is idempotent for unknown job_ids" do
      assert :ok = Store.delete("never-existed")
      assert :ok = Store.delete("never-existed")
    end
  end

  describe "concurrent reads" do
    test "load/1 is a direct ETS read, safe from many processes" do
      m = memo(:negotiation, %{}, "tx-1")
      :ok = Store.save("hot", :negotiation, [m])

      results =
        1..50
        |> Task.async_stream(fn _ -> Store.load("hot") end,
          max_concurrency: 25,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, %{state: :negotiation}}, &1))
    end
  end

  describe "DETS persistence (configured via :job_store_path)" do
    # These tests do NOT touch the global supervised Store. They open a
    # fresh DETS file directly + drive Store's init/1 against it, so we
    # can observe encode/replay/teardown without :rest_for_one cascade
    # restarts on every recycle. Hydration semantics are the same as a
    # supervised restart -- it's the same `init/1` path either way.

    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "raxol_acp_store_#{System.unique_integer([:positive])}.dets"
        )

      on_exit(fn -> File.rm(tmp) end)

      %{path: tmp}
    end

    defp open_dets!(path) do
      {:ok, table} =
        :dets.open_file(:raxol_acp_test_dets, type: :set, file: String.to_charlist(path))

      table
    end

    defp insert_dets!(table, job_id, record) do
      :ok = :dets.insert(table, {job_id, record})
    end

    defp close_dets!(table) do
      _ = :dets.sync(table)
      :ok = :dets.close(table)
    end

    test "init/1 hydrates ETS from an existing DETS file", %{path: path} do
      record = %{
        state: :evaluation,
        memos: [memo(:evaluation, %{step: 3}, "tx-3")],
        updated_at: DateTime.utc_now()
      }

      table = open_dets!(path)
      insert_dets!(table, "hydrate-1", record)
      close_dets!(table)

      :ok = with_persistent_store(path)
      on_exit(fn -> recycle_to_ets_only() end)

      assert {:ok, %{state: :evaluation, memos: [m]}} = Store.load("hydrate-1")
      assert m.tx_hash == "tx-3"
    end

    test "save/3 mirrors to DETS so a later open observes the record", %{path: path} do
      :ok = with_persistent_store(path)
      on_exit(fn -> recycle_to_ets_only() end)

      :ok = Store.save("disk-1", :negotiation, [memo(:negotiation, %{step: 1}, "tx-1")])
      :ok = recycle_to_ets_only()

      table = open_dets!(path)
      [{"disk-1", %{state: :negotiation, memos: [m]}}] = :dets.lookup(table, "disk-1")
      close_dets!(table)

      assert m.tx_hash == "tx-1"
    end

    test "delete/1 mirrors to DETS", %{path: path} do
      :ok = with_persistent_store(path)
      on_exit(fn -> recycle_to_ets_only() end)

      :ok = Store.save("disk-2", :request, [])
      :ok = Store.delete("disk-2")
      :ok = recycle_to_ets_only()

      table = open_dets!(path)
      assert [] = :dets.lookup(table, "disk-2")
      close_dets!(table)
    end

    test "clear/0 wipes DETS too", %{path: path} do
      :ok = with_persistent_store(path)
      on_exit(fn -> recycle_to_ets_only() end)

      :ok = Store.save("disk-a", :request, [])
      :ok = Store.save("disk-b", :request, [])
      :ok = Store.clear()
      :ok = recycle_to_ets_only()

      table = open_dets!(path)
      assert :dets.info(table, :size) == 0
      close_dets!(table)
    end
  end

  # Stop the supervised Store and wait for the supervisor to bring it
  # back. Used by the persistence tests to flush DETS before inspecting
  # the file.
  defp stop_store! do
    case Process.whereis(Store) do
      nil ->
        wait_for_named(Store)

      pid ->
        ref = Process.monitor(pid)
        :ok = GenServer.stop(pid, :normal)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> raise "Store did not stop"
        end

        wait_for_named(Store)
    end
  end

  # Configure DETS path + recycle Store so the new init opens a fresh
  # DETS handle.
  defp with_persistent_store(path) do
    Application.put_env(:raxol_acp, :job_store_path, path)
    stop_store!()
  end

  # Drop Store's DETS handle (terminate syncs + closes DETS) and let
  # the supervisor restart it WITHOUT a DETS path. The DETS file
  # becomes unlocked so the test can open it directly. Idempotent.
  defp recycle_to_ets_only do
    Application.delete_env(:raxol_acp, :job_store_path)
    stop_store!()
  end

  defp wait_for_named(name, timeout_ms \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_named(name, deadline)
  end

  defp do_wait_for_named(name, deadline) do
    case Process.whereis(name) do
      nil ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_for_named(name, deadline)
        else
          raise "#{inspect(name)} never came back online"
        end

      _pid ->
        :ok
    end
  end

  describe "Job.Server integration: transient restart" do
    test "every successful transition writes through to the Store" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.50"), <<>>)
      {:ok, _pid} = Job.Supervisor.start_job(job_id: job_id)

      assert :error = Store.load(job_id)

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{step: 1}, @sig)

      assert {:ok, %{state: :negotiation, memos: [memo]}} = Store.load(job_id)
      assert memo.type == :negotiation
      assert memo.payload == %{step: 1}
      assert memo.tx_hash == "tx-1"

      assert {:ok, :transaction} =
               Job.Server.transition(job_id, :accept_payment, %{step: 2}, @sig)

      assert {:ok, %{state: :transaction, memos: [_, m2]}} = Store.load(job_id)
      assert m2.type == :transaction
      assert m2.tx_hash == "tx-2"
    end

    test ":persist? false bypasses the Store" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.50"), <<>>)
      {:ok, _pid} = Job.Supervisor.start_job(job_id: job_id, persist?: false)

      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{}, @sig)

      assert :error = Store.load(job_id)
    end

    test "transient restart hydrates state + memos from the Store" do
      {:ok, job_id} = ContractClient.create_job(@seller, Decimal.new("0.50"), <<>>)
      {:ok, pid} = Job.Supervisor.start_job(job_id: job_id)

      # Drive the job two transitions in.
      assert {:ok, :negotiation} =
               Job.Server.transition(job_id, :accept_request, %{step: 1}, @sig)

      assert {:ok, :transaction} =
               Job.Server.transition(job_id, :accept_payment, %{step: 2}, @sig)

      # Crash the server with a non-normal exit. :transient restart kicks in.
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 500

      new_pid = wait_for_new_pid(job_id, pid)
      assert new_pid != pid

      # The restarted server has hydrated from the Store, not started fresh.
      assert Job.Server.current_state(job_id) == :transaction

      memos = Job.Server.memos(job_id)
      assert Enum.map(memos, & &1.type) == [:negotiation, :transaction]
      assert Enum.map(memos, & &1.payload) == [%{step: 1}, %{step: 2}]

      # The lifecycle continues correctly from the hydrated state.
      assert {:ok, :evaluation} =
               Job.Server.transition(job_id, :deliver, %{step: 3}, @sig)

      assert {:ok, %{state: :evaluation, memos: [_, _, m3]}} = Store.load(job_id)
      assert m3.type == :evaluation
    end
  end

  defp wait_for_new_pid(job_id, old_pid, timeout_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait_for_new_pid(job_id, old_pid, deadline)
  end

  defp do_wait_for_new_pid(job_id, old_pid, deadline) do
    case Job.Registry.whereis(job_id) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(5)
          do_wait_for_new_pid(job_id, old_pid, deadline)
        else
          flunk("Job.Server for #{job_id} did not restart with a new pid in time")
        end
    end
  end
end
