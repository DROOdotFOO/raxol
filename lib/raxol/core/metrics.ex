defmodule Raxol.Core.Metrics do
  @moduledoc """
  Core metrics module for Raxol framework.

  Provides metrics collection and recording with timeout-guarded
  calls to underlying collectors. Metrics are non-critical -- failures
  are swallowed where appropriate.
  """

  @spec init(keyword()) :: :ok | {:error, term()}
  def init(options \\ []) do
    with {:ok, _pid} <-
           safe_call(
             fn -> Raxol.Core.Metrics.MetricsCollector.start_link(options) end,
             5000
           ),
         :ok <-
           safe_call(
             fn -> Raxol.Core.Metrics.Aggregator.init(options) end,
             3000
           ),
         :ok <-
           safe_call(
             fn -> Raxol.Core.Metrics.AlertManager.init(options) end,
             3000
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:metrics_init_failed, reason}}
    end
  end

  @doc """
  Records a metric with the given name, value, and optional tags.

  ## Example

      Raxol.Core.Metrics.record("render_time", 150, component: "table")
  """
  @spec record(String.t(), any(), keyword()) :: :ok
  def record(name, value, tags \\ []) do
    # Metrics are non-critical -- swallow failures
    fire_and_forget(fn ->
      Raxol.Core.Metrics.MetricsCollector.record_metric(name, :custom, value,
        tags: tags
      )
    end)

    fire_and_forget(fn ->
      Raxol.Core.Metrics.Aggregator.record(name, value, tags)
    end)

    :ok
  end

  @spec get_metrics() ::
          {:ok, map()}
          | {:error, {:metrics_get_failed, :timeout | {term(), term()}}}
  def get_metrics do
    case safe_call(
           fn -> Raxol.Core.Metrics.MetricsCollector.get_all_metrics() end,
           2000
         ) do
      {:ok, metrics} when is_map(metrics) -> {:ok, metrics}
      {:ok, data} -> {:ok, normalize_metrics(data)}
      {:error, reason} -> {:error, {:metrics_get_failed, reason}}
    end
  end

  @spec clear_metrics() ::
          :ok | {:error, {:metrics_clear_failed, :timeout | {term(), term()}}}
  def clear_metrics do
    with :ok <-
           safe_call(
             fn -> Raxol.Core.Metrics.MetricsCollector.clear_metrics() end,
             2000
           ),
         :ok <- safe_call(fn -> Raxol.Core.Metrics.Aggregator.clear() end, 2000) do
      :ok
    else
      {:error, reason} -> {:error, {:metrics_clear_failed, reason}}
    end
  end

  # -- Private --

  # Runs fun in a Task with timeout, normalizes the result to {:ok, result} | {:error, reason}.
  defp safe_call(fun, timeout_ms) do
    task = Task.async(fun)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, :ok} -> :ok
      {:ok, value} -> {:ok, value}
      nil -> {:error, :timeout}
      {:exit, reason} -> {:error, {:exit, reason}}
    end
  end

  # Runs fun in a Task, ignores the result. For non-critical operations.
  defp fire_and_forget(fun) do
    task = Task.async(fun)

    case Task.yield(task, 1000) || Task.shutdown(task) do
      _ -> :ok
    end
  end

  defp normalize_metrics(data) when is_list(data) do
    Enum.into(data, %{}, fn
      {key, value} -> {key, value}
      _ -> {nil, nil}
    end)
    |> Map.delete(nil)
  end
end
