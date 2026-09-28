defmodule Raxol.Core.Runtime.Plugins.ResourceBudget do
  @moduledoc """
  Enforces runtime resource budgets for supervised plugin work.

  `Raxol.Core.Runtime.Plugins.PluginSupervisor` registers each active plugin
  task. This server samples those task processes, their memory, their owned ETS
  tables, and their share of BEAM reductions. Budgets come from plugin manifest
  metadata stored in `PluginRegistry`.

  Actions are configured per plugin:

    * `:warn` logs and emits telemetry without blocking work
    * `:throttle` rate-limits new supervised work until usage returns under budget
    * `:kill` terminates active work and unloads the plugin
  """

  use GenServer

  alias Raxol.Core.Runtime.Log

  alias Raxol.Core.Runtime.Plugins.{
    Manifest,
    PluginLifecycle,
    PluginRegistry,
    PluginSupervisor
  }

  @type plugin_id :: atom() | String.t()

  @type budget :: %{
          max_memory_mb: number(),
          max_cpu_percent: number(),
          max_ets_tables: non_neg_integer(),
          max_processes: non_neg_integer()
        }

  @type usage :: %{
          memory_mb: float(),
          cpu_percent: float(),
          ets_tables: non_neg_integer(),
          processes: non_neg_integer()
        }

  @type action :: :warn | :throttle | :kill

  @default_interval_ms 5_000
  @default_throttle_interval_ms 1_000
  @default_action :warn
  @telemetry_event [:raxol, :plugins, :resource_budget, :exceeded]

  defstruct [
    :timer_ref,
    interval_ms: @default_interval_ms,
    throttle_interval_ms: @default_throttle_interval_ms,
    plugin_actions: %{},
    violation_counts: %{},
    cpu_samples: %{}
  ]

  # -- Client API ------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Checks current supervised resource usage for one plugin."
  @spec check(plugin_id()) :: {:ok, usage()} | {:over_budget, usage(), budget()}
  def check(plugin_id) do
    GenServer.call(__MODULE__, {:check, normalize_plugin_id(plugin_id)})
  end

  @doc "Sets the exact enforcement action for a registered plugin."
  @spec set_action(plugin_id(), action()) :: :ok
  def set_action(plugin_id, action) when action in [:warn, :throttle, :kill] do
    GenServer.call(__MODULE__, {:set_action, normalize_plugin_id(plugin_id), action})
  end

  @doc "Checks all registered plugins without applying enforcement actions."
  @spec monitor_all() :: [{plugin_id(), :ok | :over_budget}]
  def monitor_all do
    GenServer.call(__MODULE__, :monitor_all)
  end

  @doc "Checks all registered plugins and synchronously applies configured actions."
  @spec enforce_now() :: [{plugin_id(), :ok | :over_budget}]
  def enforce_now do
    GenServer.call(__MODULE__, :enforce_now)
  end

  @doc "Returns whether new work for a plugin is currently rate-limited."
  @spec throttled?(plugin_id()) :: boolean()
  def throttled?(plugin_id), do: PluginSupervisor.throttled?(plugin_id)

  @doc false
  @spec admit(plugin_id()) :: :ok | {:error, :throttled}
  def admit(plugin_id), do: PluginSupervisor.admit(plugin_id)

  # -- Server ----------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)

    state = %__MODULE__{
      interval_ms: interval_ms,
      throttle_interval_ms:
        Keyword.get(opts, :throttle_interval_ms, @default_throttle_interval_ms),
      timer_ref: Process.send_after(self(), :check_budgets, interval_ms)
    }

    {:ok, state}
  end

  @impl GenServer
  def handle_call({:check, plugin_id}, _from, state) do
    {result, state} = check_plugin(plugin_id, state)
    {:reply, result, state}
  end

  def handle_call({:set_action, plugin_id, action}, _from, state) do
    _result = PluginRegistry.update_metadata(plugin_id, %{resource_budget_action: action})
    {:reply, :ok, %{state | plugin_actions: Map.put(state.plugin_actions, plugin_id, action)}}
  end

  def handle_call(:monitor_all, _from, state) do
    {checks, state} = check_all_plugins(state)
    {:reply, statuses(checks), state}
  end

  def handle_call(:enforce_now, _from, state) do
    {results, state} = enforce_budgets(state)
    {:reply, results, state}
  end

  @impl GenServer
  def handle_info(:check_budgets, state) do
    {_results, state} = enforce_budgets(state)
    timer_ref = Process.send_after(self(), :check_budgets, state.interval_ms)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- Measurement -----------------------------------------------------------

  defp check_all_plugins(state) do
    PluginRegistry.list()
    |> Enum.map_reduce(state, fn entry, acc ->
      {result, acc} = check_plugin(entry.id, acc)
      {{entry.id, result}, acc}
    end)
  end

  defp check_plugin(plugin_id, state) do
    {usage, state} = measure_usage(plugin_id, state)
    budget = get_budget(plugin_id)

    result =
      if over_budget?(usage, budget) do
        {:over_budget, usage, budget}
      else
        {:ok, usage}
      end

    {result, state}
  end

  defp measure_usage(plugin_id, state) do
    pids = PluginSupervisor.task_pids(plugin_id)
    process_set = MapSet.new(pids)

    memory_bytes =
      Enum.reduce(pids, 0, fn pid, total ->
        total + process_info_value(pid, :memory)
      end)

    ets_tables =
      :ets.all()
      |> Enum.count(fn table ->
        case :ets.info(table, :owner) do
          owner when is_pid(owner) -> MapSet.member?(process_set, owner)
          _ -> false
        end
      end)

    {cpu_percent, state} = measure_cpu_percent(plugin_id, pids, state)

    usage = %{
      memory_mb: memory_bytes / (1024 * 1024),
      cpu_percent: cpu_percent,
      ets_tables: ets_tables,
      processes: length(pids)
    }

    {usage, state}
  end

  defp measure_cpu_percent(plugin_id, pids, state) do
    total_reductions = total_reductions()

    current_process_reductions =
      Map.new(pids, fn pid ->
        {pid, process_info_value(pid, :reductions)}
      end)

    case Map.get(state.cpu_samples, plugin_id) do
      nil ->
        sample = %{
          total_reductions: total_reductions,
          process_reductions: current_process_reductions
        }

        {0.0, put_in(state.cpu_samples[plugin_id], sample)}

      previous ->
        plugin_delta =
          Enum.reduce(current_process_reductions, 0, fn {pid, reductions}, total ->
            total + max(0, reductions - Map.get(previous.process_reductions, pid, 0))
          end)

        total_delta = max(0, total_reductions - previous.total_reductions)

        percent =
          if total_delta == 0 do
            0.0
          else
            min(100.0, plugin_delta * 100.0 / total_delta)
          end

        sample = %{
          total_reductions: total_reductions,
          process_reductions: current_process_reductions
        }

        {percent, put_in(state.cpu_samples[plugin_id], sample)}
    end
  end

  defp process_info_value(pid, key) do
    case Process.info(pid, key) do
      {^key, value} when is_integer(value) -> value
      _ -> 0
    end
  end

  defp total_reductions do
    {total, _since_last_call} = :erlang.statistics(:reductions)
    total
  end

  # -- Enforcement -----------------------------------------------------------

  defp enforce_budgets(state) do
    {checks, state} = check_all_plugins(state)

    state =
      Enum.reduce(checks, state, fn
        {plugin_id, {:ok, _usage}}, acc ->
          clear_violation(plugin_id, acc)

        {plugin_id, {:over_budget, usage, budget}}, acc ->
          count = Map.get(acc.violation_counts, plugin_id, 0) + 1

          acc = %{
            acc
            | violation_counts: Map.put(acc.violation_counts, plugin_id, count)
          }

          action = action_for(plugin_id, acc)
          acc = enforce_action(plugin_id, action, usage, budget, acc)
          emit_violation(plugin_id, action, usage, budget, count)
          acc
      end)

    {statuses(checks), state}
  end

  defp enforce_action(plugin_id, :warn, usage, _budget, state) do
    Log.warning("[ResourceBudget] Plugin #{plugin_id} over budget: #{inspect(usage)}")

    state
  end

  defp enforce_action(plugin_id, :throttle, _usage, _budget, state) do
    Log.warning("[ResourceBudget] Throttling plugin #{plugin_id}")
    PluginSupervisor.throttle(plugin_id, state.throttle_interval_ms)
    state
  end

  defp enforce_action(plugin_id, :kill, _usage, _budget, state) do
    Log.warning("[ResourceBudget] Killing over-budget plugin #{plugin_id}")
    PluginSupervisor.block(plugin_id)
    _terminated = PluginSupervisor.terminate_plugin_tasks(plugin_id)
    unload_plugin(plugin_id)

    %{
      state
      | violation_counts: Map.delete(state.violation_counts, plugin_id),
        cpu_samples: Map.delete(state.cpu_samples, plugin_id)
    }
  end

  defp clear_violation(plugin_id, state) do
    PluginSupervisor.clear_throttle(plugin_id)
    %{state | violation_counts: Map.delete(state.violation_counts, plugin_id)}
  end

  defp unload_plugin(plugin_id) do
    case Process.whereis(PluginLifecycle) do
      nil ->
        PluginRegistry.unregister(plugin_id)
        PluginSupervisor.clear_throttle(plugin_id)

      _pid ->
        case PluginSupervisor.start_cleanup(plugin_id, fn -> unload_plugin_safely(plugin_id) end) do
          {:ok, _pid} -> :ok
          {:error, :already_started} -> :ok
          {:error, reason} -> unload_fallback(plugin_id, reason)
        end
    end
  end

  defp unload_plugin_safely(plugin_id) do
    try do
      case PluginLifecycle.unload(plugin_id) do
        :ok -> :ok
        {:error, reason} -> unload_fallback(plugin_id, reason)
      end
    catch
      :exit, reason -> unload_fallback(plugin_id, reason)
    after
      PluginSupervisor.clear_throttle(plugin_id)
    end
  end

  defp unload_fallback(plugin_id, reason) do
    Log.warning(
      "[ResourceBudget] Lifecycle unload failed for #{plugin_id}: #{inspect(reason)}; unregistering directly"
    )

    PluginRegistry.unregister(plugin_id)
    PluginSupervisor.clear_throttle(plugin_id)
  end

  defp emit_violation(plugin_id, action, usage, budget, count) do
    :telemetry.execute(
      @telemetry_event,
      %{violation_count: count},
      %{
        plugin_id: plugin_id,
        action: action,
        usage: usage,
        budget: budget
      }
    )
  end

  defp statuses(checks) do
    Enum.map(checks, fn
      {plugin_id, {:ok, _usage}} -> {plugin_id, :ok}
      {plugin_id, {:over_budget, _usage, _budget}} -> {plugin_id, :over_budget}
    end)
  end

  defp get_budget(plugin_id) do
    default = Manifest.default_budget()

    case PluginRegistry.get(plugin_id) do
      {:ok, entry} ->
        budget =
          entry
          |> Map.get(:metadata, %{})
          |> Map.get(:resource_budget, %{})

        if valid_budget?(budget) do
          Map.merge(default, budget)
        else
          default
        end

      :error ->
        default
    end
  end

  defp action_for(plugin_id, state) do
    case PluginRegistry.get(plugin_id) do
      {:ok, %{metadata: %{resource_budget_action: action}}}
      when action in [:warn, :throttle, :kill] ->
        action

      _ ->
        Map.get(state.plugin_actions, plugin_id, @default_action)
    end
  end

  defp valid_budget?(budget) when is_map(budget) do
    Enum.all?(
      [
        {:max_memory_mb, :number},
        {:max_cpu_percent, :number},
        {:max_ets_tables, :integer},
        {:max_processes, :integer}
      ],
      fn
        {key, :number} ->
          value = Map.get(budget, key, 0)
          is_number(value) and value >= 0

        {key, :integer} ->
          value = Map.get(budget, key, 0)
          is_integer(value) and value >= 0
      end
    )
  end

  defp valid_budget?(_budget), do: false

  defp over_budget?(usage, budget) do
    usage.memory_mb > budget.max_memory_mb or
      usage.cpu_percent > budget.max_cpu_percent or
      usage.ets_tables > budget.max_ets_tables or
      usage.processes > budget.max_processes
  end

  defp normalize_plugin_id(id) when is_atom(id), do: id

  defp normalize_plugin_id(id) when is_binary(id) do
    String.to_existing_atom(id)
  rescue
    ArgumentError -> id
  end
end
