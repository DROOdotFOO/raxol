defmodule Raxol.Core.Runtime.Lifecycle.ShutdownTest do
  use ExUnit.Case, async: true

  alias Raxol.Core.Runtime.Lifecycle.Shutdown

  describe "stop_process/2" do
    test "no-ops on nil pid" do
      assert :ok = Shutdown.stop_process(nil, "test")
    end

    test "stops a live GenServer process" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Agent.start_link(fn -> :running end)
      assert Process.alive?(pid)

      Shutdown.stop_process(pid, "test_agent")

      refute Process.alive?(pid)
    end

    test "handles already-dead process gracefully" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Agent.start_link(fn -> :running end)
      Agent.stop(pid)
      refute Process.alive?(pid)

      # Should not raise
      result = Shutdown.stop_process(pid, "dead_agent")
      # Returns nil (from the if branch not executing) or :ok from the catch
      assert result in [nil, :ok]
    end
  end

  describe "cleanup_plugin_manager/2" do
    test "no-ops on nil" do
      assert :ok = Shutdown.cleanup_plugin_manager(nil, %{})
    end

    test "no-ops on false" do
      assert :ok = Shutdown.cleanup_plugin_manager(false, %{})
    end

    test "stops plugin manager when true and process alive" do
      Process.flag(:trap_exit, true)
      {:ok, pid} = Agent.start_link(fn -> :pm_state end)
      state = %{plugin_manager: pid}

      Shutdown.cleanup_plugin_manager(true, state)

      refute Process.alive?(pid)
    end
  end

  describe "cleanup_registry_table/2" do
    test "no-ops on nil" do
      assert :ok = Shutdown.cleanup_registry_table(nil, %{})
    end

    test "no-ops on false" do
      assert :ok = Shutdown.cleanup_registry_table(false, %{})
    end

    test "deletes existing ETS table when true" do
      table_name = :shutdown_test_table
      :ets.new(table_name, [:set, :named_table, :public])
      state = %{command_registry_table: table_name}

      Shutdown.cleanup_registry_table(true, state)

      assert :ets.info(table_name) == :undefined
    end

    test "handles non-existent table gracefully" do
      state = %{command_registry_table: :nonexistent_table_xyz}

      # Should not raise
      Shutdown.cleanup_registry_table(true, state)
    end
  end
end
