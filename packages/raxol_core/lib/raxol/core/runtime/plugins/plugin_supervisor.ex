defmodule Raxol.Core.Runtime.Plugins.PluginSupervisor do
  @moduledoc """
  Supervises stable plugin runtimes and isolated plugin tasks.

  Each loaded plugin owns a long-lived `PluginRuntime` process below a dynamic
  supervisor. Stateful callbacks run serially in that process, so timers and
  messages sent to `self()` remain valid for the plugin's loaded lifetime.
  Auxiliary work can still run below `Task.Supervisor`; those tasks are tracked
  by plugin ID for resource accounting and termination.

  `ResourceBudget` measures the stable runtime together with active auxiliary
  tasks. New auxiliary work passes through budget admission before it starts.

  ## Guarantees

    * One stable, isolated runtime process per loaded plugin
    * Plugin state is owned by its runtime process
    * Auxiliary task crashes do not bring down the caller
    * Synchronous auxiliary work has configurable timeouts
    * Live plugin processes are attributable to a plugin budget

  """

  use Supervisor

  alias Raxol.Core.Runtime.Log

  alias Raxol.Core.Runtime.Plugins.{
    PluginInstanceSupervisor,
    PluginRegistry,
    ResourceBudget
  }

  @task_supervisor_name Raxol.Core.Runtime.Plugins.TaskSupervisor
  @task_registry :raxol_plugin_supervised_tasks
  @throttle_registry :raxol_plugin_throttles
  @cleanup_registry :raxol_plugin_cleanups
  @default_timeout 5_000

  # ============================================================================
  # Supervisor API
  # ============================================================================

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(opts) do
    PluginRegistry.init()
    init_registry(@task_registry, :set)
    init_registry(@throttle_registry, :set)
    init_registry(@cleanup_registry, :set)

    children = [
      {Registry, keys: :unique, name: Raxol.Core.Runtime.Plugins.ProcessRegistry},
      {DynamicSupervisor,
       name: Raxol.Core.Runtime.Plugins.InstanceDynamicSupervisor, strategy: :one_for_one},
      {Task.Supervisor, name: @task_supervisor_name, max_restarts: 100, max_seconds: 60},
      {ResourceBudget, Keyword.get(opts, :resource_budget, [])}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ============================================================================
  # Public API
  # ============================================================================

  @doc """
  Runs a plugin task synchronously with crash isolation.

  Returns `{:ok, result}` on success, or `{:error, reason}` on failure.
  The task runs under the Task.Supervisor, so crashes are isolated.

  ## Options

    * `:timeout` - Maximum time in milliseconds (default: 5000)
    * `:enforce_budget` - Set to `false` only for host-controlled lifecycle
      cleanup that must run while a plugin is throttled
  ## Examples

      {:ok, state} = PluginSupervisor.run_plugin_task(:my_plugin, fn ->
        MyPlugin.init(%{config: "value"})
      end)

      {:error, {:crashed, %RuntimeError{}}} = PluginSupervisor.run_plugin_task(:bad_plugin, fn ->
        raise "oops"
      end)

  """
  @spec run_plugin_task(atom() | String.t(), (-> term()), keyword()) ::
          {:ok, term()} | {:error, term()}
  def run_plugin_task(plugin_id, func, opts \\ []) do
    plugin_id = normalize_plugin_id(plugin_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with :ok <- maybe_admit(plugin_id, opts) do
      task =
        Task.Supervisor.async_nolink(@task_supervisor_name, fn ->
          run_registered(plugin_id, func)
        end)

      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} ->
          {:ok, result}

        {:exit, reason} ->
          log_plugin_crash(plugin_id, reason)
          {:error, {:crashed, reason}}

        nil ->
          log_plugin_timeout(plugin_id, timeout)
          {:error, {:timeout, timeout}}
      end
    end
  end

  @doc """
  Runs a plugin task asynchronously (fire and forget).

  The task runs under the Task.Supervisor, so crashes are isolated.
  Crashes are logged but don't return errors to the caller.

  ## Examples

      PluginSupervisor.async_plugin_task(:my_plugin, fn ->
        MyPlugin.handle_event(event)
      end)

  """
  @spec async_plugin_task(atom() | String.t(), (-> term())) :: :ok | {:error, :throttled}
  def async_plugin_task(plugin_id, func) do
    plugin_id = normalize_plugin_id(plugin_id)

    with :ok <- admit(plugin_id) do
      case Task.Supervisor.start_child(@task_supervisor_name, fn ->
             run_registered(plugin_id, fn ->
               try do
                 func.()
               rescue
                 error ->
                   log_plugin_crash(plugin_id, error)
                   {:error, {:crashed, error}}
               catch
                 kind, value ->
                   log_plugin_crash(plugin_id, {kind, value})
                   {:error, {:crashed, {kind, value}}}
               end
             end)
           end) do
        {:ok, _pid} ->
          :ok

        {:ok, _pid, _info} ->
          :ok

        :ignore ->
          :ok

        {:error, reason} ->
          Log.error(
            "[PluginSupervisor] Failed to start async task for #{inspect(plugin_id)}: #{inspect(reason)}"
          )

          :ok
      end
    end
  end

  @doc """
  Runs multiple plugin tasks concurrently with isolation.

  Returns results in the same order as input functions.
  Failed tasks return `{:error, reason}` in their position.

  ## Options

    * `:timeout` - Maximum time for all tasks (default: 5000)

  ## Examples

      results = PluginSupervisor.run_plugin_tasks_concurrent(:my_plugin, [
        fn -> fetch_data() end,
        fn -> process_config() end
      ])
      # => [{:ok, data}, {:ok, config}]

  """
  @spec run_plugin_tasks_concurrent(atom() | String.t(), [(-> term())], keyword()) ::
          [{:ok, term()} | {:error, term()}]
  def run_plugin_tasks_concurrent(plugin_id, funcs, opts \\ []) do
    plugin_id = normalize_plugin_id(plugin_id)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case maybe_admit(plugin_id, opts) do
      :ok ->
        tasks =
          Enum.map(funcs, fn func ->
            Task.Supervisor.async_nolink(@task_supervisor_name, fn ->
              run_registered(plugin_id, func)
            end)
          end)

        Task.yield_many(tasks, timeout)
        |> Enum.map(fn
          {_task, {:ok, result}} ->
            {:ok, result}

          {task, {:exit, reason}} ->
            log_plugin_crash(plugin_id, reason)
            shutdown_task(task)
            {:error, {:crashed, reason}}

          {task, nil} ->
            log_plugin_timeout(plugin_id, timeout)
            shutdown_task(task)
            {:error, {:timeout, timeout}}
        end)

      {:error, _reason} = error ->
        List.duplicate(error, length(funcs))
    end
  end

  @doc """
  Safely invokes a plugin callback with isolation.

  Handles the common pattern of calling a module function if it exists.

  ## Examples

      # Calls MyPlugin.on_load() if exported, returns {:ok, result} or {:error, reason}
      PluginSupervisor.call_plugin_callback(:my_plugin, MyPlugin, :on_load, [])

      # Calls MyPlugin.handle_event(event) with timeout
      PluginSupervisor.call_plugin_callback(:my_plugin, MyPlugin, :handle_event, [event], timeout: 1000)

  """
  @spec call_plugin_callback(atom(), module(), atom(), list(), keyword()) ::
          {:ok, term()} | {:error, term()} | :not_exported
  def call_plugin_callback(plugin_id, module, function, args, opts \\ []) do
    arity = length(args)

    case function_exported?(module, function, arity) do
      true ->
        run_plugin_task(
          plugin_id,
          fn ->
            apply(module, function, args)
          end,
          opts
        )

      false ->
        :not_exported
    end
  end

  @doc """
  Gets statistics about plugin task execution.
  """
  @spec stats() :: %{
          active_tasks: non_neg_integer(),
          supervisor_info: nil | keyword()
        }
  def stats do
    %{
      active_tasks: Task.Supervisor.children(@task_supervisor_name) |> length(),
      supervisor_info: Process.info(Process.whereis(@task_supervisor_name))
    }
  end

  @doc "Returns the live supervised task processes owned by a plugin."
  @spec task_pids(atom() | String.t()) :: [pid()]
  def task_pids(plugin_id) do
    plugin_id = normalize_plugin_id(plugin_id)

    case :ets.whereis(@task_registry) do
      :undefined ->
        []

      _table ->
        @task_registry
        |> :ets.tab2list()
        |> Enum.flat_map(fn
          {pid, ^plugin_id} when is_pid(pid) ->
            if Process.alive?(pid) do
              [pid]
            else
              :ets.delete(@task_registry, pid)
              []
            end

          _entry ->
            []
        end)
    end
  end

  @doc "Returns the stable runtime and live auxiliary task processes for a plugin."
  @spec plugin_pids(atom() | String.t()) :: [pid()]
  def plugin_pids(plugin_id) do
    case PluginInstanceSupervisor.runtime_pid(plugin_id) do
      nil -> task_pids(plugin_id)
      runtime_pid -> [runtime_pid | task_pids(plugin_id)]
    end
  end

  @doc "Terminates every live supervised task owned by a plugin."
  @spec terminate_plugin_tasks(atom() | String.t()) :: non_neg_integer()
  def terminate_plugin_tasks(plugin_id) do
    pids = task_pids(plugin_id)

    Enum.each(pids, fn pid ->
      :ets.delete(@task_registry, pid)
      Process.exit(pid, :kill)
    end)

    length(pids)
  end

  @doc false
  @spec admit(atom() | String.t()) :: :ok | {:error, :throttled}
  def admit(plugin_id) do
    plugin_id = normalize_plugin_id(plugin_id)

    case :ets.whereis(@throttle_registry) do
      :undefined -> :ok
      _table -> admit_from_registry(plugin_id)
    end
  end

  @doc false
  def throttle(plugin_id, interval_ms) do
    plugin_id = normalize_plugin_id(plugin_id)
    deadline = System.monotonic_time(:millisecond) + interval_ms
    :ets.insert_new(@throttle_registry, {plugin_id, deadline, interval_ms})
    :ok
  end

  @doc false
  def clear_throttle(plugin_id) do
    :ets.delete(@throttle_registry, normalize_plugin_id(plugin_id))
    :ok
  end

  @doc false
  def block(plugin_id) do
    plugin_id = normalize_plugin_id(plugin_id)
    :ets.insert(@throttle_registry, {plugin_id, :infinity, 0})
    :ok
  end

  @doc false
  def throttled?(plugin_id) do
    case :ets.whereis(@throttle_registry) do
      :undefined -> false
      _table -> :ets.member(@throttle_registry, normalize_plugin_id(plugin_id))
    end
  end

  @doc false
  def start_cleanup(plugin_id, func) when is_function(func, 0) do
    plugin_id = normalize_plugin_id(plugin_id)

    if :ets.insert_new(@cleanup_registry, {plugin_id}) do
      result =
        Task.Supervisor.start_child(@task_supervisor_name, fn ->
          try do
            func.()
          after
            :ets.delete(@cleanup_registry, plugin_id)
          end
        end)

      if match?({:error, _reason}, result) do
        :ets.delete(@cleanup_registry, plugin_id)
      end

      result
    else
      {:error, :already_started}
    end
  end

  defp init_registry(name, type) do
    :ets.new(name, [
      :named_table,
      :public,
      type,
      read_concurrency: true,
      write_concurrency: true
    ])
  rescue
    ArgumentError ->
      case :ets.whereis(name) do
        :undefined -> init_registry(name, type)
        table -> table
      end
  end

  defp admit_from_registry(plugin_id) do
    case :ets.lookup(@throttle_registry, plugin_id) do
      [] ->
        :ok

      [{^plugin_id, :infinity, _interval_ms}] ->
        {:error, :throttled}

      [{^plugin_id, deadline, interval_ms}] ->
        now = System.monotonic_time(:millisecond)

        if now < deadline do
          {:error, :throttled}
        else
          replacement = {plugin_id, now + interval_ms, interval_ms}
          match_spec = [{{plugin_id, deadline, interval_ms}, [], [replacement]}]

          case :ets.select_replace(@throttle_registry, match_spec) do
            1 -> :ok
            0 -> admit_from_registry(plugin_id)
          end
        end
    end
  end

  defp maybe_admit(plugin_id, opts) do
    if Keyword.get(opts, :enforce_budget, true) do
      admit(plugin_id)
    else
      :ok
    end
  end

  defp run_registered(plugin_id, func) do
    true = :ets.insert(@task_registry, {self(), plugin_id})

    try do
      func.()
    after
      :ets.delete(@task_registry, self())
    end
  end

  defp normalize_plugin_id(id) when is_atom(id), do: id

  defp normalize_plugin_id(id) when is_binary(id) do
    String.to_existing_atom(id)
  rescue
    ArgumentError -> id
  end

  # ============================================================================
  # Private Functions
  # ============================================================================

  defp log_plugin_crash(plugin_id, reason) do
    Log.error("[PluginSupervisor] Plugin #{inspect(plugin_id)} crashed: #{inspect(reason)}")
  end

  defp log_plugin_timeout(plugin_id, timeout) do
    Log.warning("[PluginSupervisor] Plugin #{inspect(plugin_id)} timed out after #{timeout}ms")
  end

  # Cleanup helper that handles all Task.shutdown outcomes.
  # Called after task has already exited or timed out, so we just need cleanup.
  defp shutdown_task(task) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, _result} -> :ok
      {:exit, _reason} -> :ok
      nil -> :ok
    end
  end
end
