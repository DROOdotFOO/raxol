defmodule Raxol.Core.Metrics.Aggregator do
  @moduledoc """
  Metric aggregation system for the Raxol metrics.

  This module handles:
  - Metric aggregation by time windows
  - Statistical calculations (mean, median, percentiles)
  - Metric grouping and categorization
  - Aggregation rules and policies
  - Real-time aggregation updates
  """

  use Raxol.Core.Behaviours.BaseManager

  alias Raxol.Core.Metrics.MetricsCollector

  @type aggregation_type :: :sum | :mean | :median | :min | :max | :percentile
  @type time_window :: :minute | :hour | :day | :week | :month
  @type aggregation_rule :: %{
          type: aggregation_type(),
          window: time_window(),
          metric_name: String.t(),
          tags: map(),
          group_by: [String.t()]
        }

  @default_options %{
    window_size: :hour,
    aggregation_types: [:mean, :max, :min],
    group_by: [],
    # 7 days in seconds
    retention_period: 7 * 24 * 60 * 60,
    # 1 minute in seconds
    update_interval: 60
  }

  # BaseManager provides start_link/1 which handles GenServer initialization
  # Usage: Raxol.Core.Metrics.Aggregator.start_link(name: __MODULE__, ...)

  @doc """
  Adds a new aggregation rule.
  """
  def add_rule(rule) do
    GenServer.call(__MODULE__, {:add_rule, rule})
  end

  @doc """
  Gets aggregated metrics for a specific rule.
  """
  def get_aggregated_metrics(rule_id) do
    GenServer.call(__MODULE__, {:get_aggregated_metrics, rule_id})
  end

  @doc """
  Updates aggregation for a specific rule.
  """
  def update_aggregation(rule_id) do
    GenServer.call(__MODULE__, {:update_aggregation, rule_id})
  end

  @doc """
  Gets all aggregation rules.
  """
  def get_rules do
    GenServer.call(__MODULE__, :get_rules)
  end

  @doc """
  Records a metric for aggregation.
  """
  def record(name, value, tags \\ []) do
    # This is a simple pass-through to the unified collector
    # The actual aggregation happens based on rules
    Raxol.Core.Metrics.MetricsCollector.record_metric(name, :custom, value,
      tags: tags
    )
  end

  @doc """
  Stops the aggregator.
  """
  def stop(pid \\ __MODULE__) do
    GenServer.stop(pid)
  end

  @doc """
  Clears all aggregations and rules.
  """
  def clear do
    GenServer.call(__MODULE__, :clear)
  end

  @doc """
  Calculates an aggregation of values using the specified method.
  """
  @spec calculate_aggregation(list(number()), atom() | {:percentile, float()}) ::
          number()
  def calculate_aggregation(values, :mean) do
    Enum.sum(values) / length(values)
  end

  def calculate_aggregation(values, :sum), do: Enum.sum(values)
  def calculate_aggregation(values, :min), do: Enum.min(values)
  def calculate_aggregation(values, :max), do: Enum.max(values)

  def calculate_aggregation(values, :median) do
    sorted = Enum.sort(values)
    count = length(sorted)

    case rem(count, 2) == 0 do
      true ->
        # Even number of elements - average of middle two
        mid = div(count, 2)
        (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2

      false ->
        # Odd number of elements - middle element
        Enum.at(sorted, div(count, 2))
    end
  end

  def calculate_aggregation(values, {:percentile, p}) do
    sorted = Enum.sort(values)
    count = length(sorted)

    case count == 0 do
      true ->
        0

      false ->
        index = ceil(p * count) - 1
        index = max(0, min(index, count - 1))
        Enum.at(sorted, index)
    end
  end

  def calculate_aggregation(values, :percentile) do
    # Default to 90th percentile
    calculate_aggregation(values, {:percentile, 0.9})
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def init_manager(opts) do
    state = %{
      rules: %{},
      next_rule_id: 1,
      aggregations: %{},
      options: Map.merge(@default_options, Map.new(opts))
    }

    schedule_update(state.options.update_interval)
    {:ok, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:add_rule, rule}, _from, state) do
    rule_id = state.next_rule_id
    validated_rule = validate_rule(rule)

    new_state = %{
      state
      | rules: Map.put(state.rules, rule_id, validated_rule),
        aggregations: Map.put(state.aggregations, rule_id, []),
        next_rule_id: rule_id + 1
    }

    {:reply, {:ok, rule_id}, new_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:get_aggregated_metrics, rule_id}, _from, state) do
    case Map.get(state.aggregations, rule_id) do
      nil -> {:reply, {:error, :rule_not_found}, state}
      metrics -> {:reply, {:ok, metrics}, state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call({:update_aggregation, rule_id}, _from, state) do
    case Map.get(state.rules, rule_id) do
      nil ->
        {:reply, {:error, :rule_not_found}, state}

      rule ->
        {:ok, metrics} =
          MetricsCollector.get_metrics(rule.metric_name, rule.tags)

        aggregated = aggregate_metrics(metrics, rule)

        new_state = %{
          state
          | aggregations: Map.put(state.aggregations, rule_id, aggregated)
        }

        {:reply, {:ok, aggregated}, new_state}
    end
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:get_rules, _from, state) do
    {:reply, {:ok, state.rules}, state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_call(:clear, _from, state) do
    cleared_state = %{
      state
      | rules: %{},
        aggregations: %{},
        next_rule_id: 1
    }

    {:reply, :ok, cleared_state}
  end

  @impl Raxol.Core.Behaviours.BaseManager
  def handle_manager_info(:update_aggregations, state) do
    new_state = update_all_aggregations(state)
    schedule_update(state.options.update_interval)
    {:noreply, new_state}
  end

  @spec validate_rule(map()) :: %{
          type: atom(),
          window: atom(),
          metric_name: any(),
          tags: map(),
          group_by: list()
        }
  defp validate_rule(rule) do
    %{
      type: Map.get(rule, :type, :mean),
      window: Map.get(rule, :window, :hour),
      metric_name: Map.get(rule, :metric_name),
      tags: Map.get(rule, :tags, %{}),
      group_by: Map.get(rule, :group_by, [])
    }
  end

  defp aggregate_metrics(metrics, rule) do
    metrics
    |> group_metrics(rule.group_by)
    |> Enum.map(fn {group, group_metrics} ->
      # Extract values from metric maps before aggregation
      values = Enum.map(group_metrics, & &1.value)
      aggregated_value = calculate_aggregation(values, rule.type)

      %{
        timestamp: DateTime.utc_now() |> DateTime.to_unix(:millisecond),
        value: aggregated_value,
        group: group,
        type: rule.type,
        window: rule.window
      }
    end)
  end

  # A rule with no recorded metrics has nothing to aggregate.
  defp group_metrics([], _group_by), do: []

  defp group_metrics(metrics, []) do
    [{"all", metrics}]
  end

  defp group_metrics(metrics, group_by) do
    metrics
    |> Enum.group_by(fn metric ->
      tags = MetricsCollector.normalize_tags(metric.tags)

      group_by
      |> Enum.map_join(":", fn key ->
        Map.get(tags, key) || Map.get(tags, String.to_atom(key))
      end)
    end)
  end

  defp update_all_aggregations(state) do
    Enum.reduce(state.rules, state, fn {rule_id, rule}, acc_state ->
      {:ok, metrics} =
        MetricsCollector.get_metrics(rule.metric_name, rule.tags)

      aggregated = aggregate_metrics(metrics, rule)

      %{
        acc_state
        | aggregations: Map.put(acc_state.aggregations, rule_id, aggregated)
      }
    end)
  end

  defp schedule_update(interval_seconds) do
    Process.send_after(self(), :update_aggregations, interval_seconds * 1000)
  end
end
