defmodule Raxol.Core.Runtime.Plugins.ResourceBudgetTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Plugins.ResourceBudget

  setup do
    # Ensure PluginRegistry ETS table exists
    Raxol.Core.Runtime.Plugins.PluginRegistry.init()

    # Start with a long interval so timer doesn't fire during tests
    {:ok, pid} = ResourceBudget.start_link(interval_ms: 60_000)

    on_exit(fn ->
      # Server may be mid-shutdown at teardown; swallow the stop's :exit.
      try do
        if Process.alive?(pid), do: GenServer.stop(pid)
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  describe "check/1" do
    test "returns ok for plugin with no usage" do
      assert {:ok, usage} = ResourceBudget.check(:test_plugin)
      assert usage.memory_mb == 0.0
      assert usage.processes == 0
    end
  end

  describe "set_action/2" do
    test "sets enforcement action" do
      assert :ok = ResourceBudget.set_action(:test_plugin, :kill)
    end

    test "rejects invalid actions" do
      assert_raise FunctionClauseError, fn ->
        ResourceBudget.set_action(:test_plugin, :invalid)
      end
    end
  end

  describe "monitor_all/0" do
    test "returns list of plugin statuses" do
      results = ResourceBudget.monitor_all()
      assert is_list(results)
    end
  end

  describe "throttled?/1" do
    test "returns false by default" do
      refute ResourceBudget.throttled?(:test_plugin)
    end
  end
end
