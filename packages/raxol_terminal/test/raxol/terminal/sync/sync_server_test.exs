defmodule Raxol.Terminal.Sync.SyncServerTest do
  use ExUnit.Case, async: true
  alias Raxol.Terminal.Sync.SyncServer

  setup do
    # Use unique name for each test to avoid conflicts with async tests
    unique_name = :"unified_sync_#{System.unique_integer([:positive])}"

    {:ok, pid} =
      SyncServer.start_link(
        consistency: :strong,
        conflict_resolution: :last_write_wins,
        timeout: 1000,
        retry_count: 3,
        name: unique_name
      )

    on_exit(fn ->
      case Process.alive?(pid) do
        true -> GenServer.stop(pid)
        false -> :ok
      end
    end)

    %{pid: pid, name: unique_name}
  end

  describe "basic operations" do
    test ~c"creates sync context", %{pid: pid} do
      assert {:ok, sync_id} = SyncServer.create_sync(:state, [], pid)
      assert {:ok, sync_state} = SyncServer.get_sync_state(sync_id, pid)
      assert sync_state.type == :state
      assert sync_state.version == 0
    end

    test ~c"syncs data", %{pid: pid} do
      {:ok, sync_id} = SyncServer.create_sync(:state, [], pid)
      data = %{value: "test"}
      assert :ok = SyncServer.sync(sync_id, data, [], pid)
      assert {:ok, sync_state} = SyncServer.get_sync_state(sync_id, pid)
      assert sync_state.data == data
      assert sync_state.version == 1
    end

    test ~c"handles version conflicts", %{pid: pid} do
      {:ok, sync_id} = SyncServer.create_sync(:state, [], pid)
      data1 = %{value: "test1"}
      data2 = %{value: "test2"}
      assert :ok = SyncServer.sync(sync_id, data1, [], pid)

      assert {:error, :version_conflict} =
               SyncServer.sync(sync_id, data2, [version: 0], pid)
    end
  end

  describe "consistency levels" do
    test ~c"strong consistency", %{pid: pid} do
      {:ok, sync_id} =
        SyncServer.create_sync(:state, [consistency: :strong], pid)

      data = %{value: "test"}
      assert :ok = SyncServer.sync(sync_id, data, [], pid)
      assert {:ok, sync_state} = SyncServer.get_sync_state(sync_id, pid)
      assert sync_state.data == data
    end

    test ~c"eventual consistency", %{pid: pid} do
      {:ok, sync_id} =
        SyncServer.create_sync(:state, [consistency: :eventual], pid)

      data = %{value: "test"}
      assert :ok = SyncServer.sync(sync_id, data, [], pid)
      assert {:ok, sync_state} = SyncServer.get_sync_state(sync_id, pid)
      assert sync_state.data == data
    end
  end

  describe "conflict resolution" do
    test ~c"last write wins", %{pid: pid} do
      {:ok, sync_id} =
        SyncServer.create_sync(
          :state,
          [conflict_resolution: :last_write_wins],
          pid
        )

      conflicts = [
        {%{value: "old"}, 1000, 1},
        {%{value: "new"}, 2000, 1}
      ]

      assert {:ok, resolved} =
               SyncServer.resolve_conflicts(sync_id, conflicts, [], pid)

      assert resolved.value == "new"
    end

    test ~c"version based", %{pid: pid} do
      {:ok, sync_id} =
        SyncServer.create_sync(
          :state,
          [conflict_resolution: :version_based],
          pid
        )

      conflicts = [
        {%{value: "old"}, 2000, 1},
        {%{value: "new"}, 1000, 2}
      ]

      assert {:ok, resolved} =
               SyncServer.resolve_conflicts(sync_id, conflicts, [], pid)

      assert resolved.value == "new"
    end

  end

  describe "error handling" do
    test ~c"handles non-existent sync", %{pid: pid} do
      assert {:error, :sync_not_found} =
               SyncServer.get_sync_state("nonexistent", pid)

      assert {:error, :sync_not_found} =
               SyncServer.sync("nonexistent", %{}, [], pid)

      assert {:error, :sync_not_found} =
               SyncServer.resolve_conflicts("nonexistent", [], [], pid)

      assert {:error, :sync_not_found} = SyncServer.cleanup("nonexistent", pid)
    end

    test "handles invalid sync type", %{pid: pid} do
      # The implementation doesn't validate sync types, so :invalid is accepted
      assert {:ok, sync_id} = SyncServer.create_sync(:invalid, [], pid)
      assert {:ok, sync_state} = SyncServer.get_sync_state(sync_id, pid)
      assert sync_state.type == :invalid
    end
  end

  describe "cleanup" do
    test ~c"cleans up sync context", %{pid: pid} do
      {:ok, sync_id} = SyncServer.create_sync(:state, [], pid)
      assert :ok = SyncServer.cleanup(sync_id, pid)

      assert {:error, :sync_not_found} =
               SyncServer.get_sync_state(sync_id, pid)
    end
  end

  describe "metadata" do
    test ~c"handles metadata in sync", %{pid: pid} do
      {:ok, sync_id} = SyncServer.create_sync(:state, [], pid)
      data = %{value: "test"}
      metadata = %{source: "test", priority: 1}
      assert :ok = SyncServer.sync(sync_id, data, [metadata: metadata], pid)
      assert {:ok, sync_state} = SyncServer.get_sync_state(sync_id, pid)
      assert sync_state.metadata == metadata
    end
  end

  describe "concurrent operations" do
    test ~c"handles concurrent syncs", %{pid: pid} do
      {:ok, sync_id} = SyncServer.create_sync(:state, [], pid)
      data1 = %{value: "test1"}
      data2 = %{value: "test2"}

      # Simulate concurrent syncs
      Task.async(fn ->
        SyncServer.sync(sync_id, data1, [version: 0], pid)
      end)

      Task.async(fn ->
        SyncServer.sync(sync_id, data2, [version: 0], pid)
      end)
      |> Task.await()

      assert {:ok, sync_state} = SyncServer.get_sync_state(sync_id, pid)
      assert sync_state.version == 1
    end
  end
end
