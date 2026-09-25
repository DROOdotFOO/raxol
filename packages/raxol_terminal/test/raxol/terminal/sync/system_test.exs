defmodule Raxol.Terminal.Sync.SystemTest do
  use ExUnit.Case, async: false
  alias Raxol.Terminal.Sync.System

  # Test-specific wrapper functions that use the process name
  defp sync_system(system_name, sync_id, key, value, opts \\ []) do
    GenServer.call(system_name, {:sync, sync_id, key, value, opts})
  end

  defp get_system(system_name, sync_id, key) do
    GenServer.call(system_name, {:get, sync_id, key})
  end

  defp get_all_system(system_name, sync_id) do
    GenServer.call(system_name, {:get_all, sync_id})
  end

  defp delete_system(system_name, sync_id, key) do
    GenServer.call(system_name, {:delete, sync_id, key})
  end

  defp clear_system(system_name, sync_id) do
    GenServer.call(system_name, {:clear, sync_id})
  end

  defp stats_system(system_name, sync_id) do
    GenServer.call(system_name, {:stats, sync_id})
  end

  setup do
    # Start the sync system with test configuration
    # Use unique name and store it for the test
    name = Raxol.Test.ProcessNaming.generate_name(System)

    {:ok, pid} =
      System.start_link(
        name: name,
        consistency_levels: %{
          split: :strong,
          window: :strong,
          tab: :eventual
        }
      )

    %{system_pid: pid, system_name: name}
  end

  describe "basic operations" do
    test ~c"sync and get", %{system_name: system_name} do
      # Sync a value
      assert :ok ==
               sync_system(system_name, "test_sync", "test_key", "test_value")

      # Get the value
      assert {:ok, "test_value"} ==
               get_system(system_name, "test_sync", "test_key")
    end

    test ~c"get non-existent sync", %{system_name: system_name} do
      assert {:error, :not_found} ==
               get_system(system_name, "nonexistent", "test_key")
    end

    test ~c"get non-existent key", %{system_name: system_name} do
      sync_system(system_name, "test_sync", "test_key", "test_value")

      assert {:error, :not_found} ==
               get_system(system_name, "test_sync", "nonexistent")
    end

    test ~c"delete", %{system_name: system_name} do
      # Sync a value
      sync_system(system_name, "test_sync", "test_key", "test_value")

      assert {:ok, "test_value"} ==
               get_system(system_name, "test_sync", "test_key")

      # Delete the value
      assert :ok == delete_system(system_name, "test_sync", "test_key")

      assert {:error, :not_found} ==
               get_system(system_name, "test_sync", "test_key")
    end

    test ~c"clear", %{system_name: system_name} do
      # Sync multiple values
      sync_system(system_name, "test_sync", "key1", "value1")
      sync_system(system_name, "test_sync", "key2", "value2")

      # Clear all values
      assert :ok == clear_system(system_name, "test_sync")

      assert {:error, :not_found} ==
               get_system(system_name, "test_sync", "key1")

      assert {:error, :not_found} ==
               get_system(system_name, "test_sync", "key2")
    end
  end

  describe "consistency levels" do
    test ~c"strong consistency", %{system_name: system_name} do
      # First sync with strong consistency
      sync_system(system_name, "split", "test_key", "value1",
        consistency: :strong,
        version: 1
      )

      # Second sync with lower version
      sync_system(system_name, "split", "test_key", "value2",
        consistency: :strong,
        version: 0
      )

      # Should keep the first value due to strong consistency
      assert {:ok, "value1"} == get_system(system_name, "split", "test_key")
    end

    test ~c"eventual consistency", %{system_name: system_name} do
      # First sync with eventual consistency
      sync_system(system_name, "tab", "test_key", "value1",
        consistency: :eventual,
        version: 1
      )

      # Second sync with higher version
      sync_system(system_name, "tab", "test_key", "value2",
        consistency: :eventual,
        version: 2
      )

      # Should use the second value due to higher version
      assert {:ok, "value2"} == get_system(system_name, "tab", "test_key")
    end

    test ~c"conflict resolution", %{system_name: system_name} do
      # First sync with eventual consistency
      sync_system(system_name, "tab", "test_key", "value1",
        consistency: :eventual,
        version: 1
      )

      # Second sync with same version
      assert {:error, :conflict} ==
               sync_system(system_name, "tab", "test_key", "value2",
                 consistency: :eventual,
                 version: 1
               )
    end
  end

  describe "metadata handling" do
    test ~c"preserves metadata", %{system_name: system_name} do
      # Sync with metadata
      sync_system(system_name, "test_sync", "test_key", "test_value", source: "test_source")

      # Get all data
      {:ok, sync_data} = get_all_system(system_name, "test_sync")
      entry = Map.get(sync_data, "test_key")

      assert entry.value == "test_value"
      assert entry.metadata.source == "test_source"
      assert entry.metadata.consistency in [:strong, :eventual, :causal]
      assert is_integer(entry.metadata.version)
      assert is_integer(entry.metadata.timestamp)
    end
  end

  describe "statistics" do
    test ~c"tracks sync statistics", %{system_name: system_name} do
      # Clear any existing sync data to ensure clean state
      clear_system(system_name, "test_sync")

      # Perform some syncs
      sync_system(system_name, "test_sync", "key1", "value1",
        consistency: :strong,
        version: 1
      )

      sync_system(system_name, "test_sync", "key2", "value2",
        consistency: :eventual,
        version: 2
      )

      sync_system(system_name, "test_sync", "key3", "value3",
        consistency: :causal,
        version: 3
      )

      # Get stats
      {:ok, stats} = stats_system(system_name, "test_sync")
      assert stats.sync_count == 3
      assert stats.conflict_count == 0
      assert is_integer(stats.last_sync)
      assert stats.consistency_levels.strong == 1
      assert stats.consistency_levels.eventual == 1
      assert stats.consistency_levels.causal == 1
    end

    test ~c"tracks conflicts", %{system_name: system_name} do
      # First sync
      sync_system(system_name, "test_sync", "test_key", "value1",
        consistency: :eventual,
        version: 1
      )

      # Second sync with same version (should cause conflict)
      sync_system(system_name, "test_sync", "test_key", "value2",
        consistency: :eventual,
        version: 1
      )

      # Get stats
      {:ok, stats} = stats_system(system_name, "test_sync")
      assert stats.conflict_count == 1
    end
  end

  describe "multiple syncs" do
    test ~c"handles multiple sync types", %{system_name: system_name} do
      # Sync to different types
      sync_system(system_name, "split", "key1", "split_value")
      sync_system(system_name, "window", "key1", "window_value")
      sync_system(system_name, "tab", "key1", "tab_value")

      # Verify each type has its own data
      assert {:ok, "split_value"} == get_system(system_name, "split", "key1")
      assert {:ok, "window_value"} == get_system(system_name, "window", "key1")
      assert {:ok, "tab_value"} == get_system(system_name, "tab", "key1")
    end

    test ~c"get_all returns all data for sync", %{system_name: system_name} do
      # Sync multiple values
      sync_system(system_name, "test_sync", "key1", "value1")
      sync_system(system_name, "test_sync", "key2", "value2")
      sync_system(system_name, "test_sync", "key3", "value3")

      # Get all data
      {:ok, sync_data} = get_all_system(system_name, "test_sync")
      assert map_size(sync_data) == 3
      assert Map.get(sync_data, "key1").value == "value1"
      assert Map.get(sync_data, "key2").value == "value2"
      assert Map.get(sync_data, "key3").value == "value3"
    end
  end

  # `Raxol.Application` starts it as `{Raxol.Terminal.Sync.System, []}`.
  describe "server naming" do
    test "a server started without a name serves the API" do
      start_supervised!({System, []})

      assert :ok == System.sync("naming", "key", "value")
      assert {:ok, "value"} == System.get("naming", "key")
    end
  end
end
