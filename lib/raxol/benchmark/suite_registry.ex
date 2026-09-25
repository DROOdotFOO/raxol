defmodule Raxol.Benchmark.SuiteRegistry do
  @moduledoc """
  Central registry for all benchmark suites.
  Manages suite discovery, registration, and execution.
  """

  require Logger

  use Raxol.Core.Behaviours.BaseManager

  @auto_discover_delay_ms Raxol.Core.Defaults.monitor_interval_ms()

  # Client API

  @doc """
  Starts the server, registered under its module name unless `:name` is
  given: the public API calls it by that name.
  """
  def start_link(opts \\ []) do
    opts |> Keyword.put_new(:name, __MODULE__) |> super()
  end

  @doc """
  Register a benchmark suite module.
  """
  def register_suite(module) when is_atom(module) do
    GenServer.call(__MODULE__, {:register_suite, module})
  end

  @doc """
  List all registered benchmark suites.
  """
  def list_suites do
    GenServer.call(__MODULE__, :list_suites)
  end

  @doc """
  Get details for a specific suite.
  """
  def get_suite(name) do
    GenServer.call(__MODULE__, {:get_suite, name})
  end

  @doc """
  Run all registered benchmark suites.
  """
  def run_all(opts \\ []) do
    GenServer.call(__MODULE__, {:run_all, opts}, :infinity)
  end

  @doc """
  Run specific benchmark suites by name or tag.
  """
  def run_suites(filter, opts \\ []) do
    GenServer.call(__MODULE__, {:run_suites, filter, opts}, :infinity)
  end

  @doc """
  Discover and automatically register benchmark suites in the codebase.
  """
  def discover_suites do
    GenServer.call(__MODULE__, :discover_suites)
  end

  @doc """
  Get performance history for a suite.
  """
  def get_history(suite_name, limit \\ 10) do
    GenServer.call(__MODULE__, {:get_history, suite_name, limit})
  end

  @doc """
  Compare current results with baseline.
  """
  def compare_with_baseline(suite_name, baseline_version) do
    GenServer.call(
      __MODULE__,
      {:compare_baseline, suite_name, baseline_version}
    )
  end

  # Server Callbacks

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(_opts) do
    state = %{
      suites: %{},
      results: %{},
      baselines: %{},
      metadata: %{
        registered_at: DateTime.utc_now(),
        last_run: nil,
        total_runs: 0
      }
    }

    # Auto-discover suites on startup
    schedule_discovery()

    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:register_suite, module}, _from, state) do
    case validate_suite_module(module) do
      {:ok, suite_info} ->
        name = suite_info.name
        updated_suites = Map.put(state.suites, name, suite_info)
        {:reply, {:ok, name}, %{state | suites: updated_suites}}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  def handle_manager_call(:list_suites, _from, state) do
    suite_list =
      state.suites
      |> Enum.map(fn {name, info} ->
        %{
          name: name,
          module: info.module,
          scenario_count: length(info.scenarios),
          tags: info.tags,
          last_run: get_last_run(state.results, name)
        }
      end)
      |> Enum.sort_by(& &1.name)

    {:reply, suite_list, state}
  end

  def handle_manager_call({:get_suite, name}, _from, state) do
    case Map.get(state.suites, name) do
      nil -> {:reply, {:error, :not_found}, state}
      suite -> {:reply, {:ok, suite}, state}
    end
  end

  def handle_manager_call({:run_all, opts}, _from, state) do
    results = run_all_suites(state.suites, opts)

    updated_state =
      state
      |> update_results(results)
      |> update_metadata()

    {:reply, {:ok, results}, updated_state}
  end

  def handle_manager_call({:run_suites, filter, opts}, _from, state) do
    filtered_suites = filter_suites(state.suites, filter)
    results = run_all_suites(filtered_suites, opts)

    updated_state =
      state
      |> update_results(results)
      |> update_metadata()

    {:reply, {:ok, results}, updated_state}
  end

  def handle_manager_call(:discover_suites, _from, state) do
    updated_state = apply_discovered_suites(state)
    count = map_size(updated_state.suites) - map_size(state.suites)
    {:reply, {:ok, count}, updated_state}
  end

  def handle_manager_call({:get_history, suite_name, limit}, _from, state) do
    history = get_suite_history(state.results, suite_name, limit)
    {:reply, history, state}
  end

  def handle_manager_call(
        {:compare_baseline, suite_name, baseline_version},
        _from,
        state
      ) do
    comparison = compare_results(state, suite_name, baseline_version)
    {:reply, comparison, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:auto_discover, state) do
    updated_state = apply_discovered_suites(state)
    {:noreply, updated_state}
  end

  # Private Functions

  defp apply_discovered_suites(state) do
    discovered = discover_benchmark_modules()

    Enum.reduce(discovered, state, fn module, acc_state ->
      case validate_suite_module(module) do
        {:ok, suite_info} ->
          name = suite_info.name
          updated_suites = Map.put(acc_state.suites, name, suite_info)
          %{acc_state | suites: updated_suites}

        _ ->
          acc_state
      end
    end)
  end

  defp validate_suite_module(module) do
    cond do
      not Code.ensure_loaded?(module) ->
        {:error, :module_not_loaded}

      not function_exported?(module, :list_suites, 0) ->
        {:error, :invalid_suite_module}

      true ->
        extract_suite_info(module)
    end
  end

  defp extract_suite_info(module) do
    suites = module.list_suites()

    suite_info = %{
      module: module,
      name: module |> Module.split() |> List.last(),
      scenarios: extract_scenarios(suites),
      tags: extract_tags(suites),
      registered_at: DateTime.utc_now()
    }

    {:ok, suite_info}
  rescue
    e ->
      Logger.warning(
        "Failed to extract suite info for #{module}: #{Exception.message(e)}"
      )

      {:error, :extraction_failed}
  end

  defp extract_scenarios(suites) do
    suites
    |> Enum.flat_map(fn suite ->
      Map.get(suite, :scenarios, [])
      |> Enum.map(fn scenario ->
        %{
          name: scenario.name,
          tags: Map.get(scenario, :tags, [])
        }
      end)
    end)
  end

  defp extract_tags(suites) do
    suites
    |> Enum.flat_map(fn suite ->
      suite.scenarios
      |> Enum.flat_map(fn scenario -> Map.get(scenario, :tags, []) end)
    end)
    |> Enum.uniq()
  end

  defp run_all_suites(suites, opts) do
    Task.async_stream(
      suites,
      fn {name, suite_info} ->
        run_suite(name, suite_info, opts)
      end,
      max_concurrency: Keyword.get(opts, :max_concurrency, 1),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, result} -> result end)
    |> Enum.into(%{})
  end

  defp run_suite(name, suite_info, opts) do
    start_time = System.monotonic_time(:microsecond)

    result =
      try do
        suite_info.module.run_benchmarks(opts)
      rescue
        error ->
          {:error, Exception.format(:error, error, __STACKTRACE__)}
      end

    end_time = System.monotonic_time(:microsecond)
    duration = end_time - start_time

    {name,
     %{
       result: result,
       duration_us: duration,
       timestamp: DateTime.utc_now(),
       opts: opts
     }}
  end

  defp filter_suites(suites, filter) when is_list(filter) do
    tags = Keyword.get(filter, :tags, [])
    names = Keyword.get(filter, :names, [])

    suites
    |> Enum.filter(fn {name, suite_info} ->
      matches_name = Enum.empty?(names) or name in names

      matches_tags =
        Enum.empty?(tags) or Enum.any?(tags, &(&1 in suite_info.tags))

      matches_name and matches_tags
    end)
    |> Enum.into(%{})
  end

  defp filter_suites(suites, filter) when is_binary(filter) do
    regex = Regex.compile!(filter, "i")

    suites
    |> Enum.filter(fn {name, _} ->
      Regex.match?(regex, name)
    end)
    |> Enum.into(%{})
  end

  defp filter_suites(suites, _), do: suites

  defp update_results(state, new_results) do
    updated_results =
      Enum.reduce(new_results, state.results, fn {suite_name, result}, acc ->
        history = Map.get(acc, suite_name, [])
        Map.put(acc, suite_name, [result | history])
      end)

    %{state | results: updated_results}
  end

  defp update_metadata(state) do
    metadata =
      state.metadata
      |> Map.put(:last_run, DateTime.utc_now())
      |> Map.update(:total_runs, 1, &(&1 + 1))

    %{state | metadata: metadata}
  end

  defp get_last_run(results, suite_name) do
    case Map.get(results, suite_name) do
      nil -> nil
      [] -> nil
      [latest | _] -> latest.timestamp
    end
  end

  defp get_suite_history(results, suite_name, limit) do
    case Map.get(results, suite_name) do
      nil -> []
      history -> Enum.take(history, limit)
    end
  end

  defp compare_results(state, suite_name, baseline_version) do
    current = get_latest_result(state.results, suite_name)
    baseline = get_baseline(state.baselines, suite_name, baseline_version)

    case {current, baseline} do
      {nil, _} ->
        {:error, :no_current_results}

      {_, nil} ->
        {:error, :baseline_not_found}

      {current_result, baseline_result} ->
        {:ok, calculate_comparison(current_result, baseline_result)}
    end
  end

  defp get_latest_result(results, suite_name) do
    case Map.get(results, suite_name) do
      nil -> nil
      [] -> nil
      [latest | _] -> latest
    end
  end

  defp get_baseline(baselines, suite_name, version) do
    baselines
    |> Map.get(suite_name, %{})
    |> Map.get(version)
  end

  defp calculate_comparison(current, baseline) do
    %{
      current: current,
      baseline: baseline,
      performance_change: calculate_performance_change(current, baseline),
      memory_change: calculate_memory_change(current, baseline)
    }
  end

  defp calculate_performance_change(_current, _baseline) do
    # Implementation would calculate actual performance differences
    %{percent_change: 0, direction: :stable}
  end

  defp calculate_memory_change(_current, _baseline) do
    # Implementation would calculate actual memory differences
    %{percent_change: 0, direction: :stable}
  end

  defp discover_benchmark_modules do
    # Find all modules that use Raxol.Benchmark.DSL
    {:ok, modules} = :application.get_key(:raxol, :modules)

    modules
    |> Enum.filter(fn module ->
      module_str = Atom.to_string(module)

      (String.contains?(module_str, "Benchmark") or
         String.contains?(module_str, "Bench")) and
        Code.ensure_loaded?(module) and
        function_exported?(module, :list_suites, 0)
    end)
  end

  defp schedule_discovery do
    # Auto-discover suites after a short delay
    _ = Process.send_after(self(), :auto_discover, @auto_discover_delay_ms)
  end
end
