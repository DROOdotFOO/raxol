defmodule Raxol.Core.Runtime.Plugins.ResourceBudgetTest do
  use ExUnit.Case, async: false

  alias Raxol.Core.Runtime.Plugins.{
    PluginLifecycle,
    PluginRegistry,
    PluginSupervisor,
    ResourceBudget
  }

  defmodule BudgetPlugin do
  end

  setup do
    start_supervised!(
      {PluginSupervisor, resource_budget: [interval_ms: 60_000, throttle_interval_ms: 60_000]}
    )

    assert is_pid(Process.whereis(ResourceBudget))
    :ok
  end

  describe "live supervised usage" do
    test "measures task process, memory, and owned ETS tables" do
      plugin_id = unique_plugin_id(:measure)
      register_tiny_budget(plugin_id)
      {task, _ref} = start_budget_task(plugin_id)

      assert {:over_budget, usage, budget} = ResourceBudget.check(plugin_id)
      assert usage.processes == 1
      assert usage.memory_mb > budget.max_memory_mb
      assert usage.ets_tables > budget.max_ets_tables

      stop_budget_task(task)
    end

    test "falls back to defaults for malformed registry metadata" do
      plugin_id = unique_plugin_id(:malformed)
      assert :ok = PluginRegistry.register(plugin_id, BudgetPlugin, %{resource_budget: :infinity})

      assert {:ok, usage} = ResourceBudget.check(plugin_id)
      assert usage.processes == 0
      assert Process.alive?(Process.whereis(ResourceBudget))
    end
  end

  describe "configured enforcement actions" do
    test "warn emits telemetry without blocking or terminating the plugin" do
      plugin_id = unique_plugin_id(:warn)
      register_tiny_budget(plugin_id)
      attach_budget_telemetry(plugin_id)
      :ok = ResourceBudget.set_action(plugin_id, :warn)
      {task, _ref} = start_budget_task(plugin_id)

      assert [{^plugin_id, :over_budget}] = ResourceBudget.enforce_now()
      assert_receive {:budget_exceeded, %{plugin_id: ^plugin_id, action: :warn}}
      refute ResourceBudget.throttled?(plugin_id)
      assert Process.alive?(task)
      assert PluginRegistry.registered?(plugin_id)

      stop_budget_task(task)
    end

    test "throttle blocks new plugin work until usage returns under budget" do
      plugin_id = unique_plugin_id(:throttle)
      register_tiny_budget(plugin_id)
      :ok = ResourceBudget.set_action(plugin_id, :throttle)
      {task, ref} = start_budget_task(plugin_id)

      assert [{^plugin_id, :over_budget}] = ResourceBudget.enforce_now()
      assert ResourceBudget.throttled?(plugin_id)

      assert {:error, :throttled} =
               PluginSupervisor.run_plugin_task(plugin_id, fn -> :should_not_run end)

      send(task, :release)
      assert_receive {:DOWN, ^ref, :process, ^task, :normal}

      assert [{^plugin_id, :ok}] = ResourceBudget.enforce_now()
      refute ResourceBudget.throttled?(plugin_id)
      assert {:ok, :allowed} = PluginSupervisor.run_plugin_task(plugin_id, fn -> :allowed end)
    end

    test "kill terminates supervised work and unregisters the plugin" do
      plugin_id = unique_plugin_id(:kill)
      register_tiny_budget(plugin_id)
      :ok = ResourceBudget.set_action(plugin_id, :kill)
      {task, ref} = start_budget_task(plugin_id)

      assert [{^plugin_id, :over_budget}] = ResourceBudget.enforce_now()
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}
      refute PluginRegistry.registered?(plugin_id)
      refute ResourceBudget.throttled?(plugin_id)
    end

    test "normalizes string IDs for measurement and throttle admission" do
      plugin_id = unique_plugin_id(:string_id)
      plugin_id_string = Atom.to_string(plugin_id)
      register_tiny_budget(plugin_id)
      :ok = ResourceBudget.set_action(plugin_id_string, :throttle)
      {task, _ref} = start_budget_task(plugin_id_string)

      assert [{^plugin_id, :over_budget}] = ResourceBudget.enforce_now()

      assert {:error, :throttled} =
               PluginSupervisor.run_plugin_task(plugin_id_string, fn -> :should_not_run end)

      stop_budget_task(task)
    end

    test "retains the configured action when the monitor restarts" do
      plugin_id = unique_plugin_id(:restart)
      register_tiny_budget(plugin_id)
      :ok = ResourceBudget.set_action(plugin_id, :kill)

      assert :ok = Supervisor.terminate_child(PluginSupervisor, ResourceBudget)
      assert {:ok, _pid} = Supervisor.restart_child(PluginSupervisor, ResourceBudget)

      {task, ref} = start_budget_task(plugin_id)
      assert [{^plugin_id, :over_budget}] = ResourceBudget.enforce_now()
      assert_receive {:DOWN, ^ref, :process, ^task, :killed}
      refute PluginRegistry.registered?(plugin_id)
    end

    test "admission does not wait for the sampling server" do
      plugin_id = unique_plugin_id(:admission)
      register_tiny_budget(plugin_id)
      budget_pid = Process.whereis(ResourceBudget)
      :ok = :sys.suspend(budget_pid)
      on_exit(fn -> if Process.alive?(budget_pid), do: :sys.resume(budget_pid) end)

      assert {:ok, :allowed} = PluginSupervisor.run_plugin_task(plugin_id, fn -> :allowed end)
      :ok = :sys.resume(budget_pid)
    end

    test "kill blocks admission while lifecycle unload is pending" do
      plugin_id = unique_plugin_id(:pending_unload)
      register_tiny_budget(plugin_id)
      :ok = ResourceBudget.set_action(plugin_id, :kill)
      parent = self()

      lifecycle =
        spawn(fn ->
          receive do
            {:"$gen_call", from, {:unload, ^plugin_id}} ->
              send(parent, :unload_started)

              receive do
                :finish_unload -> GenServer.reply(from, :ok)
              end
          end
        end)

      true = Process.register(lifecycle, PluginLifecycle)
      on_exit(fn -> if Process.alive?(lifecycle), do: Process.exit(lifecycle, :kill) end)
      {_task, _ref} = start_budget_task(plugin_id)

      assert [{^plugin_id, :over_budget}] = ResourceBudget.enforce_now()
      assert_receive :unload_started
      assert ResourceBudget.throttled?(plugin_id)

      assert {:error, :throttled} =
               PluginSupervisor.run_plugin_task(plugin_id, fn -> :should_not_run end)

      send(lifecycle, :finish_unload)
    end
  end

  describe "set_action/2" do
    test "rejects invalid actions" do
      assert_raise FunctionClauseError, fn ->
        apply(ResourceBudget, :set_action, [:test_plugin, :invalid])
      end
    end
  end

  describe "monitor_all/0" do
    test "returns registered plugin statuses" do
      plugin_id = unique_plugin_id(:monitor)
      register_tiny_budget(plugin_id)

      assert {plugin_id, :ok} in ResourceBudget.monitor_all()
    end
  end

  def handle_budget_event(_event, _measurements, metadata, test_pid) do
    send(test_pid, {:budget_exceeded, metadata})
  end

  defp register_tiny_budget(plugin_id) do
    budget = %{
      max_memory_mb: 0,
      max_cpu_percent: 100,
      max_ets_tables: 0,
      max_processes: 0
    }

    assert :ok =
             PluginRegistry.register(plugin_id, BudgetPlugin, %{
               resource_budget: budget
             })

    budget
  end

  defp start_budget_task(plugin_id) do
    parent = self()

    assert :ok =
             PluginSupervisor.async_plugin_task(plugin_id, fn ->
               table = :ets.new(:budget_plugin_table, [:set])
               payload = :binary.copy(<<0>>, 65_536)
               send(parent, {:budget_task_ready, self()})

               receive do
                 :release -> {table, byte_size(payload)}
               end
             end)

    assert_receive {:budget_task_ready, task}
    ref = Process.monitor(task)
    {task, ref}
  end

  defp stop_budget_task(task) do
    ref = Process.monitor(task)
    send(task, :release)
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
  end

  defp attach_budget_telemetry(plugin_id) do
    handler_id = "resource_budget_#{plugin_id}"

    :telemetry.attach(
      handler_id,
      [:raxol, :plugins, :resource_budget, :exceeded],
      &__MODULE__.handle_budget_event/4,
      self()
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  defp unique_plugin_id(prefix) do
    :"#{prefix}_#{System.unique_integer([:positive])}"
  end
end
